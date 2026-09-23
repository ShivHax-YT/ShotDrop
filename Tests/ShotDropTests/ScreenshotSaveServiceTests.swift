import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

final class ScreenshotSaveServiceTests: XCTestCase {
    func testCloneFailuresReportSpecificReasonsAndPreserveOriginalAndSentinels() async throws {
        let cases: [(POSIXErrorCode, ScreenshotSaveFailure.Reason)] = [
            (.ENOTSUP, .unsupportedFilesystem), (.EXDEV, .crossDeviceClone),
            (.ENOSPC, .noSpace), (.EACCES, .permissionDenied), (.EPERM, .permissionDenied)
        ]
        for (code, reason) in cases {
            let fixture = try SaveFixture()
            defer { fixture.cleanUp() }
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let fileSystem = LocalScreenshotOrganizationFileSystem(clone: { _, _, _ in
                calls.withLock { $0 += 1 }
                errno = code.rawValue
                return -1
            })
            let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
            let outcome = await service.save(try fixture.request())
            let failure = try failed(outcome)
            XCTAssertEqual(failure.reason, reason, "errno \(code)")
            XCTAssertEqual(failure.originalURL, fixture.source)
            XCTAssertEqual(failure.originalStatus, .available)
            XCTAssertTrue(failure.actions.contains(.revealOriginal))
            XCTAssertTrue(failure.actions.contains(.chooseDestination))
            XCTAssertNil(failure.recoverableDestination)
            XCTAssertEqual(calls.withLock { $0 }, 1)
            try fixture.assertPreserved()
            XCTAssertEqual(try fixture.visibleDestinationEntries(), ["unrelated.txt"])
        }
    }

