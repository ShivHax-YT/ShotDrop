import Darwin
import Foundation
import XCTest
@testable import ShotDrop

final class LocalScreenshotOrganizationFileSystemTests: XCTestCase {
    func testRealCloneInheritsDestinationACLWhilePrivateStageRemainsUnchanged() throws {
        try withFixture { fixture in
            let slots = ["slot-0.stage", "slot-1.stage"].map { fixture.poolRoot.appendingPathComponent($0) }
            let baselines = try slots.map { try stagingTestAttributeHashes(at: $0) }
            let originalACL = try stagingACLText(at: fixture.source)
            let originalMode = try stagingTestMode(at: fixture.source)
            try installStagingInheritedReadACL(at: fixture.destination)
            let destinationACL = try stagingACLText(at: fixture.destination)
            XCTAssertTrue(destinationACL.contains("file_inherit"))
            let staged = try fixture.stage()
            let stageURL = try Self.stageURL(in: fixture.poolRoot)
            XCTAssertEqual(try stagingACLText(at: stageURL), "")
            XCTAssertEqual(try stagingTestMode(at: stageURL), 0o600)
            let result = try staged.publish(named: "inherited.png")
            XCTAssertEqual(result.housekeeping, .clean)
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.bytes)
            XCTAssertNotEqual(result.identity, staged.identity)
            // POSIX 0600 does not negate grants inherited from the chosen destination.
            XCTAssertEqual(try stagingTestMode(at: result.destinationURL), 0o600)
            XCTAssertTrue(try stagingACLText(at: result.destinationURL)
                .contains("allow,inherited:read,readattr,readextattr,readsecurity"))
            staged.discard()
            for (index, slot) in slots.enumerated() {
                XCTAssertEqual(try stagingACLText(at: slot), "")
                XCTAssertEqual(try stagingTestMode(at: slot), 0o600)
                XCTAssertEqual(try Data(contentsOf: slot), Data())
                XCTAssertEqual(try stagingTestAttributeHashes(at: slot), baselines[index])
            }
            XCTAssertEqual(try stagingACLText(at: fixture.destination), destinationACL)
            XCTAssertEqual(try stagingACLText(at: fixture.source), originalACL)
            XCTAssertEqual(try stagingTestMode(at: fixture.source), originalMode)
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.bytes)
            try fixture.assertOriginal()
        }
    }

    func testPostPublicationDirectoryMoveReturnsVerifiedSurvivingPath() throws {
        try withFixture { fixture in
            let destination = fixture.destination
            let moved = fixture.root.appendingPathComponent("moved-destination", isDirectory: true)
            let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, fault: { phase in
                if phase == .afterPublish {
                    try FileManager.default.moveItem(at: destination, to: moved)
                }
            })
            let stage = try fileSystem.stageCopy(
                source: fixture.source, destinationRoot: destination,
                subdirectories: [], expectedIdentity: nil
            )
            let error = try XCTUnwrap(failure { try stage.publish(named: "published.png") })
            XCTAssertEqual(error.posixCode, ENOENT)
            let recovery = try XCTUnwrap(error.recoverableDestination)
            XCTAssertEqual(recovery.resolvingSymlinksInPath(),
                           moved.appendingPathComponent("published.png").resolvingSymlinksInPath())
            XCTAssertEqual(try Data(contentsOf: recovery), fixture.bytes)
            try fixture.assertOriginal()
            stage.discard()
            XCTAssertEqual(try Data(contentsOf: recovery), fixture.bytes)
        }
    }

    func testCrossDeviceSpaceAndPermissionErrorsPreserveOriginal() throws {
        for code: POSIXErrorCode in [.EXDEV, .ENOSPC, .EACCES] {
            try withFixture { fixture in
                let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, fault: { phase in
                    if phase == .afterCopy { throw POSIXError(code) }
                })
                XCTAssertThrowsError(try fileSystem.stageCopy(
                    source: fixture.source, destinationRoot: fixture.destination,
                    subdirectories: [], expectedIdentity: nil
                ))
                try fixture.assertOriginal()
                XCTAssertEqual(try entries(fixture.destination), [])
            }
        }
    }

    func testCloneSyscallFailuresPreserveOriginalAndNeverPublish() throws {
        for code: POSIXErrorCode in [.ENOTSUP, .EXDEV, .ENOSPC, .EACCES] {
            try withFixture { fixture in
                let sentinelURL = fixture.destination.appendingPathComponent("unrelated.png")
                let sentinelBytes = Data("existing user file must survive failed publication".utf8)
                try sentinelBytes.write(to: sentinelURL)
                let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, clone: { _, _, _ in
                    errno = code.rawValue
                    return -1
                })
                let stage = try fileSystem.stageCopy(
                    source: fixture.source, destinationRoot: fixture.destination,
                    subdirectories: [], expectedIdentity: nil
                )
                let stageURL = try Self.stageURL(in: fixture.poolRoot)
                XCTAssertEqual(try Data(contentsOf: stageURL), fixture.bytes)
                let error = try XCTUnwrap(failure { try stage.publish(named: "published.png") })
                XCTAssertEqual(error.code, code == .EACCES ? .permissionDenied : .destinationUnavailable)
                XCTAssertEqual(error.posixCode, code.rawValue)
                XCTAssertNil(error.recoverableDestination)
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: fixture.destination.appendingPathComponent("published.png").path
                ))
                stage.discard()
                XCTAssertEqual(try Data(contentsOf: stageURL), fixture.bytes)
                XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelBytes)
                XCTAssertEqual(try entries(fixture.destination), ["unrelated.png"])
                try fixture.assertOriginal()
            }
        }
    }

    func testDirectoryFailurePreservesNestedPOSIXCodeOverCocoaFallback() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let intermediate = NSError(domain: "FixtureWrapper", code: 7, userInfo: [NSUnderlyingErrorKey: posix])
        let outer = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                            userInfo: [NSUnderlyingErrorKey: intermediate])
        let failure = LocalScreenshotOrganizationFileSystem.directoryCreationFailure(outer)
        XCTAssertEqual(failure.posixCode, ENOSPC)
        XCTAssertEqual(failure.code, .destinationUnavailable)
    }

    func testDirectoryFailureUsesStructuredCocoaFallbacksOnly() {
        let cases: [(Int, Int32)] = [
            (NSFileWriteOutOfSpaceError, ENOSPC),
            (NSFileWriteNoPermissionError, EACCES),
            (NSFileWriteVolumeReadOnlyError, EROFS),
            (NSFileWriteFileExistsError, EEXIST),
            (NSFileNoSuchFileError, ENOENT)
        ]
        for (cocoaCode, posixCode) in cases {
            let failure = LocalScreenshotOrganizationFileSystem.directoryCreationFailure(
                NSError(domain: NSCocoaErrorDomain, code: cocoaCode)
            )
            XCTAssertEqual(failure.posixCode, posixCode)
            XCTAssertEqual(failure.code, posixCode == EACCES ? .permissionDenied : .destinationUnavailable)
        }
        let unknown = NSError(domain: "UnrecognizedError", code: 99,
                              userInfo: [NSLocalizedDescriptionKey: "No space left on device"])
        XCTAssertNil(LocalScreenshotOrganizationFileSystem.directoryCreationFailure(unknown).posixCode)
    }

    func testPostPublicationRecoveryPreservesStructuredErrorCode() throws {
        try withFixture { fixture in
            let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, fault: { phase in
                if phase == .afterPublish {
                    throw ScreenshotCopyFailure(code: .ioFailure, detail: "Injected flush failure", posixCode: ENOSPC)
                }
            })
            let stage = try fileSystem.stageCopy(
                source: fixture.source, destinationRoot: fixture.destination,
                subdirectories: [], expectedIdentity: nil
            )
            let error = try XCTUnwrap(failure { try stage.publish(named: "published.png") })
            XCTAssertEqual(error.code, .ioFailure)
            XCTAssertEqual(error.posixCode, ENOSPC)
            let recovery = try XCTUnwrap(error.recoverableDestination)
            XCTAssertEqual(try Data(contentsOf: recovery), fixture.bytes)
            stage.discard()
            XCTAssertEqual(try Data(contentsOf: recovery), fixture.bytes)
            try fixture.assertOriginal()
        }
    }

    func testLargeCopyPreservesBytesExtendedAttributesAndOriginal() throws {
        try withFixture { fixture in
            let marker = Data("screenshot metadata fixture".utf8)
            try Self.setAttribute(marker, at: fixture.source)
            let identity = try XCTUnwrap(LocalScreenshotFileSystem().identity(at: fixture.source))
            let stage = try LocalScreenshotOrganizationFileSystem(pool: fixture.pool).stageCopy(
                source: fixture.source, destinationRoot: fixture.destination,
                subdirectories: ["2026", "09"], expectedIdentity: identity
            )
            let result = try stage.publish(named: "saved.png")
            XCTAssertNotEqual(result.identity, stage.identity)
            XCTAssertEqual(result.outputToken, stage.outputToken)
            XCTAssertNotEqual(result.identity, identity)
            XCTAssertEqual(result.destinationURL, fixture.destination.appendingPathComponent("2026/09/saved.png"))
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.bytes)
            XCTAssertEqual(try Self.attribute(at: result.destinationURL), marker)
            XCTAssertEqual(try Self.attribute(at: fixture.source), marker)
            try fixture.assertOriginal()
            stage.discard()
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.bytes)
            XCTAssertEqual(try entries(result.destinationURL.deletingLastPathComponent()), ["saved.png"])
        }
    }

    func testRepeatedCollisionsDoNotOverwriteAndStageCanPublishAnotherName() throws {
        try withFixture { fixture in
            let existing = fixture.destination.appendingPathComponent("existing.png")
            let sentinel = Data("existing user screenshot".utf8)
            try sentinel.write(to: existing)
            let stage = try fixture.stage()
            for _ in 0..<3 {
                let error = failure { try stage.publish(named: "existing.png") }
                XCTAssertEqual(error?.code, .collision)
                XCTAssertEqual(try Data(contentsOf: existing), sentinel)
                try fixture.assertOriginal()
            }
            let published = try stage.publish(named: "available.png")
            XCTAssertNotEqual(published.identity, stage.identity)
            XCTAssertEqual(try Data(contentsOf: published.destinationURL), fixture.bytes)
            XCTAssertEqual(try Data(contentsOf: existing), sentinel)
            stage.discard()
            XCTAssertEqual(try entries(fixture.destination), ["available.png", "existing.png"])
        }
    }

    func testExistingDestinationSymlinkIsCollisionAndItsTargetIsUntouched() throws {
        try withFixture { fixture in
            let target = fixture.root.appendingPathComponent("unrelated.txt")
            let sentinel = Data("private existing target".utf8)
            try sentinel.write(to: target)
            let link = fixture.destination.appendingPathComponent("linked.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let stage = try fixture.stage()
            XCTAssertEqual(failure { try stage.publish(named: "linked.png") }?.code, .collision)
            XCTAssertEqual(try Data(contentsOf: target), sentinel)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
            try fixture.assertOriginal()
            stage.discard()
            XCTAssertEqual(try entries(fixture.destination), ["linked.png"])
        }
    }

    func testMissingSourceCannotCreatePublishedFile() throws {
        try withFixture { fixture in
            XCTAssertThrowsError(try LocalScreenshotOrganizationFileSystem(pool: fixture.pool).stageCopy(
                source: fixture.root.appendingPathComponent("missing.png"),
                destinationRoot: fixture.destination, subdirectories: [], expectedIdentity: nil
            ))
            try fixture.assertOriginal()
            XCTAssertEqual(try entries(fixture.destination), [])
        }
    }

    func testDestinationBlockedByRegularFilePreservesBothFiles() throws {
        try withFixture { fixture in
            let blocked = fixture.root.appendingPathComponent("blocked")
            let sentinel = Data("never replace destination".utf8)
            try sentinel.write(to: blocked)
            XCTAssertThrowsError(try LocalScreenshotOrganizationFileSystem(pool: fixture.pool).stageCopy(
                source: fixture.source, destinationRoot: blocked,
                subdirectories: [], expectedIdentity: nil
            ))
            XCTAssertEqual(try Data(contentsOf: blocked), sentinel)
            try fixture.assertOriginal()
            XCTAssertEqual(try entries(fixture.destination), [])
        }
    }

    func testDateFolderBlockedByRegularFilePreservesBothFiles() throws {
        try withFixture { fixture in
            let blocked = fixture.destination.appendingPathComponent("2026")
            let sentinel = Data("user file".utf8)
            try sentinel.write(to: blocked)
            XCTAssertThrowsError(try LocalScreenshotOrganizationFileSystem(pool: fixture.pool).stageCopy(
                source: fixture.source, destinationRoot: fixture.destination,
                subdirectories: ["2026", "09"], expectedIdentity: nil
            ))
            XCTAssertEqual(try Data(contentsOf: blocked), sentinel)
            try fixture.assertOriginal()
            XCTAssertEqual(try entries(fixture.destination), ["2026"])
        }
    }

    func testSourceSymlinkIsRejectedWithoutChangingTarget() throws {
        try withFixture { fixture in
            let link = fixture.root.appendingPathComponent("source-link.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
            XCTAssertThrowsError(try LocalScreenshotOrganizationFileSystem(pool: fixture.pool).stageCopy(
                source: link, destinationRoot: fixture.destination,
                subdirectories: [], expectedIdentity: nil
            ))
            try fixture.assertOriginal()
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), fixture.source.path)
            XCTAssertEqual(try entries(fixture.destination), [])
        }
    }

    func testDateFolderSymlinkIsRejectedWithoutWritingOutsideDestination() throws {
        try withFixture { fixture in
            let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let sentinel = outside.appendingPathComponent("sentinel")
            try Data("outside file".utf8).write(to: sentinel)
            let link = fixture.destination.appendingPathComponent("2026")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertThrowsError(try LocalScreenshotOrganizationFileSystem(pool: fixture.pool).stageCopy(
                source: fixture.source, destinationRoot: fixture.destination,
                subdirectories: ["2026"], expectedIdentity: nil
            ))
            XCTAssertEqual(try entries(outside), ["sentinel"])
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside file".utf8))
            XCTAssertEqual(try entries(fixture.destination), ["2026"])
            try fixture.assertOriginal()
        }
    }

    func testExpectedIdentityMismatchPreservesSourceAndLeavesNoStage() throws {
        try withFixture { fixture in
            let actual = try XCTUnwrap(LocalScreenshotFileSystem().identity(at: fixture.source))
            let wrong = ScreenshotFileIdentity(device: actual.device, inode: actual.inode &+ 1,
                                               birthNanoseconds: actual.birthNanoseconds)
            XCTAssertEqual(failure {
                try LocalScreenshotOrganizationFileSystem(pool: fixture.pool).stageCopy(
                    source: fixture.source, destinationRoot: fixture.destination,
                    subdirectories: [], expectedIdentity: wrong
                )
            }?.code, .sourceChanged)
            try fixture.assertOriginal()
            XCTAssertEqual(try entries(fixture.destination), [])
        }
    }

    func testEveryFaultPhasePreservesOriginalAndRecoversPublishedCopy() throws {
        for phase in ScreenshotCopyPhase.allCases {
            try withFixture { fixture in
                let unrelated = fixture.destination.appendingPathComponent(".unrelated-hidden-file")
                let sentinel = Data("must survive cleanup".utf8)
                try sentinel.write(to: unrelated)
                let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, fault: { current in
                    if current == phase { throw InjectedFailure.interrupted }
                })
                var stage: (any ScreenshotStagedCopy)?
                var thrown: Error?
                do {
                    stage = try fileSystem.stageCopy(source: fixture.source,
                                                     destinationRoot: fixture.destination,
                                                     subdirectories: [], expectedIdentity: nil)
                    _ = try stage?.publish(named: "published.png")
                    XCTFail("Fault hook did not throw at \(phase)")
                } catch { thrown = error }
                stage?.discard()
                stage?.discard()
                try fixture.assertOriginal()
                XCTAssertEqual(try Data(contentsOf: unrelated), sentinel)
                let published = fixture.destination.appendingPathComponent("published.png")
                if phase == .afterPublish {
                    let error = try XCTUnwrap(thrown as? ScreenshotCopyFailure)
                    XCTAssertEqual(error.recoverableDestination, published)
                    XCTAssertEqual(try Data(contentsOf: published), fixture.bytes)
                    XCTAssertEqual(try entries(fixture.destination), [".unrelated-hidden-file", "published.png"])
                } else {
                    XCTAssertNotNil(thrown)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))
                    XCTAssertEqual(try entries(fixture.destination), [".unrelated-hidden-file"])
                }
            }
        }
    }

    func testSourceMutationDuringCopyIsRejectedAndNewSourceBytesAreRetained() throws {
        try withFixture { fixture in
            let source = fixture.source
            let changed = Data("source changed while copying".utf8)
            let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, fault: { phase in
                if phase == .afterCopy { try changed.write(to: source) }
            })
            XCTAssertEqual(failure {
                try fileSystem.stageCopy(source: source, destinationRoot: fixture.destination,
                                         subdirectories: [], expectedIdentity: nil)
            }?.code, .sourceChanged)
            XCTAssertEqual(try Data(contentsOf: source), changed)
            XCTAssertEqual(try entries(fixture.destination), [])
        }
    }

    func testDiscardRetiresOwnedStageWithoutUnlinkingOrChangingUnrelatedPaths() throws {
        try withFixture { fixture in
            let unrelated = fixture.destination.appendingPathComponent(".shotdrop-unrelated.stage")
            let sentinel = Data("unrelated hidden contents".utf8)
            try sentinel.write(to: unrelated)
            let stage = try fixture.stage()
            let stageURL = try Self.stageURL(in: fixture.poolRoot)
            XCTAssertEqual(try Data(contentsOf: stageURL), fixture.bytes)
            stage.discard()
            stage.discard()
            XCTAssertTrue(FileManager.default.fileExists(atPath: stageURL.path))
            XCTAssertEqual(try Data(contentsOf: stageURL), fixture.bytes)
            XCTAssertEqual(try entries(fixture.destination), [".shotdrop-unrelated.stage"])
            XCTAssertEqual(try Data(contentsOf: unrelated), sentinel)
            try fixture.assertOriginal()
        }
    }

    func testInvalidPublicationNamesCannotEscapeDestinationAndStageRemainsUsable() throws {
        try withFixture { fixture in
            let sentinel = fixture.root.appendingPathComponent("outside.png")
            let sentinelBytes = Data("outside name must not be replaced".utf8)
            try sentinelBytes.write(to: sentinel)
            let stage = try fixture.stage()
            for name in ["", ".", "..", "../outside.png", "nested/file.png", "/absolute.png", "nul\0.png"] {
                XCTAssertEqual(failure { try stage.publish(named: name) }?.code, .invalidName, name)
                try fixture.assertOriginal()
                XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
            }
            let result = try stage.publish(named: "safe.png")
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.bytes)
            stage.discard()
            XCTAssertEqual(try entries(fixture.destination), ["safe.png"])
        }
    }

    func testChangedStageBytesCannotBePublished() throws {
        try withFixture { fixture in
            let destination = fixture.destination
            let poolRoot = fixture.poolRoot
            let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, fault: { phase in
                if phase == .beforeVerification {
                    try Data("tampered copy".utf8).write(to: Self.stageURL(in: poolRoot))
                }
            })
            XCTAssertEqual(failure {
                try fileSystem.stageCopy(source: fixture.source, destinationRoot: destination,
                                         subdirectories: [], expectedIdentity: nil)
            }?.code, .verificationFailed)
            try fixture.assertOriginal()
            XCTAssertEqual(try entries(destination), [])
        }
    }

    func testChangedStageMetadataCannotBePublished() throws {
        try withFixture { fixture in
            let destination = fixture.destination
            let poolRoot = fixture.poolRoot
            let marker = Data("original attribute".utf8)
            try Self.setAttribute(marker, at: fixture.source)
            let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, fault: { phase in
                if phase == .beforeVerification {
                    try Self.setAttribute(Data("changed attribute".utf8), at: Self.stageURL(in: poolRoot))
                }
            })
            XCTAssertEqual(failure {
                try fileSystem.stageCopy(source: fixture.source, destinationRoot: destination,
                                         subdirectories: [], expectedIdentity: nil)
            }?.code, .verificationFailed)
            try fixture.assertOriginal()
            XCTAssertEqual(try Self.attribute(at: fixture.source), marker)
            XCTAssertEqual(try entries(destination), [])
        }
    }

    func testReplacedStagePathIsNotDeletedOrPublished() throws {
        try withFixture { fixture in
            let stage = try fixture.stage()
            let hiddenURL = try Self.stageURL(in: fixture.poolRoot)
            let moved = fixture.root.appendingPathComponent("moved-private-stage")
            try FileManager.default.moveItem(at: hiddenURL, to: moved)
            let replacement = Data("replacement belongs to somebody else".utf8)
            try replacement.write(to: hiddenURL)
            XCTAssertEqual(failure { try stage.publish(named: "output.png") }?.code, .verificationFailed)
            XCTAssertEqual(try Data(contentsOf: moved), fixture.bytes)
            stage.discard()
            XCTAssertEqual(try Data(contentsOf: hiddenURL), replacement)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
            XCTAssertEqual(try entries(fixture.destination), [])
            try fixture.assertOriginal()
        }
    }

    func testStagePathSwapAfterVerificationPublishesOnlyVerifiedDescriptorBytes() throws {
        try withFixture { fixture in
            let parked = fixture.root.appendingPathComponent("parked-stage")
            let replacement = Data("unrelated replacement must not become the screenshot".utf8)
            let unrelated = fixture.destination.appendingPathComponent("unrelated.png")
            let unrelatedBytes = Data("preexisting user screenshot".utf8)
            try unrelatedBytes.write(to: unrelated)
            let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, race: { point, stageURL in
                guard point == .afterStageVerificationBeforePublish else { return }
                try FileManager.default.moveItem(at: stageURL, to: parked)
                try replacement.write(to: stageURL)
            })
            var stage: (any ScreenshotStagedCopy)? = try fileSystem.stageCopy(
                source: fixture.source, destinationRoot: fixture.destination,
                subdirectories: [], expectedIdentity: nil
            )
            let stageURL = try Self.stageURL(in: fixture.poolRoot)
            let result = try XCTUnwrap(stage).publish(named: "published.png")
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.bytes)
            XCTAssertNotEqual(try Data(contentsOf: result.destinationURL), replacement)
            XCTAssertEqual(try Data(contentsOf: stageURL), replacement)
            XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path), "Race hook must execute")
            XCTAssertEqual(result.identity, try LocalScreenshotFileSystem().identity(at: result.destinationURL))
            XCTAssertEqual(result.outputToken, stage?.outputToken)
            XCTAssertNotEqual(result.identity, stage?.identity)
            stage?.discard()
            stage?.discard()
            stage = nil
            XCTAssertEqual(try Data(contentsOf: stageURL), replacement)
            XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.bytes)
            XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedBytes)
            XCTAssertEqual(try entries(fixture.destination), ["published.png", "unrelated.png"])
            try fixture.assertOriginal()
        }
    }

    func testOutputHardLinkToStageAfterCloningIsRejectedAndNeverTruncated() throws {
        try withFixture { fixture in
            let output = fixture.destination.appendingPathComponent("published.png")
            let parkedClone = fixture.root.appendingPathComponent("parked-clone.png")
            let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, race: { point, stageURL in
                guard point == .afterCloneBeforeOutputOpen else { return }
                try FileManager.default.moveItem(at: output, to: parkedClone)
                try FileManager.default.linkItem(at: stageURL, to: output)
            })
            var stage: (any ScreenshotStagedCopy)? = try fileSystem.stageCopy(
                source: fixture.source, destinationRoot: fixture.destination,
                subdirectories: [], expectedIdentity: nil
            )
            let stageURL = try Self.stageURL(in: fixture.poolRoot)
            let error = try XCTUnwrap(failure { try XCTUnwrap(stage).publish(named: "published.png") })
            XCTAssertEqual(error.code, .verificationFailed)
            XCTAssertNil(error.recoverableDestination, "The substituted hard link must not become a verified receipt")
            XCTAssertEqual(try LocalScreenshotFileSystem().identity(at: output), stage?.identity)
            XCTAssertEqual(try Data(contentsOf: output), fixture.bytes)
            XCTAssertEqual(try Data(contentsOf: parkedClone), fixture.bytes)
            stage?.discard()
            stage?.discard()
            stage = nil
            XCTAssertEqual(try Data(contentsOf: output), fixture.bytes)
            XCTAssertEqual(try Data(contentsOf: stageURL), fixture.bytes)
            XCTAssertEqual(try Data(contentsOf: parkedClone), fixture.bytes)
            try fixture.assertOriginal()
        }
    }

    func testStagePathSwapAfterCleanupIdentityCheckNeverUnlinksReplacement() throws {
        try withFixture { fixture in
            let parked = fixture.root.appendingPathComponent("parked-stage")
            let replacement = Data("unrelated file arriving at the last cleanup boundary".utf8)
            let unrelated = fixture.destination.appendingPathComponent("unrelated.png")
            let unrelatedBytes = Data("preexisting user screenshot".utf8)
            try unrelatedBytes.write(to: unrelated)
            let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, race: { point, stageURL in
                guard point == .afterStageIdentityCheckBeforeCleanup else { return }
                try FileManager.default.moveItem(at: stageURL, to: parked)
                try replacement.write(to: stageURL)
            })
            var stage: (any ScreenshotStagedCopy)? = try fileSystem.stageCopy(
                source: fixture.source, destinationRoot: fixture.destination,
                subdirectories: [], expectedIdentity: nil
            )
            let stageURL = try Self.stageURL(in: fixture.poolRoot)
            XCTAssertEqual(try Data(contentsOf: stageURL), fixture.bytes)
            let output = try XCTUnwrap(stage).publish(named: "published.png")
            stage?.discard()
            stage?.discard()
            stage = nil
            XCTAssertEqual(try Data(contentsOf: stageURL), replacement)
            XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path), "Race hook must execute")
            XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedBytes)
            XCTAssertEqual(try entries(fixture.destination), ["published.png", "unrelated.png"])
            XCTAssertEqual(try Data(contentsOf: output.destinationURL), fixture.bytes)
            guard case .retired = output.housekeeping else {
                return XCTFail("Replaced stage must retire while the verified output remains saved")
            }
            try fixture.assertOriginal()
        }
    }

    private enum InjectedFailure: Error { case interrupted }

    private func failure<T>(_ body: () throws -> T) -> ScreenshotCopyFailure? {
        do {
            _ = try body()
            XCTFail("Expected transaction to fail")
            return nil
        } catch {
            guard let failure = error as? ScreenshotCopyFailure else {
                XCTFail("Expected ScreenshotCopyFailure, got \(error)")
                return nil
            }
            return failure
        }
    }

    private func entries(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private static func stageURL(in directory: URL) throws -> URL {
        let slots = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "stage" }
        return try XCTUnwrap(slots.first { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 })
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = try resolvedStagingTemporaryDirectory()
            .appendingPathComponent("ShotDropOrganizationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("original.png")
        let poolRoot = root.appendingPathComponent("pool", isDirectory: true)
        let pool = ScreenshotStagingPool(registryDirectory: root.appendingPathComponent("registry", isDirectory: true))
        try pool.initialize(legacyArtifactsAccountedFor: true)
        try pool.registerRoot(at: poolRoot, sourceDirectory: sourceDirectory, destinationDirectory: destination,
                              ordinaryLocalDestinationReviewed: true)
        // Nonuniform bytes cross the stream's chunk boundary and exercise a partial final chunk.
        let bytes = Data((0..<(1_048_576 + 137)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: source)
        try body(Fixture(root: root, source: source, destination: destination, bytes: bytes, pool: pool, poolRoot: poolRoot))
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let bytes: Data
        let pool: ScreenshotStagingPool
        let poolRoot: URL

        func stage() throws -> any ScreenshotStagedCopy {
            try LocalScreenshotOrganizationFileSystem(pool: pool).stageCopy(
                source: source, destinationRoot: destination, subdirectories: [], expectedIdentity: nil
            )
        }

        func assertOriginal(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try Data(contentsOf: source), bytes, file: file, line: line)
        }
    }

    private static let attributeName = "com.macfleet.shotdrop.fixture"

    private static func setAttribute(_ data: Data, at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path in
            data.withUnsafeBytes { bytes in
                setxattr(path!, attributeName, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func attribute(at url: URL) throws -> Data {
        let count = url.withUnsafeFileSystemRepresentation { getxattr($0!, attributeName, nil, 0, 0, 0) }
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var data = Data(count: count)
        let readCount = url.withUnsafeFileSystemRepresentation { path in
            data.withUnsafeMutableBytes { getxattr(path!, attributeName, $0.baseAddress, $0.count, 0, 0) }
        }
        guard readCount == count else { throw POSIXError(.EIO) }
        return data
    }
}
