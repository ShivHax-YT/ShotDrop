import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ShotDrop

/// Foundation may preserve /var as an alias on macOS; pool fixtures require the
/// actual filesystem path because admission deliberately rejects aliased parents.
func resolvedStagingTemporaryDirectory() throws -> URL {
    let temporary = FileManager.default.temporaryDirectory
    guard let resolved = realpath(temporary.path, nil) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

func installStagingInheritedReadACL(at directory: URL) throws {
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/bin/chmod")
    command.arguments = ["+a", "everyone allow read,readattr,readextattr,readsecurity,file_inherit", directory.path]
    let errors = Pipe()
    command.standardError = errors
    try command.run()
    command.waitUntilExit()
    guard command.terminationStatus == 0 else {
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTFail("Could not install fixture destination ACL: \(detail)")
        throw CocoaError(.fileWriteUnknown)
    }
}

/// Darwin returns ENOENT for an absent extended ACL even when the file exists.
func stagingACLText(at url: URL) throws -> String {
    guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
        if errno == ENOENT { return "" }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var length = 0
    guard let text = acl_to_text(acl, &length) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { acl_free(UnsafeMutableRawPointer(text)) }
    return String(cString: text).components(separatedBy: .newlines)
        .filter { !$0.isEmpty && !$0.hasPrefix("!#acl") }.joined(separator: "\n")
}

func stagingTestMode(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
}

func stagingTestAttributeHashes(at url: URL) throws -> [String: Data] {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    return try BoundedScreenshotCopy.attributes(descriptor)
}

final class ScreenshotStagingIntegrationTests: XCTestCase {
    func testMissingReviewedDestinationPausesWithoutCreatingReplacement() throws {
        let fixture = try StagingIntegrationFixture()
        defer { fixture.cleanUp() }
        let initialSlots = try fixture.slotIdentities()
        let baselines = try fixture.slots.map { try stagingTestAttributeHashes(at: $0) }
        let moved = fixture.root.appendingPathComponent("moved-destination", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.destination, to: moved)
        let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool)
        XCTAssertThrowsError(try fileSystem.stageCopy(
            source: fixture.source, destinationRoot: fixture.destination,
            subdirectories: [], expectedIdentity: fixture.sourceIdentity
        )) { error in
            XCTAssertEqual((error as? ScreenshotCopyFailure)?.code, .stagingPaused)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
        XCTAssertEqual(try fixture.slotIdentities(), initialSlots)
        for (index, slot) in fixture.slots.enumerated() {
            XCTAssertEqual(try Data(contentsOf: slot), Data())
            XCTAssertEqual(try stagingTestAttributeHashes(at: slot), baselines[index])
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }

    func testReplacedDestinationPausesUntilExplicitReviewUpdateWithoutReplacingSlots() throws {
        let fixture = try StagingIntegrationFixture()
        defer { fixture.cleanUp() }
        let initialSlots = try fixture.slotIdentities()
        let moved = fixture.root.appendingPathComponent("moved-destination", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.destination, to: moved)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool)
        XCTAssertThrowsError(try fileSystem.stageCopy(
            source: fixture.source, destinationRoot: fixture.destination,
            subdirectories: [], expectedIdentity: fixture.sourceIdentity
        )) { error in
            XCTAssertEqual((error as? ScreenshotCopyFailure)?.code, .stagingPaused)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        for slot in fixture.slots { XCTAssertEqual(try Data(contentsOf: slot), Data()) }
        try fixture.pool.updateDestinationReview(
            at: fixture.destination, forRoot: fixture.poolRoot,
            sourceDirectory: fixture.sourceDirectory, ordinaryLocalDestinationReviewed: true
        )
        let staged = try fileSystem.stageCopy(
            source: fixture.source, destinationRoot: fixture.destination,
            subdirectories: [], expectedIdentity: fixture.sourceIdentity
        )
        let receipt = try staged.publish(named: "reviewed.png")
        XCTAssertEqual(receipt.housekeeping, .clean)
        XCTAssertEqual(try Data(contentsOf: receipt.destinationURL), fixture.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
        XCTAssertEqual(try fixture.slotIdentities(), initialSlots)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.poolRoot.path).sorted(),
                       ["slot-0.stage", "slot-1.stage"])
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }

    func testDestinationACLInheritanceDoesNotContaminateReusablePrivateSlots() async throws {
        let fixture = try StagingIntegrationFixture()
        defer { fixture.cleanUp() }
        let identities = try fixture.slotIdentities()
        let baselines = try fixture.slots.map { try stagingTestAttributeHashes(at: $0) }
        let originalACL = try stagingACLText(at: fixture.source)
        let originalMode = try stagingTestMode(at: fixture.source)
        try installStagingInheritedReadACL(at: fixture.destination)
        XCTAssertTrue(try stagingACLText(at: fixture.destination).contains("file_inherit"))
        let organizer = ScreenshotOrganizer(fileSystem: LocalScreenshotOrganizationFileSystem(pool: fixture.pool))
        for name in ["first", "second"] {
            let receipt = try await organizer.organize(fixture.request(template: name))
            XCTAssertEqual(receipt.housekeeping, .clean)
            XCTAssertEqual(try Data(contentsOf: receipt.destinationURL), fixture.bytes)
            XCTAssertEqual(try stagingTestMode(at: receipt.destinationURL), 0o600)
            XCTAssertTrue(try stagingACLText(at: receipt.destinationURL)
                .contains("allow,inherited:read,readattr,readextattr,readsecurity"))
            for (index, slot) in fixture.slots.enumerated() {
                XCTAssertEqual(try stagingACLText(at: slot), "")
                XCTAssertEqual(try stagingTestMode(at: slot), 0o600)
                XCTAssertEqual(try Data(contentsOf: slot), Data())
                XCTAssertEqual(try stagingTestAttributeHashes(at: slot), baselines[index])
            }
        }
        XCTAssertEqual(try fixture.slotIdentities(), identities)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(try stagingACLText(at: fixture.source), originalACL)
        XCTAssertEqual(try stagingTestMode(at: fixture.source), originalMode)
    }

    func testTenThousandSuccessfulTransactionsReuseTwoFixedSlotInodes() throws {
        let fixture = try StagingIntegrationFixture()
        defer { fixture.cleanUp() }
        let initialSlots = try fixture.slotIdentities()
        let initialRootEntries = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        let expectedHash = Data(SHA256.hash(data: fixture.bytes))
        let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool)
        let clock = ContinuousClock()
        let workloadStart = clock.now
        var transactionSeconds = [Double]()
        transactionSeconds.reserveCapacity(10_000)
        for iteration in 0..<10_000 {
            try autoreleasepool {
                let transactionStart = clock.now
                let staged = try fileSystem.stageCopy(
                    source: fixture.source, destinationRoot: fixture.destination,
                    subdirectories: [], expectedIdentity: fixture.sourceIdentity
                )
                let output = try staged.publish(named: "transaction.png")
                guard case .clean = output.housekeeping else {
                    XCTFail("Successful transaction \(iteration) unexpectedly retired its slot")
                    throw StagingIntegrationFailure.unexpectedHousekeeping
                }
                staged.discard()
                let duration = transactionStart.duration(to: clock.now).components
                transactionSeconds.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: output.destinationURL))), expectedHash,
                               "Output hash at transaction \(iteration)")
                XCTAssertEqual(try fixture.slotIdentities(), initialSlots, "Slot inode changed at transaction \(iteration)")
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.poolRoot.path).sorted(),
                               ["slot-0.stage", "slot-1.stage"])
                // The output is an explicitly disposable fixture; keep workload storage bounded.
                try FileManager.default.removeItem(at: output.destinationURL)
            }
            if (iteration + 1).isMultiple(of: 1_000) {
                print("STAGING_WORKLOAD completed=\(iteration + 1) fixedSlots=2")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted(), initialRootEntries)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        XCTAssertEqual(try fixture.slotIdentities(), initialSlots)
        for slot in fixture.slots { XCTAssertEqual(try Data(contentsOf: slot), Data()) }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        let samples = transactionSeconds.sorted()
        let duration = workloadStart.duration(to: clock.now).components
        let total = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        print("STAGING_WORKLOAD transactions=10000 totalSeconds=\(total) transactionMeanSeconds=\(samples.reduce(0, +) / 10000) transactionP50Seconds=\(samples[4999]) transactionP95Seconds=\(samples[9499]) transactionP99Seconds=\(samples[9899]) transactionMaxSeconds=\(samples[9999])")
    }

    func testOrganizerHoldsLeaseAcrossAwaitAndCancellationRetiresOnlyHeldSlot() async throws {
        let fixture = try StagingIntegrationFixture()
        defer { fixture.cleanUp() }
        let initialSlots = try fixture.slotIdentities()
        let gate = StagingPublicationGate()
        let suspended = expectation(description: "Organizer reached awaited publication hook")
        let firstOrganizer = ScreenshotOrganizer(fileSystem: LocalScreenshotOrganizationFileSystem(pool: fixture.pool))
        let request = fixture.request()
        let first = Task {
            try await firstOrganizer.organize(request) { _ in
                suspended.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [suspended], timeout: 10)
        let heldSlot = try XCTUnwrap(fixture.slots.first { (try? Data(contentsOf: $0)) == fixture.bytes })
        let heldBytes = try Data(contentsOf: heldSlot)
        do {
            _ = try await firstOrganizer.organize(fixture.request(template: "reentrant"))
            XCTFail("Actor reentrancy must not start another transaction while its hook is suspended")
        } catch {
            XCTAssertEqual((error as? ScreenshotCopyFailure)?.code, .stagingPaused)
            XCTAssertEqual(try Data(contentsOf: heldSlot), heldBytes)
        }
        let otherPool = ScreenshotStagingPool(registryDirectory: fixture.registryDirectory)
        let secondOrganizer = ScreenshotOrganizer(fileSystem: LocalScreenshotOrganizationFileSystem(pool: otherPool))
        do {
            _ = try await secondOrganizer.organize(fixture.request(template: "competing"))
            XCTFail("A second pool instance must not acquire a lease while publication is suspended")
        } catch {
            XCTAssertEqual((error as? ScreenshotCopyFailure)?.code, .stagingPaused)
            XCTAssertEqual(try Data(contentsOf: heldSlot), heldBytes)
            XCTAssertEqual(try fixture.slotIdentities(), initialSlots)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        }
        first.cancel()
        await gate.release()
        do {
            _ = try await first.value
            XCTFail("Expected cancelled publication")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: heldSlot), fixture.bytes, "Cancellation must preserve the retired stage bytes")
        XCTAssertEqual(try fixture.slotIdentities(), initialSlots)
        let retried = try await secondOrganizer.organize(fixture.request(template: "retry"))
        guard case .clean = retried.housekeeping else { return XCTFail("The remaining clean slot should support retry") }
        XCTAssertEqual(try Data(contentsOf: retried.destinationURL), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: heldSlot), fixture.bytes, "Retry must not reset the retired slot")
        XCTAssertEqual(try fixture.slotIdentities(), initialSlots)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
    }

    func testVerifiedSaveRemainsSavedWhenHousekeepingRetiresReplacedSlot() async throws {
        let fixture = try StagingIntegrationFixture()
        defer { fixture.cleanUp() }
        let parked = fixture.root.appendingPathComponent("parked-owned-stage")
        let replacement = Data("unrelated replacement at cleanup boundary".utf8)
        let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, race: { point, stageURL in
            guard point == .afterStageIdentityCheckBeforeCleanup else { return }
            try FileManager.default.moveItem(at: stageURL, to: parked)
            try replacement.write(to: stageURL)
        })
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
        let outcome = await service.save(ScreenshotSaveRequest(
            organization: fixture.request(), sourceDirectoryURL: fixture.sourceDirectory,
            destinationAccess: .userApproved
        ))
        guard case .saved(let receipt) = outcome else { return XCTFail("Cleanup retirement must not erase a verified saved receipt") }
        guard case .retired = receipt.housekeeping else { return XCTFail("The substituted stage path must retire") }
        XCTAssertEqual(try Data(contentsOf: receipt.destinationURL), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: parked), fixture.bytes)
        let replacementSlot = try XCTUnwrap(fixture.slots.first { (try? Data(contentsOf: $0)) == replacement })
        XCTAssertEqual(try Data(contentsOf: replacementSlot), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["capture.png"])
    }
}