    func testVerificationFailureCannotBecomeSavedSuccess() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let destination = fixture.destination
        let fileSystem = LocalScreenshotOrganizationFileSystem(fault: { phase in
            guard phase == .beforeVerification else { return }
            let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                at: destination, includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix(".shotdrop-staging-") })
            try Data("corrupted stage".utf8).write(to: directory.appendingPathComponent("screenshot.stage"))
        })
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
        let failure = try failed(await service.save(try fixture.request()))
        XCTAssertEqual(failure.reason, .verificationFailed)
        XCTAssertEqual(failure.originalStatus, .available)
        XCTAssertTrue(failure.actions.contains(.revealOriginal))
        XCTAssertNil(failure.recoverableDestination)
        try fixture.assertPreserved()
        XCTAssertEqual(try fixture.visibleDestinationEntries(), ["unrelated.txt"])
    }

    func testPostPublicationFailureRemainsFailedAndReportsSurvivingCopy() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let fileSystem = LocalScreenshotOrganizationFileSystem(fault: { phase in
            if phase == .afterPublish {
                throw ScreenshotCopyFailure(code: .verificationFailed, detail: "Injected final verification failure")
            }
        })
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
        let failure = try failed(await service.save(try fixture.request()))
        XCTAssertEqual(failure.reason, .verificationFailed)
        XCTAssertEqual(failure.originalStatus, .available)
        XCTAssertTrue(failure.actions.contains(.revealOriginal))
        let recovery = try XCTUnwrap(failure.recoverableDestination)
        XCTAssertEqual(recovery, fixture.destination.appendingPathComponent("capture.png"))
        XCTAssertEqual(try Data(contentsOf: recovery), fixture.bytes)
        XCTAssertEqual(try fixture.visibleDestinationEntries(), ["capture.png", "unrelated.txt"])
        try fixture.assertPreserved()
    }

    func testCollisionSuffixSuccessPreservesAllExistingFiles() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let occupied = ["capture.png", "capture (2).png"]
        for name in occupied {
            try Data(name.utf8).write(to: fixture.destination.appendingPathComponent(name))
        }
        let result = try saved(await ScreenshotSaveService().save(try fixture.request()))
        XCTAssertEqual(result.destinationURL.lastPathComponent, "capture (3).png")
        XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.bytes)
        XCTAssertFalse(result.sourceWasRemoved)
        for name in occupied {
            XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(name)), Data(name.utf8))
        }
        try fixture.assertPreserved()
    }

    func testCollisionAtCloneBoundaryRetriesWithoutReplacingCompetingFile() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let destination = fixture.destination
        let competing = Data("another writer won the destination name".utf8)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let fileSystem = LocalScreenshotOrganizationFileSystem(clone: { sourceFD, directoryFD, name in
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 1 {
                do { try competing.write(to: destination.appendingPathComponent(name)) }
                catch { XCTFail("Could not establish collision fixture: \(error)") }
                errno = EEXIST
                return -1
            }
            return fclonefileat(sourceFD, directoryFD, name, UInt32(CLONE_ACL))
        })
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
        let result = try saved(await service.save(try fixture.request()))
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(result.destinationURL.lastPathComponent, "capture (2).png")
        XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent("capture.png")), competing)
        try fixture.assertPreserved()
    }

    func testCollisionExhaustionReportsFailureAndLeavesExistingBytesIntact() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let occupied = ["capture.png", "capture (2).png"]
        for name in occupied {
            try Data(name.utf8).write(to: fixture.destination.appendingPathComponent(name))
        }
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(collisionLimit: occupied.count))
        let failure = try failed(await service.save(try fixture.request()))
        XCTAssertEqual(failure.reason, .collision)
        XCTAssertEqual(failure.originalStatus, .available)
        XCTAssertTrue(failure.actions.contains(.revealOriginal))
        XCTAssertNil(failure.recoverableDestination)
        for name in occupied {
            XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(name)), Data(name.utf8))
        }
        XCTAssertEqual(Set(try fixture.visibleDestinationEntries()), Set(occupied + ["unrelated.txt"]))
        try fixture.assertPreserved()
    }

    func testExplicitRetryOfSameSourceSucceedsAfterTransientCloneFailure() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let fileSystem = LocalScreenshotOrganizationFileSystem(clone: { sourceFD, directoryFD, name in
            let count = calls.withLock { $0 += 1; return $0 }
            if count == 1 {
                errno = ENOSPC
                return -1
            }
            return fclonefileat(sourceFD, directoryFD, name, UInt32(CLONE_ACL))
        })
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
        let request = try fixture.request()
        let first = try failed(await service.save(request))
        XCTAssertEqual(first.reason, .noSpace)
        XCTAssertTrue(first.actions.contains(.retry))
        XCTAssertEqual(first.originalStatus, .available)
        try fixture.assertPreserved()
        XCTAssertEqual(try fixture.visibleDestinationEntries(), ["unrelated.txt"])
        let second = try saved(await service.save(request))
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(second.destinationURL.lastPathComponent, "capture.png")
        XCTAssertEqual(try Data(contentsOf: second.destinationURL), fixture.bytes)
        try fixture.assertPreserved()
    }

    func testAccessExplanationGateDoesNotTouchMissingSourceOrDestination() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let parked = fixture.root.appendingPathComponent("parked-original.png")
        let originalRequest = try fixture.request()
        try FileManager.default.moveItem(at: fixture.source, to: parked)
        let absentDestination = fixture.root.appendingPathComponent("not-created", isDirectory: true)
        var organization = originalRequest.organization
        organization = ScreenshotOrganizationRequest(
            sourceURL: organization.sourceURL, destinationRoot: absentDestination,
            template: organization.template, namingContext: organization.namingContext,
            expectedIdentity: organization.expectedIdentity
        )
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let fileSystem = LocalScreenshotOrganizationFileSystem(fault: { _ in calls.withLock { $0 += 1 } })
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
        let request = ScreenshotSaveRequest(organization: organization, sourceDirectoryURL: fixture.sourceDirectory)
        let failure = try failed(await service.save(request))
        XCTAssertEqual(failure.reason, .accessRequired)
        XCTAssertEqual(failure.originalStatus, .notChecked)
        XCTAssertEqual(failure.actions, [.chooseDestination])
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertNil(failure.recoverableDestination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentDestination.path))
        XCTAssertEqual(try Data(contentsOf: parked), fixture.bytes)
        try fixture.assertSentinels()
    }

    func testEqualSourceAndDestinationRootFailsBeforeStaging() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let base = try fixture.request().organization
        let request = ScreenshotSaveRequest(
            organization: ScreenshotOrganizationRequest(
                sourceURL: base.sourceURL, destinationRoot: fixture.sourceDirectory,
                template: base.template, namingContext: base.namingContext,
                expectedIdentity: base.expectedIdentity
            ), sourceDirectoryURL: fixture.sourceDirectory, destinationAccess: .userApproved
        )
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let fileSystem = LocalScreenshotOrganizationFileSystem(fault: { _ in calls.withLock { $0 += 1 } })
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
        let failure = try failed(await service.save(request))
        XCTAssertEqual(failure.reason, .destinationOverlap)
        XCTAssertTrue(failure.actions.contains(.chooseDestination))
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.sourceDirectory.path).sorted(),
                       ["original.png", "source-sentinel.txt"])
        try fixture.assertPreserved()
    }

    func testMismatchedDeclaredSourceCannotBypassDestinationOverlapCheck() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let declaredSource = fixture.root.appendingPathComponent("declared-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: declaredSource, withIntermediateDirectories: false)
        let base = try fixture.request().organization
        let request = ScreenshotSaveRequest(
            organization: ScreenshotOrganizationRequest(
                sourceURL: base.sourceURL, destinationRoot: fixture.sourceDirectory,
                template: base.template, namingContext: base.namingContext,
                expectedIdentity: base.expectedIdentity
            ), sourceDirectoryURL: declaredSource, destinationAccess: .userApproved
        )
        let sourceEntries = try FileManager.default.contentsOfDirectory(atPath: fixture.sourceDirectory.path).sorted()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let fileSystem = LocalScreenshotOrganizationFileSystem(fault: { _ in calls.withLock { $0 += 1 } })
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
        let failure = try failed(await service.save(request))
        XCTAssertEqual(failure.reason, .sourceOutsideFolder)
        XCTAssertEqual(failure.originalStatus, .available)
        XCTAssertTrue(failure.actions.contains(.revealOriginal))
        XCTAssertNil(failure.recoverableDestination)
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.sourceDirectory.path).sorted(), sourceEntries)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: declaredSource.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["unrelated.txt"])
        try fixture.assertPreserved()
    }

    func testDeclaredSourceAliasToActualSourceFolderAllowsSave() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let alias = fixture.root.appendingPathComponent("source-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.sourceDirectory)
        let request = ScreenshotSaveRequest(
            organization: try fixture.request().organization,
            sourceDirectoryURL: alias, destinationAccess: .userApproved
        )
        let result = try saved(await ScreenshotSaveService().save(request))
        XCTAssertEqual(result.destinationURL, fixture.destination.appendingPathComponent("capture.png"))
        XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), fixture.sourceDirectory.path)
        try fixture.assertPreserved()
    }

    func testDeclaredSourceAliasChangedDuringPublicationHookFailsBeforePublication() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let alias = fixture.root.appendingPathComponent("source-alias", isDirectory: true)
        let parkedAlias = fixture.root.appendingPathComponent("original-source-alias", isDirectory: true)
        let differentDirectory = fixture.root.appendingPathComponent("different-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: differentDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.sourceDirectory)
        let request = ScreenshotSaveRequest(
            organization: try fixture.request().organization,
            sourceDirectoryURL: alias, destinationAccess: .userApproved
        )
        let outcome = await ScreenshotSaveService().save(request) { _ in
            try FileManager.default.moveItem(at: alias, to: parkedAlias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: differentDirectory)
        }
        let failure = try failed(outcome)
        XCTAssertEqual(failure.reason, .sourceOutsideFolder)
        XCTAssertEqual(failure.originalStatus, .available)
        XCTAssertTrue(failure.actions.contains(.revealOriginal))
        XCTAssertNil(failure.recoverableDestination)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), differentDirectory.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: parkedAlias.path), fixture.sourceDirectory.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: differentDirectory.path), [])
        XCTAssertEqual(try fixture.visibleDestinationEntries(), ["unrelated.txt"])
        try fixture.assertPreserved()
    }

    func testMissingOriginalDoesNotOfferRevealOrClaimAvailable() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let request = try fixture.request()
        let parked = fixture.root.appendingPathComponent("parked-original.png")
        try FileManager.default.moveItem(at: fixture.source, to: parked)
        let failure = try failed(await ScreenshotSaveService().save(request))
        XCTAssertEqual(failure.reason, .sourceUnavailable)
        XCTAssertEqual(failure.originalStatus, .unavailable)
        XCTAssertFalse(failure.actions.contains(.revealOriginal))
        XCTAssertNil(failure.recoverableDestination)
        XCTAssertEqual(try Data(contentsOf: parked), fixture.bytes)
        XCTAssertEqual(try fixture.visibleDestinationEntries(), ["unrelated.txt"])
        try fixture.assertSentinels()
    }

    func testOriginalMovedDuringFailedSaveDoesNotOfferReveal() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let source = fixture.source
        let parked = fixture.root.appendingPathComponent("parked-original.png")
        let fileSystem = LocalScreenshotOrganizationFileSystem(clone: { _, _, _ in
            do { try FileManager.default.moveItem(at: source, to: parked) }
            catch { XCTFail("Could not move fixture source: \(error)") }
            errno = ENOSPC
            return -1
        })
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
        let failure = try failed(await service.save(try fixture.request()))
        XCTAssertEqual(failure.reason, .noSpace)
        XCTAssertEqual(failure.originalStatus, .unavailable)
        XCTAssertFalse(failure.actions.contains(.revealOriginal))
        XCTAssertNil(failure.recoverableDestination)
        XCTAssertEqual(try Data(contentsOf: parked), fixture.bytes)
        XCTAssertEqual(try fixture.visibleDestinationEntries(), ["unrelated.txt"])
        try fixture.assertSentinels()
    }

    func testReplacementAtOriginalPathIsReportedChangedAndSurvives() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let request = try fixture.request()
        let parked = fixture.root.appendingPathComponent("parked-original.png")
        try FileManager.default.moveItem(at: fixture.source, to: parked)
        let replacement = Data("a different file now owns the original path".utf8)
        try replacement.write(to: fixture.source)
        let failure = try failed(await ScreenshotSaveService().save(request))
        XCTAssertEqual(failure.reason, .sourceChanged)
        XCTAssertEqual(failure.originalStatus, .changed)
        XCTAssertFalse(failure.actions.contains(.revealOriginal))
        XCTAssertNil(failure.recoverableDestination)
        XCTAssertEqual(try Data(contentsOf: fixture.source), replacement)
        XCTAssertEqual(try Data(contentsOf: parked), fixture.bytes)
        XCTAssertEqual(try fixture.visibleDestinationEntries(), ["unrelated.txt"])
        try fixture.assertSentinels()
    }

    func testInPlaceOriginalMutationIsReportedChangedEvenWhenIdentityIsUnchanged() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let source = fixture.source
        let changed = Data("same inode now contains changed screenshot bytes".utf8)
        let fileSystem = LocalScreenshotOrganizationFileSystem(fault: { phase in
            guard phase == .afterCopy else { return }
            let handle = try FileHandle(forWritingTo: source)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: changed)
        })
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: fileSystem))
        let request = try fixture.request()
        let failure = try failed(await service.save(request))
        XCTAssertEqual(failure.reason, .sourceChanged)
        XCTAssertEqual(failure.originalStatus, .changed)
        XCTAssertFalse(failure.actions.contains(.revealOriginal))
        XCTAssertNil(failure.recoverableDestination)
        XCTAssertEqual(try LocalScreenshotFileSystem().identity(at: source), request.organization.expectedIdentity)
        XCTAssertEqual(try Data(contentsOf: source), changed)
        XCTAssertEqual(try fixture.visibleDestinationEntries(), ["unrelated.txt"])
        try fixture.assertSentinels()
    }

    func testCancellationDuringPublicationIsSeparateFromSaveFailure() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let outcome = await ScreenshotSaveService().save(try fixture.request()) { _ in
            throw CancellationError()
        }
        guard case .cancelled(let originalURL) = outcome else {
            return XCTFail("Expected cancellation instead of saved or failed")
        }
        XCTAssertEqual(originalURL, fixture.source)
        XCTAssertEqual(try fixture.visibleDestinationEntries(), ["unrelated.txt"])
        try fixture.assertPreserved()
    }

    func testPublicationHookMutationReportsChangedOriginalBeforePublishing() async throws {
        let fixture = try SaveFixture()
        defer { fixture.cleanUp() }
        let source = fixture.source
        let changed = Data("source edited while the async publication hook was active".utf8)
        let base = try fixture.request().organization
        let request = ScreenshotSaveRequest(
            organization: ScreenshotOrganizationRequest(
                sourceURL: base.sourceURL, destinationRoot: base.destinationRoot,
                template: base.template, namingContext: base.namingContext
            ), sourceDirectoryURL: fixture.sourceDirectory, destinationAccess: .userApproved
        )
        XCTAssertNil(request.organization.expectedIdentity)
        let outcome = await ScreenshotSaveService().save(request) { _ in
            let handle = try FileHandle(forWritingTo: source)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: changed)
        }
        let failure = try failed(outcome)
        XCTAssertEqual(failure.reason, .sourceChanged)
        XCTAssertEqual(failure.originalStatus, .changed)
        XCTAssertFalse(failure.actions.contains(.revealOriginal))
        XCTAssertNil(failure.recoverableDestination)
        XCTAssertEqual(try LocalScreenshotFileSystem().identity(at: source), fixture.initialIdentity)
        XCTAssertEqual(try Data(contentsOf: source), changed)
        XCTAssertEqual(try fixture.visibleDestinationEntries(), ["unrelated.txt"])
        try fixture.assertSentinels()
    }

    private func failed(_ outcome: ScreenshotSaveOutcome, file: StaticString = #filePath,
                        line: UInt = #line) throws -> ScreenshotSaveFailure {
        guard case .failed(let failure) = outcome else {
            XCTFail("Expected failed save outcome", file: file, line: line)
            throw UnexpectedOutcome()
        }
        return failure
    }

    private func saved(_ outcome: ScreenshotSaveOutcome, file: StaticString = #filePath,
                       line: UInt = #line) throws -> ScreenshotOrganizationResult {
        guard case .saved(let result) = outcome else {
            XCTFail("Expected saved outcome", file: file, line: line)
            throw UnexpectedOutcome()
        }
        return result
    }

    private struct UnexpectedOutcome: Error {}
}

