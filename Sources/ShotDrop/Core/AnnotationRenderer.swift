import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The actor serializes decoding and rendering. All document coordinates are upright,
/// bottom-left source pixels; export and preview run the same drawing implementation.
actor AnnotationRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func load(reference: RecentFileReference) throws -> AnnotationSource {
        try Task.checkCancellation()
        guard reference.role == .savedCopy else { throw AnnotationFailure.unavailable }
        guard case let .available(file) = RecentFileResolver().resolve(reference) else { throw AnnotationFailure.unavailable }
        let decoded = try ScreenshotTextImage(data: file.validatedData)
        let upright = CIImage(cgImage: decoded.image).oriented(decoded.orientation)
        let extent = upright.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        _ = try AnnotationDocument(width: width, height: height)
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(upright, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                           bounds: extent, format: .RGBA8, colorSpace: Self.colorSpace)
        }
        try Task.checkCancellation()
        return AnnotationSource(reference: reference, width: width, height: height, rgba: bytes)
    }

    func preview(source: AnnotationSource, state: AnnotationState, maximumDimension: Int = 1200) throws -> AnnotationRaster {
        guard (1...2048).contains(maximumDimension) else { throw AnnotationFailure.tooLarge }
        return try render(source: source, state: state, maximumDimension: maximumDimension)
    }

    func png(source: AnnotationSource, state: AnnotationState) throws -> Data {
        let raster = try render(source: source, state: state, maximumDimension: nil)
        let image = try Self.image(raster: raster)
        let sink = AnnotationPNGBuffer()
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            let sink = Unmanaged<AnnotationPNGBuffer>.fromOpaque(info).takeUnretainedValue()
            guard count <= AnnotationPNGBuffer.limit - sink.data.count else { sink.exceeded = true; return 0 }
            sink.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(sink).toOpaque(), cbks: &callbacks),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.png.identifier as CFString, 1, nil) else {
            throw AnnotationFailure.encodingFailed
        }
        // Construct a fresh image container; no source dictionaries or thumbnails are copied.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), !sink.exceeded else { throw AnnotationFailure.encodingFailed }
        try Task.checkCancellation()
        let clean = try AnnotationPNGContainer.cleanEncoderOutput(sink.data)
        let verified = try ScreenshotTextImage(data: clean)
        guard verified.image.width == raster.width, verified.image.height == raster.height,
              verified.orientation == .up else { throw AnnotationFailure.encodingFailed }
        return clean
    }

    nonisolated static func image(raster: AnnotationRaster) throws -> CGImage {
        guard raster.width > 0, raster.height > 0, raster.width <= 32_000_000,
              raster.height <= 32_000_000 / raster.width,
              raster.rgba.count == raster.width * raster.height * 4,
              let provider = CGDataProvider(data: raster.rgba as CFData),
              let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: raster.width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw AnnotationFailure.invalidImage
        }
        return image
    }

    private func render(source: AnnotationSource, state: AnnotationState, maximumDimension: Int?) throws -> AnnotationRaster {
        let document = try AnnotationDocument(width: source.width, height: source.height)
        try document.validate(state)
        try Task.checkCancellation()
        let sourceImage = try Self.image(raster: AnnotationRaster(width: source.width, height: source.height, rgba: source.rgba))
        let scale: CGFloat
        if let maximumDimension { scale = min(1, CGFloat(maximumDimension) / max(state.crop.width, state.crop.height)) }
        else { scale = 1 }
        let width = max(1, Int((state.crop.width * scale).rounded()))
        let height = max(1, Int((state.crop.height * scale).rounded()))
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: Self.colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AnnotationFailure.renderingFailed }
        let sx = Double(width) / state.crop.width, sy = Double(height) / state.crop.height
        canvas.scaleBy(x: sx, y: sy)
        canvas.translateBy(x: -state.crop.minX, y: -state.crop.minY)
        canvas.draw(sourceImage, in: document.extent)
        for mark in state.marks {
            try Task.checkCancellation()
            canvas.saveGState()
            let color = CGColor(colorSpace: Self.colorSpace, components: [mark.color.red, mark.color.green, mark.color.blue, mark.color.alpha])!
            canvas.setStrokeColor(color); canvas.setFillColor(color)
            canvas.setLineWidth(mark.stroke); canvas.setLineCap(.round); canvas.setLineJoin(.round)
            switch mark.tool {
            case .rectangle: canvas.stroke(mark.bounds)
            case .arrow:
                canvas.move(to: mark.start); canvas.addLine(to: mark.end); canvas.strokePath()
                let angle = atan2(mark.end.y - mark.start.y, mark.end.x - mark.start.x)
                let length = min(max(10, mark.stroke * 4), hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) / 2)
                canvas.move(to: CGPoint(x: mark.end.x - length * cos(angle - .pi / 6), y: mark.end.y - length * sin(angle - .pi / 6)))
                canvas.addLine(to: mark.end)
                canvas.addLine(to: CGPoint(x: mark.end.x - length * cos(angle + .pi / 6), y: mark.end.y - length * sin(angle + .pi / 6)))
                canvas.strokePath()
            case .text:
                let font = CTFontCreateWithName("Helvetica" as CFString, mark.fontSize, nil)
                let string = NSAttributedString(string: mark.text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
                let framesetter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: mark.bounds, transform: nil), nil)
                canvas.textMatrix = CGAffineTransform.identity
                CTFrameDraw(frame, canvas)
            case .blur:
                guard let snapshot = canvas.makeImage() else { throw AnnotationFailure.renderingFailed }
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                let blurred = CIImage(cgImage: snapshot).clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: mark.blurRadius * max(sx, sy)])
                    .cropped(to: bounds)
                guard let image = context.createCGImage(blurred, from: bounds, format: .RGBA8, colorSpace: Self.colorSpace) else { throw AnnotationFailure.renderingFailed }
                canvas.clip(to: mark.bounds)
                canvas.draw(image, in: state.crop)
            case .select, .crop: throw AnnotationFailure.invalidGeometry
            }
            canvas.restoreGState()
        }
        try Task.checkCancellation()
        guard let bytes = canvas.data else { throw AnnotationFailure.renderingFailed }
        return AnnotationRaster(width: width, height: height, rgba: Data(bytes: bytes, count: width * height * 4))
    }
}

private final class AnnotationPNGBuffer {
    static let limit = 64 * 1024 * 1024
    var data = Data()
    var exceeded = false
}