private actor StagingPublicationGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private enum StagingIntegrationFailure: Error { case unexpectedHousekeeping }

private struct StagingIntegrationFixture {
    let root: URL
    let sourceDirectory: URL
    let source: URL
    let destination: URL
    let registryDirectory: URL
    let poolRoot: URL
    let pool: ScreenshotStagingPool
    let sourceIdentity: ScreenshotFileIdentity
    let bytes = Data((0..<257).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    var slots: [URL] { ["slot-0.stage", "slot-1.stage"].map { poolRoot.appendingPathComponent($0) } }

    init() throws {
        root = try resolvedStagingTemporaryDirectory().appendingPathComponent("ShotDropStagingIntegration-\(UUID().uuidString)", isDirectory: true)
        sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        source = sourceDirectory.appendingPathComponent("original.png")
        destination = root.appendingPathComponent("destination", isDirectory: true)
        registryDirectory = root.appendingPathComponent("registry", isDirectory: true)
        poolRoot = root.appendingPathComponent("pool", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try bytes.write(to: source)
        sourceIdentity = try XCTUnwrap(LocalScreenshotFileSystem().identity(at: source))
        pool = ScreenshotStagingPool(registryDirectory: registryDirectory)
        try pool.initialize(legacyArtifactsAccountedFor: true)
        try pool.registerRoot(at: poolRoot, sourceDirectory: sourceDirectory, destinationDirectory: destination,
                              ordinaryLocalDestinationReviewed: true)
    }

    func request(template: String = "capture") -> ScreenshotOrganizationRequest {
        ScreenshotOrganizationRequest(
            sourceURL: source, destinationRoot: destination, template: template,
            namingContext: ScreenshotNamingContext(appName: "Fixture", capturedAt: Date(timeIntervalSince1970: 0),
                                                   timeZone: TimeZone(secondsFromGMT: 0)!),
            expectedIdentity: sourceIdentity
        )
    }

    func slotIdentities() throws -> [String: UInt64] {
        try Dictionary(uniqueKeysWithValues: slots.map { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
            return (url.lastPathComponent, inode)
        })
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
