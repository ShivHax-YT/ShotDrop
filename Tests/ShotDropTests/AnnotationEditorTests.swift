import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

@MainActor
final class AnnotationEditorTests: XCTestCase {
    func testAxisAlignedArrowsAndUndoRedo() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AnnotationEditorModel(identity: fixture.identity)
        model.load(); await model.finishPendingWork()
        model.tool = .arrow
        model.gesture(start: CGPoint(x: 2,y: 8),end: CGPoint(x: 24,y: 8))
        await model.finishPendingWork()
        model.gesture(start: CGPoint(x: 8,y: 2),end: CGPoint(x: 8,y: 24))
        await model.finishPendingWork()
        XCTAssertEqual(model.document?.state.marks.count,2)
        model.undo(); await model.finishPendingWork()
        XCTAssertEqual(model.document?.state.marks.count,1)
        model.redo(); await model.finishPendingWork()
        XCTAssertEqual(model.document?.state.marks.count,2)
        model.close()
    }

    func testCropRequiresApplyAndCancelDoesNotCommit() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AnnotationEditorModel(identity: fixture.identity)
        model.load(); await model.finishPendingWork()
        let original = try XCTUnwrap(model.document?.state.crop)
        model.tool = .crop
        model.gesture(start: CGPoint(x: 4,y: 4),end: CGPoint(x: 24,y: 24))
        XCTAssertNotNil(model.cropDraft)
        XCTAssertEqual(model.document?.state.crop,original)
        model.cancelGesture()
        XCTAssertNil(model.cropDraft)
        XCTAssertFalse(try XCTUnwrap(model.document?.isDirty))
        model.gesture(start: CGPoint(x: 4,y: 4),end: CGPoint(x: 24,y: 24))
        model.applyCrop(); await model.finishPendingWork()
        XCTAssertEqual(model.document?.state.crop,CGRect(x: 4,y: 4,width: 20,height: 20))
        XCTAssertEqual(model.renderedCrop,model.document?.state.crop)
        model.undo(); await model.finishPendingWork()
        XCTAssertEqual(model.document?.state.crop,original)
        model.close()
    }

    func testSaveAndClosePreserveOriginalAndCannotMarkEditsSaved() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = try Data(contentsOf: fixture.url)
        let model = AnnotationEditorModel(identity: fixture.identity)
        model.load(); await model.finishPendingWork()
        model.tool = .rectangle
        model.gesture(start: CGPoint(x: 2,y: 2),end: CGPoint(x: 24,y: 24))
        await model.finishPendingWork()
        let state = model.document?.state
        model.save()
        XCTAssertFalse(AnnotationExportAvailability.productionEnabled)
        XCTAssertEqual(model.message,AnnotationExportAvailability.explanation)
        XCTAssertTrue(try XCTUnwrap(model.document?.isDirty))
        XCTAssertEqual(model.document?.state,state)
        model.close(); await model.finishPendingWork()
        XCTAssertEqual(model.document?.state,state)
        XCTAssertEqual(model.identity,fixture.identity)
        XCTAssertEqual(try Data(contentsOf: fixture.url),before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path),["source.png"])
    }

    func testMissingSourceShowsRecoveryWithoutCanvasOrRetarget() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.url)
        let model = AnnotationEditorModel(identity: fixture.identity)
        model.load(); await model.finishPendingWork()
        XCTAssertNil(model.document); XCTAssertNil(model.image)
        XCTAssertEqual(model.identity,fixture.identity)
        XCTAssertTrue(model.message.contains("Restore the saved copy"))
        var recoveryRequests = 0
        model.openRecents = { recoveryRequests += 1 }
        model.openRecents?()
        XCTAssertEqual(recoveryRequests, 1)
        XCTAssertEqual(model.identity, fixture.identity)
        XCTAssertNil(model.document)
        model.close()
    }

    func testUndoCancelsActiveGestureBeforeUndoingCommittedEdit() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AnnotationEditorModel(identity: fixture.identity)
        model.load(); await model.finishPendingWork()
        model.tool = .rectangle
        model.gesture(start: CGPoint(x: 2,y: 2),end: CGPoint(x: 24,y: 24))
        await model.finishPendingWork()
        model.beginGesture()
        model.undo()
        XCTAssertFalse(model.gestureActive)
        XCTAssertEqual(model.document?.state.marks.count,1)
        model.undo(); await model.finishPendingWork()
        XCTAssertEqual(model.document?.state.marks.count,0)
        model.close()
    }

    func testCloseRetainsPendingWorkerUntilLoaderActuallyReturns() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = AnnotationEditorLoadGate()
        let model = AnnotationEditorModel(identity: fixture.identity,sourceLoader: { reference in
            await gate.suspend()
            return AnnotationSource(reference: reference,width:32,height:32,rgba:Data(repeating:255,count:32*32*4))
        })
        model.load(); await gate.waitUntilStarted()
        model.close()
        XCTAssertTrue(model.hasPendingWork,"Cancellation does not release admission while decoding is still held")
        await gate.release(); await model.finishPendingWork()
        XCTAssertFalse(model.hasPendingWork)
        XCTAssertNil(model.source); XCTAssertNil(model.document); XCTAssertNil(model.image)
    }

    func testPreviewRetryRecoversInitialAndEditedFailuresWithoutLosingState() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let renderer = AnnotationEditorFlakyPreview()
        let model = AnnotationEditorModel(identity: fixture.identity,previewRenderer: { source,state in
            try await renderer.render(source:source,state:state)
        })
        model.load(); await model.finishPendingWork()
        XCTAssertTrue(model.previewFailed); XCTAssertFalse(model.rendering)
        XCTAssertNotNil(model.source); XCTAssertNil(model.image)
        model.retry(); await model.finishPendingWork()
        XCTAssertFalse(model.previewFailed); XCTAssertNotNil(model.image)
        model.tool = .rectangle
        model.gesture(start:CGPoint(x:2,y:2),end:CGPoint(x:24,y:24))
        await model.finishPendingWork()
        let edited = model.document?.state
        XCTAssertTrue(model.previewFailed); XCTAssertFalse(model.rendering)
        model.retry(); await model.finishPendingWork()
        XCTAssertFalse(model.previewFailed); XCTAssertFalse(model.rendering)
        XCTAssertEqual(model.document?.state,edited)
        XCTAssertEqual(model.renderedRevision,model.document?.revision)
        XCTAssertTrue(try XCTUnwrap(model.document?.isDirty))
        model.close()
    }

    func testExplicitZoomCanSelectSamePercentageAfterFit() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AnnotationEditorModel(identity:fixture.identity)
        model.chooseZoom(1); model.fit = true; model.chooseZoom(1)
        XCTAssertFalse(model.fit); XCTAssertEqual(model.zoom,1)
        model.close()
    }

    func testRedoCancelsGestureAndInterveningEditRejectsStaleGesture() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = AnnotationEditorModel(identity: fixture.identity)
        model.load(); await model.finishPendingWork()
        model.tool = .rectangle
        model.gesture(start:CGPoint(x:2,y:2),end:CGPoint(x:24,y:24))
        await model.finishPendingWork()
        model.undo(); await model.finishPendingWork()
        model.beginGesture(); model.redo()
        XCTAssertFalse(model.gestureActive)
        XCTAssertEqual(model.document?.state.marks.count,0)
        model.redo(); await model.finishPendingWork()
        model.beginGesture()
        model.changeSelected {$0.stroke = 4}
        await model.finishPendingWork()
        model.gesture(start:CGPoint(x:4,y:4),end:CGPoint(x:20,y:20))
        XCTAssertEqual(model.document?.state.marks.count,1,"A finished intervening preview cannot validate an older drag")
        model.endGesture(); model.close()
    }

    private func fixture() throws -> (directory: URL,url: URL,identity: AnnotationSessionIdentity) {
        let directory = try resolvedStagingTemporaryDirectory().appendingPathComponent("annotation-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("source.png")
        let bitmap = try XCTUnwrap(CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray:1,alpha:1)); bitmap.fill(CGRect(x:0,y:0,width:32,height:32))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(bitmap.makeImage()),nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to:url)
        let reference = try RecentFileReference.capture(at:url,role:.savedCopy)
        return (directory,url,AnnotationSessionIdentity(captureID:UUID(),revision:7,reference:reference))
    }
}

private actor AnnotationEditorLoadGate {
    private var continuation: CheckedContinuation<Void,Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void,Never>] = []
    func suspend() async {
        started = true
        startWaiters.forEach {$0.resume()}; startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor AnnotationEditorFlakyPreview {
    private var count = 0
    private let renderer = AnnotationRenderer()
    func render(source:AnnotationSource,state:AnnotationState) async throws -> AnnotationRaster {
        count += 1
        if count == 1 || count == 3 { throw AnnotationFailure.renderingFailed }
        return try await renderer.preview(source:source,state:state)
    }
}