private struct SaveFixture {
    let root: URL
    let sourceDirectory: URL
    let source: URL
    let destination: URL
    let bytes: Data
    let initialIdentity: ScreenshotFileIdentity
    private let sentinelBytes = Data("unrelated user file must survive every save operation".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotDropSaveService-\(UUID().uuidString)", isDirectory: true)
        sourceDirectory = root.appendingPathComponent("screenshots", isDirectory: true)
        source = sourceDirectory.appendingPathComponent("original.png")
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let buffer = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        bytes = buffer as Data
        try bytes.write(to: source)
        initialIdentity = try XCTUnwrap(LocalScreenshotFileSystem().identity(at: source))
        try sentinelBytes.write(to: sourceDirectory.appendingPathComponent("source-sentinel.txt"))
        try sentinelBytes.write(to: destination.appendingPathComponent("unrelated.txt"))
    }

    func request() throws -> ScreenshotSaveRequest {
        ScreenshotSaveRequest(
            organization: ScreenshotOrganizationRequest(
                sourceURL: source, destinationRoot: destination, template: "capture",
                namingContext: ScreenshotNamingContext(
                    appName: "Notes", capturedAt: Date(timeIntervalSince1970: 1_790_078_400),
                    timeZone: TimeZone(secondsFromGMT: 0)!
                ), expectedIdentity: initialIdentity
            ), sourceDirectoryURL: sourceDirectory, destinationAccess: .userApproved
        )
    }

    func assertPreserved(file: StaticString = #filePath, line: UInt = #line) throws {
        let current = try Data(contentsOf: source)
        XCTAssertEqual(current, bytes, file: file, line: line)
        XCTAssertEqual(Data(SHA256.hash(data: current)), Data(SHA256.hash(data: bytes)), file: file, line: line)
        XCTAssertEqual(try LocalScreenshotFileSystem().identity(at: source), initialIdentity, file: file, line: line)
        try assertSentinels(file: file, line: line)
    }

    func assertSentinels(file: StaticString = #filePath, line: UInt = #line) throws {
        for url in [sourceDirectory.appendingPathComponent("source-sentinel.txt"),
                    destination.appendingPathComponent("unrelated.txt")] {
            XCTAssertEqual(try Data(contentsOf: url), sentinelBytes, file: file, line: line)
        }
    }

    func visibleDestinationEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: destination.path)
            .filter { !$0.hasPrefix(".shotdrop-staging-") }.sorted()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
