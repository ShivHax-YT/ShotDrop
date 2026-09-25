import AppKit
import Darwin
import Foundation
import XCTest
@testable import ShotDrop

@MainActor
final class ProductionFlowTests: XCTestCase {
    func testDirectAnnotationExportPreservesSourceAndProducesValidPNG() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceURL = fixture.source.appendingPathComponent("original.png")
        let png = try ClipboardTestFixture.imageData(type: .png)
        try png.write(to: sourceURL)
        let reference = try RecentFileReference.capture(at: sourceURL, role: .savedCopy)
        let renderer = AnnotationRenderer()
        let source = try await renderer.load(reference: reference)
        var document = try AnnotationDocument(width: source.width, height: source.height)
        var state = document.state
        state.marks.append(.init(tool: .highlight, start: .init(x: 1, y: 1), end: .init(x: 12, y: 12)))
        try document.commit(state)
        let rendered = try await renderer.png(source: source, state: state)
        let service = AnnotationExportService(fileSystem: DirectScreenshotFileSystem())
        let receipt = try await service.export(png: rendered, source: reference, destination: fixture.destination, proposedStem: "annotated")
        XCTAssertEqual(try Data(contentsOf: sourceURL), png)
        XCTAssertEqual(try Data(contentsOf: receipt.destinationURL), rendered)
        XCTAssertNotEqual(rendered, png)
        try AnnotationPNGContainer.validate(rendered)
    }

    func testConfirmedSetupAdvancesThroughVerifyAndDone() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var started = false
        let model = ShotDropSetupModel(destinationURL: fixture.destination,
            service: ProductionSetupAccess(), gate: ProductionSetupGate { binding in
                started = binding.source.path == fixture.source.path && binding.destination.path == fixture.destination.path
                return started
            })
        await model.continueSetup()
        await model.continueSetup()
        model.selectSource(fixture.source)
        model.confirmCurrentSource(true)
        await model.continueSetup()
        XCTAssertTrue(started)
        XCTAssertEqual(model.step, .test)
        XCTAssertTrue(model.canRunTest)
        XCTAssertFalse(model.showsPausedSetup)
        await model.continueSetup()
        XCTAssertFalse(model.isPresented)
        XCTAssertFalse(model.isDeferred)
    }

    func testRealDetectorSavesCopiesAndPublishesToPrivateClipboard() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let png = try ClipboardTestFixture.imageData(type: .png)
        let source = fixture.source.appendingPathComponent("capture.png")
        let saved = expectation(description: "Saved and copied real file event")
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: DirectScreenshotFileSystem()))
        let relay = FlowRelay()
        let detector = ScreenshotDetector(useSpotlight: false) { relay.emit($0) }
        var output: URL?
        let pipeline = ScreenshotPipeline(writer: AppKitScreenshotPasteboardWriter(pasteboard: board), mode: .both,
            authorizeSource: {}, startDetector: { callback in relay.set(callback); try await detector.start(in: fixture.source) },
            stopDetector: { await detector.stop() }, registerOutput: { await detector.ignoreOutput(token: $0) },
            request: { event in
                .init(organization: .init(sourceURL: event.url, destinationRoot: fixture.destination,
                    template: "capture", namingContext: .init(appName: "Test", capturedAt: Date(), timeZone: .current),
                    expectedIdentity: event.identity), sourceDirectoryURL: fixture.source, destinationAccess: .userApproved)
            }, save: { request, before in await service.save(request, beforePublishing: before) },
            onOutcome: { outcome in
                if case .saved(let receipt) = outcome.save { output = receipt.destinationURL }
                else { XCTFail("Real file was not saved") }
                if case .copied = outcome.copy {} else { XCTFail("Real file was not copied") }
                saved.fulfill()
            })
        try await pipeline.start(sourceAccessExplained: true)
        try png.write(to: source)
        let marker = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        XCTAssertEqual(marker.withUnsafeBytes { setxattr(source.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, $0.count, 0, 0) }, 0)
        await fulfillment(of: [saved], timeout: 10)
        await pipeline.stop()
        XCTAssertEqual(try Data(contentsOf: source), png)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(output)), png)
        XCTAssertEqual(board.data(forType: .png), png)
        XCTAssertNotNil(board.string(forType: .fileURL))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).contains { $0.hasPrefix(".shotdrop-") })
    }

    private func makeFixture() throws -> (root: URL, source: URL, destination: URL) {
        let ptr = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(ptr) }
        let root = URL(fileURLWithPath: String(cString: ptr)).appendingPathComponent("ShotDropProduction-\(UUID())")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (root, source, destination)
    }
}

private final class FlowRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (DetectedScreenshot) -> Void)?
    func set(_ value: @escaping @Sendable (DetectedScreenshot) -> Void) { lock.lock(); callback = value; lock.unlock() }
    func emit(_ event: DetectedScreenshot) { lock.lock(); let value = callback; lock.unlock(); value?(event) }
}
