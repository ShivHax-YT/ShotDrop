import AppKit
import XCTest
@testable import ShotDrop

@MainActor
final class PinPanelPresentationTests: XCTestCase {
    func testDuplicateOrManagerShowDuringDecodeRevealsSameTokenAndPanel() async throws {
        _ = NSApplication.shared
        for duplicate in [true, false] {
            let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
            let identity = PinScreenshotIdentity(captureID: UUID(), revision: 1,
                reference: try RecentFileReference.capture(at: textFixtureURL(fixture.saved), role: .savedCopy))
            let entered = expectation(description: "Decoder entered")
            let presented = expectation(description: "One retained panel created")
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let store = PinScreenshotStore { identity in
                entered.fulfill()
                guard gate.wait(timeout: .now() + 10) == .success else { throw PinScreenshotFailure.closed }
                return PinScreenshotSnapshot(identity: identity,
                    image: RecentPreviewImage(width: 1, height: 1, bytesPerRow: 4, rgba: Data([0, 0, 0, 255])),
                    sourceWidth: 1, sourceHeight: 1)
            }
            var calls: [(NSPanel, PinPanelPresentation.Intent)] = []
            let coordinator = PinScreenshotCoordinator(store: store, presentation: { panel, intent in
                calls.append((panel, intent))
                if calls.count == 1 { presented.fulfill() }
            })
            defer { coordinator.closeAll() }
            await coordinator.pin(identity, filename: "fixture.png")
            await fulfillment(of: [entered], timeout: 3)
            let token = try XCTUnwrap(coordinator.items.first?.id)
            if duplicate { await coordinator.pin(identity, filename: "fixture.png") }
            else { coordinator.show(token) }
            XCTAssertEqual(coordinator.items.count, 1)
            XCTAssertEqual(coordinator.items.first?.id, token)
            XCTAssertTrue(calls.isEmpty)
            gate.signal()
            await fulfillment(of: [presented], timeout: 3)
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.1, .explicitShow)
            XCTAssertFalse(try XCTUnwrap(calls.first?.0).isVisible)
            let statistics = await store.statistics()
            XCTAssertEqual(statistics.sessions, 1)
            coordinator.show(token)
            XCTAssertEqual(calls.count, 2)
            XCTAssertTrue(calls[0].0 === calls[1].0, "Explicit reveal must reuse the exact native panel")
            XCTAssertEqual(calls[1].1, .explicitShow)
            XCTAssertEqual(try Data(contentsOf: fixture.saved), fixture.png)
        }
    }

    func testCoordinatorFirstLoadWithoutExplicitRepeatRemainsPassive() async throws {
        _ = NSApplication.shared
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let identity = PinScreenshotIdentity(captureID: UUID(), revision: 1,
            reference: try RecentFileReference.capture(at: textFixtureURL(fixture.saved), role: .savedCopy))
        let presented = expectation(description: "Passive panel")
        var calls: [(NSPanel, PinPanelPresentation.Intent)] = []
        let store = PinScreenshotStore { identity in
            PinScreenshotSnapshot(identity: identity,
                image: RecentPreviewImage(width: 1, height: 1, bytesPerRow: 4, rgba: Data([0, 0, 0, 255])),
                sourceWidth: 1, sourceHeight: 1)
        }
        let coordinator = PinScreenshotCoordinator(store: store, presentation: { panel, intent in
            calls.append((panel, intent)); presented.fulfill()
        })
        defer { coordinator.closeAll() }
        await coordinator.pin(identity, filename: "fixture.png")
        await fulfillment(of: [presented], timeout: 3)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1, .passiveLoad)
        let panel = try XCTUnwrap(calls.first?.0)
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { findScroll($0) }.first
        }
        let scroll = try XCTUnwrap(findScroll(content))
        XCTAssertGreaterThanOrEqual(scroll.frame.height, 100, "Pin image viewport must not collapse behind its controls")
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, 0)
        XCTAssertFalse(try XCTUnwrap(calls.first?.0).isVisible)
    }

    func testDelayedDuplicateAdmissionAfterCloseOrDecodeFailureCannotRestoreIntent() async throws {
        _ = NSApplication.shared
        for termination in ["close", "closeAll", "failure"] {
            let failDecode = termination == "failure"
            let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
            let identity = PinScreenshotIdentity(captureID: UUID(), revision: 1,
                reference: try RecentFileReference.capture(at: textFixtureURL(fixture.saved), role: .savedCopy))
            let decoderEntered = expectation(description: "Held decoder")
            let duplicateHeld = expectation(description: "Duplicate admission held after real store result")
            let terminated = expectation(description: "Original pin closed or failed")
            let decoderGate = DispatchSemaphore(value: 0)
            defer { decoderGate.signal() }
            let admissionGate = PinAdmissionHold(entered: duplicateHeld)
            defer { Task { await admissionGate.release() } }
            let store = PinScreenshotStore { identity in
                decoderEntered.fulfill()
                guard decoderGate.wait(timeout: .now() + 10) == .success else { throw PinScreenshotFailure.closed }
                if failDecode { throw PinScreenshotFailure.invalidImage }
                return PinScreenshotSnapshot(identity: identity,
                    image: RecentPreviewImage(width: 1, height: 1, bytesPerRow: 4, rgba: Data([0, 0, 0, 255])),
                    sourceWidth: 1, sourceHeight: 1)
            }
            var presented = 0
            var didTerminate = false
            var lateLoading = false
            let coordinator = PinScreenshotCoordinator(store: store, admission: { identity in
                await admissionGate.hold(try await store.admit(identity))
            }, presentation: { _, _ in presented += 1 })
            defer { coordinator.closeAll() }
            coordinator.onFeedback = { _, feedback in
                switch feedback {
                case .closed, .failed:
                    if !didTerminate { didTerminate = true; terminated.fulfill() }
                case .loading:
                    if didTerminate { lateLoading = true }
                default: break
                }
            }
            await coordinator.pin(identity, filename: "fixture.png")
            await fulfillment(of: [decoderEntered], timeout: 3)
            let token = try XCTUnwrap(coordinator.items.first?.id)
            coordinator.show(token)
            XCTAssertEqual(coordinator.pendingExplicitShowCount, 1)
            let duplicate = Task { await coordinator.pin(identity, filename: "fixture.png") }
            await fulfillment(of: [duplicateHeld], timeout: 3)
            if termination == "close" { coordinator.close(token) }
            if termination == "closeAll" { coordinator.closeAll() }
            decoderGate.signal()
            await fulfillment(of: [terminated], timeout: 3)
            await admissionGate.release()
            await duplicate.value
            XCTAssertFalse(lateLoading)
            XCTAssertEqual(presented, 0)
            XCTAssertTrue(coordinator.items.isEmpty)
            XCTAssertEqual(coordinator.pendingExplicitShowCount, 0)
        }
    }

    func testCloseAllRetiresOpenedAdmissionBeforeLocalRegistration() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let identity = PinScreenshotIdentity(captureID: UUID(), revision: 1,
            reference: try RecentFileReference.capture(at: textFixtureURL(fixture.saved), role: .savedCopy))
        let held = expectation(description: "Opened admission held")
        let gate = PinAdmissionHold(entered: held, holdOpened: true)
        let store = PinScreenshotStore { identity in
            PinScreenshotSnapshot(identity: identity,
                image: RecentPreviewImage(width: 1, height: 1, bytesPerRow: 4, rgba: Data([0, 0, 0, 255])),
                sourceWidth: 1, sourceHeight: 1)
        }
        var presentations = 0
        var feedbackCount = 0
        let coordinator = PinScreenshotCoordinator(store: store, admission: { identity in
            await gate.hold(try await store.admit(identity))
        }, presentation: { _, _ in presentations += 1 })
        coordinator.onFeedback = { _, _ in feedbackCount += 1 }
        let request = Task { await coordinator.pin(identity, filename: "fixture.png") }
        await fulfillment(of: [held], timeout: 3)
        coordinator.closeAll()
        let countAtClose = feedbackCount
        await gate.release()
        await request.value
        XCTAssertEqual(feedbackCount, countAtClose)
        XCTAssertEqual(presentations, 0)
        XCTAssertTrue(coordinator.items.isEmpty)
        XCTAssertEqual(coordinator.pendingExplicitShowCount, 0)
        let statistics = await store.statistics()
        XCTAssertEqual(statistics.sessions, 0)
    }

    func testPassiveDecodeCompletionOnlyOrdersFrontWithoutRequestingKey() {
        let panel = PinPresentationSpy()
        PinPanelPresentation.present(panel, intent: .passiveLoad)
        XCTAssertEqual(panel.calls, [.orderFront])
    }

    func testExplicitShowRequestsKeyOnTheSameRetainedPanel() {
        let panel = PinPresentationSpy()
        PinPanelPresentation.present(panel, intent: .passiveLoad)
        PinPanelPresentation.present(panel, intent: .explicitShow)
        PinPanelPresentation.present(panel, intent: .explicitShow)
        XCTAssertEqual(panel.calls, [.orderFront, .makeKeyAndOrderFront, .makeKeyAndOrderFront])
    }
}

/// Exercises the exact presentation helper used by passive load and coordinator Show,
/// without constructing, displaying, or activating a native window.
@MainActor
private final class PinPresentationSpy: PinPanelPresentationTarget {
    enum Call { case orderFront, makeKeyAndOrderFront }
    var calls: [Call] = []
    func orderFront(_ sender: Any?) { calls.append(.orderFront) }
    func makeKeyAndOrderFront(_ sender: Any?) { calls.append(.makeKeyAndOrderFront) }
}

private actor PinAdmissionHold {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private let holdOpened: Bool
    init(entered: XCTestExpectation, holdOpened: Bool = false) {
        self.entered = entered; self.holdOpened = holdOpened
    }
    func hold(_ admission: PinScreenshotStore.Admission) async -> PinScreenshotStore.Admission {
        switch admission {
        case .existing where !holdOpened, .opened where holdOpened: break
        default: return admission
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
        return admission
    }
    func release() { continuation?.resume(); continuation = nil }
}
