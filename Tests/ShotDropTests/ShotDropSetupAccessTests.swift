import Darwin
import Foundation
import XCTest
@testable import ShotDrop

@MainActor
final class ShotDropSetupAccessTests: XCTestCase {
    func testExplicitCustomLocationIsDiscoveredWithoutOpeningAnyFolder() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let probe = SetupAccessProbe()
        var operations = ShotDropSetupAccessOperations()
        operations.openDirectory = { _ in probe.record(); throw ShotDropSetupAccessIssue.denied }
        let service = LocalShotDropSetupAccessService(
            readLocationPreference: { fixture.source.path }, operations: operations
        )

        let result = await service.discoverSource()

        XCTAssertEqual(result, .known(fixture.source))
        XCTAssertEqual(probe.count, 0, "Discovery must not cause a protected-folder access request")
    }

    func testExplicitTildeLocationUsesInjectedHomeWithoutAssumingDesktop() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let service = LocalShotDropSetupAccessService(
            readLocationPreference: { "~/Custom Captures" }, homeDirectory: fixture.root
        )
        let result = await service.discoverSource()
        XCTAssertEqual(result, .known(fixture.root.appendingPathComponent("Custom Captures", isDirectory: true)))
    }

    func testAbsentAndUnrecognizedLocationsRemainUnknown() async {
        let values: [String?] = [nil, "", "Desktop", "file:///tmp/captures", "~someone/captures", "/tmp/../captures", "/tmp/./captures", "/tmp/\0captures"]
        for value in values {
            let service = LocalShotDropSetupAccessService(readLocationPreference: { value })
            let result = await service.discoverSource()
            XCTAssertEqual(result, .unknown)
        }
    }

    func testDiscoveryAndSourceOperationsExecuteAwayFromMainThread() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let probe = SetupAccessProbe()
        var operations = ShotDropSetupAccessOperations()
        let realEnumerate = operations.enumerateDirectory
        operations.enumerateDirectory = { descriptor in
            probe.record()
            try realEnumerate(descriptor)
        }
        let service = LocalShotDropSetupAccessService(readLocationPreference: {
            probe.record()
            return fixture.source.path
        }, operations: operations)
        _ = await service.discoverSource()
        let result = await service.checkSource(fixture.source)
        guard case .accessible = result else { return XCTFail("Source should be accessible: \(result)") }
        XCTAssertEqual(probe.count, 2)
        XCTAssertFalse(probe.wasOnMainThread)
    }

    func testSourceCheckEnumeratesAndRetainsContentsWithoutReadingChildren() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let child = fixture.source.appendingPathComponent("unreadable.png")
        try Data([1, 2, 3, 4]).write(to: child)
        XCTAssertEqual(chmod(child.path, 0), 0)
        defer { _ = chmod(child.path, 0o600) }
        let before = try fixture.entries()
        let service = LocalShotDropSetupAccessService(readLocationPreference: { nil })

        let first = await service.checkSource(fixture.source)
        guard case let .accessible(identity) = first else { return XCTFail("Directory enumeration should not read its children") }
        let second = await service.checkSource(fixture.source, expecting: identity)

        XCTAssertEqual(second, .accessible(identity))
        XCTAssertEqual(try fixture.entries(), before)
        XCTAssertEqual(chmod(child.path, 0o600), 0)
        XCTAssertEqual(try Data(contentsOf: child), Data([1, 2, 3, 4]))
    }

    func testSourceMissingAndDeniedRemainDistinct() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing", isDirectory: true)
        let local = LocalShotDropSetupAccessService(readLocationPreference: { nil })
        let missingResult = await local.checkSource(missing)
        XCTAssertEqual(missingResult, .unavailable(.missing))

        var operations = ShotDropSetupAccessOperations()
        operations.openDirectory = { _ in throw ShotDropSetupAccessIssue.denied }
        let denied = LocalShotDropSetupAccessService(readLocationPreference: { nil }, operations: operations)
        let deniedResult = await denied.checkSource(fixture.source)
        XCTAssertEqual(deniedResult, .unavailable(.denied))
    }

    func testEnumerationDenialCannotBeReportedAccessible() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        var operations = ShotDropSetupAccessOperations()
        operations.enumerateDirectory = { _ in throw ShotDropSetupAccessIssue.denied }
        let service = LocalShotDropSetupAccessService(readLocationPreference: { nil }, operations: operations)
        let result = await service.checkSource(fixture.source)
        XCTAssertEqual(result, .unavailable(.denied))
    }

    func testSourceMovedOrReplacedRequiresExplicitNewSelection() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let service = LocalShotDropSetupAccessService(readLocationPreference: { nil })
        guard case let .accessible(identity) = await service.checkSource(fixture.source) else {
            return XCTFail("Fixture must be accessible")
        }
        let moved = fixture.root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.source, to: moved)
        let missing = await service.checkSource(fixture.source, expecting: identity)
        XCTAssertEqual(missing, .unavailable(.changed))
        let retarget = await service.checkSource(moved, expecting: identity)
        XCTAssertEqual(retarget, .unavailable(.changed))
        try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: false)
        let replaced = await service.checkSource(fixture.source, expecting: identity)
        XCTAssertEqual(replaced, .unavailable(.changed))
    }

    func testSourceReplacementDuringEnumerationIsDetected() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        var operations = ShotDropSetupAccessOperations()
        operations.enumerateDirectory = { _ in
            try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("moved"))
            try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: false)
        }
        let service = LocalShotDropSetupAccessService(readLocationPreference: { nil }, operations: operations)
        let result = await service.checkSource(fixture.source)
        XCTAssertEqual(result, .unavailable(.changed))
    }

    func testSourceAndDestinationSymlinksAreRejectedWithoutFollowing() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
        let service = fixture.service()
        let source = await service.checkSource(alias)
        let destination = await service.checkDestination(alias)
        XCTAssertEqual(source, .unavailable(.unsafe))
        XCTAssertEqual(destination, .unavailable(.unsafe))
    }

    func testWritableDestinationOnlyNeedsReviewAndCreatesNothing() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let before = try fixture.entries()
        let service = fixture.service()
        let result = await service.checkDestination(fixture.destination)
        guard case let .needsReview(identity) = result else { return XCTFail("Read-only candidate must still need review: \(result)") }
        XCTAssertEqual(identity.path, fixture.destination.path)
        XCTAssertEqual(try fixture.entries(), before)
    }

    func testMissingDefaultDestinationIsNotCreated() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let defaultDestination = fixture.root.appendingPathComponent("Pictures/ShotDrop", isDirectory: true)
        let before = try fixture.entries()
        let result = await fixture.service().checkDestination(defaultDestination)
        XCTAssertEqual(result, .unavailable(.missing))
        XCTAssertEqual(try fixture.entries(), before)
    }

    func testDestinationDeniedAndUnsupportedChecksDoNotWriteProbes() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let before = try fixture.entries()
        var operations = ShotDropSetupAccessOperations()
        operations.checkDestinationWritable = { _ in throw ShotDropSetupAccessIssue.denied }
        let denied = LocalShotDropSetupAccessService(readLocationPreference: { nil }, operations: operations)
        let deniedResult = await denied.checkDestination(fixture.destination)
        XCTAssertEqual(deniedResult, .unavailable(.denied))
        operations.checkDestinationWritable = { _ in }
        operations.inspectDestination = { _ in throw ShotDropSetupAccessIssue.unsupported }
        let unsupported = LocalShotDropSetupAccessService(readLocationPreference: { nil }, operations: operations)
        let unsupportedResult = await unsupported.checkDestination(fixture.destination)
        XCTAssertEqual(unsupportedResult, .unavailable(.unsupported))
        XCTAssertEqual(try fixture.entries(), before)
    }

    func testDestinationChecksSeparationAndPinnedSourceWhenAvailable() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        guard case let .accessible(identity) = await service.checkSource(fixture.source) else {
            return XCTFail("Fixture must be accessible")
        }
        let valid = await service.checkDestination(fixture.destination, source: fixture.source, sourceIdentity: identity)
        guard case .needsReview = valid else { return XCTFail("Separated candidate still needs review") }
        let same = await service.checkDestination(fixture.source, source: fixture.source, sourceIdentity: identity)
        XCTAssertEqual(same, .unavailable(.unsafe))
        let ancestor = await service.checkDestination(fixture.root, source: fixture.source, sourceIdentity: identity)
        XCTAssertEqual(ancestor, .unavailable(.unsafe))
        let unpinned = await service.checkDestination(fixture.destination, source: fixture.source)
        XCTAssertEqual(unpinned, .unavailable(.changed))
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: false)
        let replaced = await service.checkDestination(fixture.destination, source: fixture.source, sourceIdentity: identity)
        XCTAssertEqual(replaced, .unavailable(.changed))
    }

    func testDestinationReplacementDuringPreflightCannotReceiveCandidateIdentity() async throws {
        let fixture = try SetupAccessFixture()
        defer { fixture.remove() }
        var operations = ShotDropSetupAccessOperations()
        operations.inspectDestination = { _ in
            try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("old-destination"))
            try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        }
        let service = LocalShotDropSetupAccessService(readLocationPreference: { nil }, operations: operations)
        let result = await service.checkDestination(fixture.destination)
        XCTAssertEqual(result, .unavailable(.changed))
    }
}

private struct SetupAccessFixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ShotDropSetup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        guard let canonical = realpath(temporary.path, nil) else {
            throw POSIXError(.EIO)
        }
        defer { free(canonical) }
        root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    }

    func service() -> LocalShotDropSetupAccessService {
        var operations = ShotDropSetupAccessOperations()
        // Host volume classification is separately covered by ScreenshotStagingVolumeTests.
        // This seam avoids making setup state tests depend on physical host drive policy.
        operations.inspectDestination = { _ in }
        return LocalShotDropSetupAccessService(readLocationPreference: { nil }, operations: operations)
    }

    func entries() throws -> [String] { try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class SetupAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0
    private var recordedMainThread = false
    var count: Int { lock.withLock { recordedCount } }
    var wasOnMainThread: Bool { lock.withLock { recordedMainThread } }

    func record() {
        lock.withLock {
            recordedCount += 1
            recordedMainThread = recordedMainThread || Thread.isMainThread
        }
    }
}
