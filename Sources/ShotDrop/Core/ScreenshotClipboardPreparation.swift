import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScreenshotClipboardFailure: Error, LocalizedError, Sendable {
    enum Code: String, Sendable {
        case invalidSource, sourceChanged, unsupportedImage, imageTooLarge, invalidImage
        case fileUnavailable, representationSetupFailed, writeFailed
    }
    let code: Code
    let detail: String
    init(_ code: Code, _ detail: String) {
        self.code = code
        self.detail = detail
    }
    var errorDescription: String? { detail }
}

struct ScreenshotClipboardRequest: Sendable {
    let sourceURL: URL
    let mode: CopyMode
    var expectedIdentity: ScreenshotFileIdentity? = nil
    /// The coordinator deliberately chooses a verified destination or surviving original.
    var survivingFileURL: URL? = nil
    var survivingFileIdentity: ScreenshotFileIdentity? = nil
}

/// Encoded bytes own their storage. No mutable image, provider, or open descriptor escapes.
struct PreparedScreenshotClipboard: Sendable {
    let mode: CopyMode
    let pngData: Data?
    let fileURL: URL?
    fileprivate let fileState: ClipboardFileState?

    fileprivate init(mode: CopyMode, pngData: Data?, fileURL: URL?, fileState: ClipboardFileState?) {
        self.mode = mode
        self.pngData = pngData
        self.fileURL = fileURL
        self.fileState = fileState
    }

    /// Revalidate off MainActor immediately before publication. A URL is a reference,
    /// not a promise against another process moving/removing a file after this check.
    @concurrent
    func validateFileForPublication() async throws {
        try Task.checkCancellation()
        guard let fileURL, let fileState else { return }
        let (descriptor, current) = try openClipboardFile(fileURL, failure: .fileUnavailable)
        defer { close(descriptor) }
        guard current == fileState else {
            throw ScreenshotClipboardFailure(.fileUnavailable, "The selected screenshot file changed before copying. Choose a surviving file and retry.")
        }
        try verifyClipboardPath(fileURL, descriptor: descriptor, expected: current, failure: .fileUnavailable)
    }
}

/// Stateless, bounded preparation runs on the concurrent executor, never MainActor.
struct ScreenshotClipboardPreparer: Sendable {
    let maximumPNGBytes: Int

    init(maximumPNGBytes: Int = 64 * 1024 * 1024) {
        self.maximumPNGBytes = max(0, maximumPNGBytes)
    }

    @concurrent
    func prepare(_ request: ScreenshotClipboardRequest) async throws -> PreparedScreenshotClipboard {
        try Task.checkCancellation()
        var pngData: Data?
        if request.mode != .file {
            let (descriptor, initial) = try openClipboardFile(request.sourceURL, failure: .invalidSource)
            defer { close(descriptor) }
            if let expected = request.expectedIdentity, expected != initial.identity {
                throw ScreenshotClipboardFailure(.sourceChanged, "The screenshot changed before its image could be prepared.")
            }
            guard initial.size > 0 else {
                throw ScreenshotClipboardFailure(.invalidImage, "The screenshot image is empty.")
            }
            guard initial.size <= Int64(maximumPNGBytes) else {
                throw ScreenshotClipboardFailure(.imageTooLarge, "The encoded screenshot exceeds the clipboard image size limit. The original is unchanged.")
            }
            var data = Data(count: Int(initial.size))
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try Task.checkCancellation()
                    let count = pread(descriptor, buffer.baseAddress!.advanced(by: offset),
                                      min(256 * 1024, buffer.count - offset), off_t(offset))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw ScreenshotClipboardFailure(.sourceChanged, "The screenshot could not be read completely. The clipboard has not been changed.")
                    }
                    offset += count
                }
            }
            try verifyClipboardPath(request.sourceURL, descriptor: descriptor, expected: initial, failure: .sourceChanged)
            try Self.validatePNG(data)
            try verifyClipboardPath(request.sourceURL, descriptor: descriptor, expected: initial, failure: .sourceChanged)
            pngData = data
        }

        var selectedURL: URL?
        var selectedState: ClipboardFileState?
        if request.mode != .image {
            guard let url = request.survivingFileURL else {
                throw ScreenshotClipboardFailure(.fileUnavailable, "Choose a verified saved screenshot or a surviving original before copying a file reference.")
            }
            let (descriptor, state) = try openClipboardFile(url, failure: .fileUnavailable)
            defer { close(descriptor) }
            if let expected = request.survivingFileIdentity, expected != state.identity {
                throw ScreenshotClipboardFailure(.fileUnavailable, "The selected screenshot file has been replaced. Its file reference was not copied.")
            }
            try verifyClipboardPath(url, descriptor: descriptor, expected: state, failure: .fileUnavailable)
            selectedURL = url
            selectedState = state
        }
        try Task.checkCancellation()
        return PreparedScreenshotClipboard(mode: request.mode, pngData: pngData,
                                           fileURL: selectedURL, fileState: selectedState)
    }

    private static func validatePNG(_ data: Data) throws {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw ScreenshotClipboardFailure(.unsupportedImage, "Image copying currently requires a PNG screenshot. The original is unchanged; its file can still be copied.")
        }
        guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(image) == UTType.png.identifier as CFString,
              CGImageSourceGetCount(image) == 1,
              CGImageSourceGetStatus(image) == .statusComplete,
              CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete,
              CGImageSourceCreateThumbnailAtIndex(image, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceShouldCache: false
              ] as CFDictionary) != nil else {
            throw ScreenshotClipboardFailure(.invalidImage, "The PNG screenshot is incomplete or unreadable. The clipboard has not been changed.")
        }
    }
}

fileprivate struct ClipboardFileState: Equatable, Sendable {
    let identity: ScreenshotFileIdentity
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let mode: mode_t
    var isRegular: Bool { mode & S_IFMT == S_IFREG }

    init(_ info: stat) {
        identity = ScreenshotFileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)),
                                          inode: UInt64(info.st_ino),
                                          birthNanoseconds: Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000
                                            + Int64(info.st_birthtimespec.tv_nsec))
        size = info.st_size
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        mode = info.st_mode
    }
}

private func openClipboardFile(
    _ url: URL, failure: ScreenshotClipboardFailure.Code
) throws -> (Int32, ClipboardFileState) {
    guard url.isFileURL, !url.path.contains("\0"),
          url.host == nil || url.host == "" || url.host == "localhost" else {
        throw ScreenshotClipboardFailure(failure, "The screenshot must be an accessible local file.")
    }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw ScreenshotClipboardFailure(failure, "The screenshot file is unavailable or unreadable. The clipboard has not been changed.")
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0, ClipboardFileState(info).isRegular else {
        close(descriptor)
        throw ScreenshotClipboardFailure(failure, "The screenshot must be a regular file, not a folder or symbolic link.")
    }
    return (descriptor, ClipboardFileState(info))
}

private func verifyClipboardPath(
    _ url: URL, descriptor: Int32, expected: ClipboardFileState, failure: ScreenshotClipboardFailure.Code
) throws {
    var descriptorInfo = stat()
    var pathInfo = stat()
    guard fstat(descriptor, &descriptorInfo) == 0, lstat(url.path, &pathInfo) == 0,
          ClipboardFileState(descriptorInfo) == expected, ClipboardFileState(pathInfo) == expected else {
        throw ScreenshotClipboardFailure(failure, "The screenshot changed during clipboard preparation. Retry with the surviving file.")
    }
}
