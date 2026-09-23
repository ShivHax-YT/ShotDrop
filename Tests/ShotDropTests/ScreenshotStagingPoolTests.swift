import Darwin
import Foundation
import os
import XCTest
@testable import ShotDrop

final class ScreenshotStagingPoolTests: XCTestCase {
    func testInitializationIsExplicitFixedAndNeverResetsExistingRegistry() throws {
        try withFixture(register: false) { fixture in
            XCTAssertEqual(try fixture.children(fixture.registry), ["lock", "registry.json"])
            XCTAssertThrowsError(try fixture.pool.initialize(legacyArtifactsAccountedFor: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
            try fixture.register()
            XCTAssertEqual(try fixture.children(fixture.root), ["slot-0.stage", "slot-1.stage"])
            XCTAssertEqual(try fixture.mode(fixture.registry), 0o700)
            XCTAssertEqual(try fixture.mode(fixture.root), 0o700)
            for slot in 0..<2 { XCTAssertEqual(try fixture.mode(fixture.slot(slot)), 0o600) }
        }
    }

    func testLegacyUnaccountedRegistryRefusesLeaseWithoutMutation() throws {
        try withFixture(legacyAccounted: false) { fixture in
            let before = try Data(contentsOf: fixture.journal)
            try expectPaused { _ = try fixture.lease() }
            XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
            XCTAssertEqual(try fixture.states(), ["clean", "clean"])
        }
    }

    func testAbsentSelectedDestinationPausesWithoutCreatingOrChargingSlot() throws {
        try withFixture { fixture in
            let absent = fixture.destination.appendingPathComponent("missing/deep", isDirectory: true)
            let before = try Data(contentsOf: fixture.journal)
            try expectPaused { _ = try fixture.pool.lease(sourceDirectory: fixture.source, destinationDirectory: absent) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
            XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
            XCTAssertEqual(try fixture.states(), ["clean", "clean"])
        }
    }

    func testRepeatedCleanUseKeepsTwoStableSlotIdentities() throws {
        try withFixture { fixture in
            let original = try fixture.inodes()
            for index in 0..<50 {
                let lease = try fixture.lease()
                try lease.transition(.writing)
                try write(Data("capture-\(index)".utf8), to: lease.descriptor)
                try lease.transition(.prepared)
                try lease.transition(.publishing)
                try lease.transition(.publishing)
                assertClean(lease.reset())
                XCTAssertEqual(lease.descriptor, -1)
            }
            XCTAssertEqual(try fixture.inodes(), original)
            XCTAssertEqual(try fixture.children(fixture.root), ["slot-0.stage", "slot-1.stage"])
            XCTAssertEqual(try fixture.states(), ["clean", "clean"])
        }
    }

    func testGlobalLockHeldUntilResetEvenAcrossSeparatePoolInstances() throws {
        try withFixture { fixture in
            let lease = try fixture.lease()
            let competitor = ScreenshotStagingPool(registryDirectory: fixture.registry)
            try expectPaused { _ = try competitor.lease(sourceDirectory: fixture.source, destinationDirectory: fixture.destination) }
            try publishing(lease)
            assertClean(lease.reset())
            let next = try competitor.lease(sourceDirectory: fixture.source, destinationDirectory: fixture.destination)
            try publishing(next)
            assertClean(next.reset())
        }
    }

    func testRetirementAndDeinitConsumeBothSlotsWithoutExpansion() throws {
        try withFixture { fixture in
            let first = try fixture.lease()
            first.retire("fixture failure")
            XCTAssertEqual(first.descriptor, -1)
            var second: ScreenshotStagingLease? = try fixture.lease()
            XCTAssertEqual(second?.url.lastPathComponent, "slot-1.stage")
            second = nil
            XCTAssertEqual(try fixture.states(), ["retired", "retired"])
            try expectPaused { _ = try fixture.lease() }
            XCTAssertEqual(try fixture.children(fixture.root), ["slot-0.stage", "slot-1.stage"])
        }
    }

    func testCrashStatesAreDurablyRetiredAndOnlyExistingCleanSlotIsUsed() throws {
        for state in ["reserved", "writing", "prepared", "publishing", "reclaiming"] {
            try withFixture { fixture in
                try fixture.editJournal { journal in
                    var roots = journal["roots"] as! [[String: Any]]
                    var slots = roots[0]["slots"] as! [[String: Any]]
                    slots[0]["state"] = state
                    roots[0]["slots"] = slots
                    journal["roots"] = roots
                }
                let lease = try fixture.lease()
                XCTAssertEqual(lease.url.lastPathComponent, "slot-1.stage")
                XCTAssertEqual(try fixture.states(), ["retired", "reserved"])
                try publishing(lease)
                assertClean(lease.reset())
            }
        }
    }

    func testCorruptMissingAndOversizeRegistryNeverReinitializeOrAdmit() throws {
        for corruption in 0..<3 {
            try withFixture { fixture in
                switch corruption {
                case 0: try Data("invalid-json".utf8).write(to: fixture.journal)
                case 1: try FileManager.default.removeItem(at: fixture.journal)
                default: try Data(repeating: 65, count: ScreenshotStagingLimits.maximumRegistryBytes + 1).write(to: fixture.journal)
                }
                try expectPaused { _ = try fixture.lease() }
                XCTAssertThrowsError(try fixture.pool.initialize(legacyArtifactsAccountedFor: true))
                XCTAssertEqual(try fixture.children(fixture.root), ["slot-0.stage", "slot-1.stage"])
            }
        }
    }

    func testFailedRegistrationIsChargedAndCannotBeReplacedOnSameVolume() throws {
        try withFixture(register: false) { fixture in
            let faulting = ScreenshotStagingPool(registryDirectory: fixture.registry, fault: { point in
                if case .beforeRootCreation = point { throw PoolTestFailure.injected }
            })
            XCTAssertThrowsError(try faulting.registerRoot(at: fixture.root, sourceDirectory: fixture.source,
                                                          destinationDirectory: fixture.destination, ordinaryLocalDestinationReviewed: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
            let replacement = fixture.base.appendingPathComponent("replacement-pool", isDirectory: true)
            try expectPaused { try fixture.pool.registerRoot(at: replacement, sourceDirectory: fixture.source,
                                                            destinationDirectory: fixture.destination, ordinaryLocalDestinationReviewed: true) }
            XCTAssertEqual(try fixture.rootRecords().count, 1)
            XCTAssertEqual(try fixture.states(), ["retired", "retired"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.path))
        }
    }

    func testFourChargedRootRecordsBlockFifthWithoutDirectoryCreation() throws {
        try withFixture { fixture in
            // Synthetic offline-volume records test the global count without mounting volumes.
            try fixture.editJournal { journal in
                var roots = journal["roots"] as! [[String: Any]]
                for index in 1..<4 {
                    var root = roots[0]
                    root["path"] = fixture.base.appendingPathComponent("offline-\(index)").path
                    let uuid = UUID().uuidString
                    root["volumeUUID"] = uuid
                    var review = root["destinationReview"] as! [String: Any]
                    review["volumeUUID"] = uuid
                    root["destinationReview"] = review
                    root.removeValue(forKey: "identity")
                    root["ready"] = false
                    root["slots"] = (0..<2).map { ["name": "slot-\($0).stage", "state": "retired"] }
                    roots.append(root)
                }
                journal["roots"] = roots
            }
            let fifth = fixture.base.appendingPathComponent("fifth", isDirectory: true)
            try expectPaused { try fixture.pool.registerRoot(at: fifth, sourceDirectory: fixture.source,
                                                            destinationDirectory: fixture.destination, ordinaryLocalDestinationReviewed: true) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fifth.path))
            XCTAssertEqual(try fixture.rootRecords().count, 4)
        }
    }

    func testFirstAndSecondSlotCreationFailureKeepWholeRootChargedWithoutAdoption() throws {
        for failingIndex in 1...2 {
            try withFixture(register: false) { fixture in
                let sourceFile = fixture.source.appendingPathComponent("retained.png")
                let sourceBytes = Data("original screenshot remains unchanged".utf8)
                try sourceBytes.write(to: sourceFile)
                let calls = OSAllocatedUnfairLock(initialState: 0)
                let faulting = ScreenshotStagingPool(registryDirectory: fixture.registry, fault: { point in
                    if case .beforeSlotCreation = point {
                        let index = calls.withLock { count in count += 1; return count }
                        if index == failingIndex { throw PoolTestFailure.injected }
                    }
                })
                XCTAssertThrowsError(try faulting.registerRoot(at: fixture.root, sourceDirectory: fixture.source,
                                                              destinationDirectory: fixture.destination, ordinaryLocalDestinationReviewed: true))
                XCTAssertEqual(calls.withLock { $0 }, failingIndex)
                XCTAssertEqual(try fixture.children(fixture.root), failingIndex == 1 ? [] : ["slot-0.stage"])
                XCTAssertEqual(try fixture.states(), ["retired", "retired"])
                XCTAssertEqual(try fixture.rootRecords().count, 1)
                try expectPaused { try fixture.register() }
                let replacement = fixture.base.appendingPathComponent("escape-pool", isDirectory: true)
                try expectPaused { try fixture.pool.registerRoot(at: replacement, sourceDirectory: fixture.source,
                                                                destinationDirectory: fixture.destination, ordinaryLocalDestinationReviewed: true) }
                try expectPaused { _ = try fixture.lease() }
                XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.path))
                XCTAssertEqual(try Data(contentsOf: sourceFile), sourceBytes)
            }
        }
    }

    func testUnknownChildrenInRegistryOrPoolPauseWithoutRemovingAnything() throws {
        for registryChild in [true, false] {
            try withFixture { fixture in
                let unknown = (registryChild ? fixture.registry : fixture.root).appendingPathComponent("unrecognized")
                let bytes = Data("preserve unknown file".utf8)
                try bytes.write(to: unknown)
                try expectPaused { _ = try fixture.lease() }
                XCTAssertEqual(try Data(contentsOf: unknown), bytes)
            }
        }
    }

    func testMovedOrReplacedRootFailsClosedWithoutAdoption() throws {
        for replace in [false, true] {
            try withFixture { fixture in
                let moved = fixture.base.appendingPathComponent("moved-root", isDirectory: true)
                try FileManager.default.moveItem(at: fixture.root, to: moved)
                if replace { try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false) }
                try expectPaused { _ = try fixture.lease() }
                XCTAssertEqual(try fixture.children(moved), ["slot-0.stage", "slot-1.stage"])
            }
        }
    }

    func testHealthyVolumeContinuesWhileAnotherRegisteredVolumeIsOfflineAndUnchanged() throws {
        try withFixture { fixture in
            // Synthetic second-volume identity exercises selection without mounting hardware.
            // Physical disconnect/reconnect acceptance remains a separate device test.
            try fixture.editJournal { journal in
                var roots = journal["roots"] as! [[String: Any]]
                var offline = roots[0]
                let volumeUUID = UUID().uuidString
                offline["path"] = fixture.base.appendingPathComponent("offline-volume/pool").path
                offline["volumeUUID"] = volumeUUID
                var review = offline["destinationReview"] as! [String: Any]
                review["volumeUUID"] = volumeUUID
                offline["destinationReview"] = review
                var identity = offline["identity"] as! [String: Any]
                identity["volumeUUID"] = volumeUUID
                offline["identity"] = identity
                var slots = offline["slots"] as! [[String: Any]]
                for index in slots.indices {
                    var slotIdentity = slots[index]["identity"] as! [String: Any]
                    slotIdentity["volumeUUID"] = volumeUUID
                    slots[index]["identity"] = slotIdentity
                    // Nonclean offline slots stay charged; another volume must not reclaim them.
                    slots[index]["state"] = index == 0 ? "writing" : "retired"
                }
                offline["slots"] = slots
                roots.append(offline)
                journal["roots"] = roots
            }
            let offlineBefore = try JSONSerialization.data(withJSONObject: fixture.rootRecords()[1], options: [.sortedKeys])
            let lease = try fixture.lease()
            XCTAssertEqual(lease.url.deletingLastPathComponent().path, fixture.root.path)
            try publishing(lease)
            assertClean(lease.reset())
            XCTAssertEqual(try fixture.rootRecords().count, 2)
            let offlineAfter = try JSONSerialization.data(withJSONObject: fixture.rootRecords()[1], options: [.sortedKeys])
            XCTAssertEqual(offlineAfter, offlineBefore)
            XCTAssertEqual(try fixture.children(fixture.root), ["slot-0.stage", "slot-1.stage"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("offline-volume").path))
        }
    }

    func testSymlinkRootAndExternalSlotHardlinkAreRejected() throws {
        try withFixture { fixture in
            let moved = fixture.base.appendingPathComponent("real-root", isDirectory: true)
            try FileManager.default.moveItem(at: fixture.root, to: moved)
            try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: moved)
            try expectPaused { _ = try fixture.lease() }
        }
        try withFixture { fixture in
            let external = fixture.destination.appendingPathComponent("external-alias")
            XCTAssertEqual(link(fixture.slot(0).path, external.path), 0)
            try expectPaused { _ = try fixture.lease() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        }
    }

    func testKnownOutputAliasIsNeverTruncated() throws {
        try withFixture { fixture in
            let lease = try fixture.lease()
            try lease.transition(.writing)
            let bytes = Data("preserve aliased output".utf8)
            try write(bytes, to: lease.descriptor)
            try lease.transition(.prepared)
            try lease.transition(.publishing)
            assertRetired(lease.reset(knownOutputFD: lease.descriptor))
            XCTAssertEqual(try Data(contentsOf: fixture.slot(0)), bytes)
            XCTAssertEqual(try fixture.states(), ["retired", "clean"])
        }
    }

    func testResetRemovesMetadataResourceForkAndPayloadButPreservesIndependentClone() throws {
        try withFixture { fixture in
            let lease = try fixture.lease()
            try lease.transition(.writing)
            let bytes = Data("independent output".utf8)
            try write(bytes, to: lease.descriptor)
            try setAttribute("com.macfleet.shotdrop.test", value: Data("metadata".utf8), descriptor: lease.descriptor)
            try setAttribute("com.apple.ResourceFork", value: Data("fork data".utf8), descriptor: lease.descriptor)
            try lease.transition(.prepared)
            try lease.transition(.publishing)
            let destinationFD = open(fixture.destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(destinationFD, 0)
            defer { close(destinationFD) }
            let cloned = fclonefileat(lease.descriptor, destinationFD, "saved.png", 0)
            if cloned != 0 && errno == ENOTSUP { throw XCTSkip("Fixture volume does not support clonefile.") }
            XCTAssertEqual(cloned, 0)
            let output = fixture.destination.appendingPathComponent("saved.png")
            let outputFD = open(output.path, O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(outputFD, 0)
            defer { close(outputFD) }
            let copiedAttributes = try BoundedScreenshotCopy.attributes(lease.descriptor)
            try lease.baseline.verify(outputFD)
            XCTAssertEqual(try BoundedScreenshotCopy.attributes(outputFD), copiedAttributes)
            assertClean(lease.reset(knownOutputFD: outputFD))
            try lease.baseline.verify(outputFD)
            XCTAssertEqual(try BoundedScreenshotCopy.attributes(outputFD), copiedAttributes)
            XCTAssertEqual(try Data(contentsOf: output), bytes)
            let check = open(fixture.slot(0).path, O_RDONLY | O_CLOEXEC)
            defer { close(check) }
            try lease.baseline.verify(check)
            let baselineNameBytes = lease.baseline.provenance == nil ? 0 : ScreenshotStagingBaseline.attributeName.utf8.count + 1
            XCTAssertEqual(flistxattr(check, nil, 0, 0), baselineNameBytes)
            XCTAssertTrue(try Data(contentsOf: fixture.slot(0)).isEmpty)
        }
    }

    func testResetFailuresRetireWithoutAllocatingOrDestroyingOriginalOutput() throws {
        for point in [ScreenshotStagingPoolFault.beforeRemoveAttributes, .beforeTruncate, .beforeSlotSync, .afterSlotSync] {
            try withFixture { fixture in
                let failing = ScreenshotStagingPool(registryDirectory: fixture.registry, fault: { phase in
                    if phase == point { throw PoolTestFailure.injected }
                })
                let lease = try failing.lease(sourceDirectory: fixture.source, destinationDirectory: fixture.destination)
                try lease.transition(.writing)
                try write(Data("stage bytes".utf8), to: lease.descriptor)
                let unrelatedOutput = fixture.destination.appendingPathComponent("verified.png")
                let outputBytes = Data("verified independent output".utf8)
                try outputBytes.write(to: unrelatedOutput)
                try lease.transition(.prepared)
                try lease.transition(.publishing)
                assertRetired(lease.reset())
                XCTAssertEqual(try fixture.states(), ["retired", "clean"])
                XCTAssertEqual(try Data(contentsOf: unrelatedOutput), outputBytes)
                let remaining = try fixture.lease()
                XCTAssertEqual(remaining.url.lastPathComponent, "slot-1.stage")
                remaining.retire("bounded fixture")
            }
        }
    }

    func testRegistryWriteOrFlushFailurePoisonsRegistryBeforeSlotMutation() throws {
        for point in [ScreenshotStagingPoolFault.beforeRegistryWrite, .beforeRegistrySync, .afterRegistrySync] {
            try withFixture { fixture in
                let failing = ScreenshotStagingPool(registryDirectory: fixture.registry, fault: { phase in
                    if phase == point { throw PoolTestFailure.injected }
                })
                XCTAssertThrowsError(try failing.lease(sourceDirectory: fixture.source, destinationDirectory: fixture.destination))
                try expectPaused { _ = try fixture.lease() }
                XCTAssertEqual(try fixture.children(fixture.registry), ["lock", "registry.json"])
                XCTAssertTrue(try Data(contentsOf: fixture.slot(0)).isEmpty)
                XCTAssertTrue(try Data(contentsOf: fixture.slot(1)).isEmpty)
            }
        }
    }

    func testReplacementDuringLeaseRetiresWithoutTruncatingReplacement() throws {
        try withFixture { fixture in
            let lease = try fixture.lease()
            try lease.transition(.writing)
            try lease.transition(.prepared)
            try lease.transition(.publishing)
            let moved = fixture.base.appendingPathComponent("moved-slot")
            try FileManager.default.moveItem(at: lease.url, to: moved)
            let replacement = Data("unrelated replacement".utf8)
            try replacement.write(to: lease.url)
            assertRetired(lease.reset())
            XCTAssertEqual(try Data(contentsOf: fixture.slot(0)), replacement)
            XCTAssertEqual(try fixture.states(), ["retired", "clean"])
        }
    }

    func testRootInsideSourceOrDestinationIsNeverCreated() throws {
        try withFixture(register: false) { fixture in
            for parent in [fixture.source, fixture.destination] {
                let invalid = parent.appendingPathComponent("pool", isDirectory: true)
                try expectPaused { try fixture.pool.registerRoot(at: invalid, sourceDirectory: fixture.source,
                                                                destinationDirectory: fixture.destination, ordinaryLocalDestinationReviewed: true) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.path))
            }
            XCTAssertTrue(try fixture.rootRecords().isEmpty)
        }
    }

    func testRegistryInsideSourceOrDestinationRejectsRegistrationBeforeRootCreation() throws {
        for insideSource in [true, false] {
            try withFixture(register: false) { fixture in
                let parent = insideSource ? fixture.source : fixture.destination
                let nestedRegistry = parent.appendingPathComponent("nested-registry", isDirectory: true)
                let unsafe = ScreenshotStagingPool(registryDirectory: nestedRegistry)
                try unsafe.initialize(legacyArtifactsAccountedFor: true)
                try expectPaused { try unsafe.registerRoot(at: fixture.root, sourceDirectory: fixture.source,
                                                          destinationDirectory: fixture.destination, ordinaryLocalDestinationReviewed: true) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
                XCTAssertEqual(try fixture.children(nestedRegistry), ["lock", "registry.json"])
            }
        }
    }

    func testChangedSourceOrDestinationOverlappingRegistryBlocksLease() throws {
        try withFixture { fixture in
            let before = try Data(contentsOf: fixture.journal)
            try expectPaused { _ = try fixture.pool.lease(sourceDirectory: fixture.registry, destinationDirectory: fixture.destination) }
            try expectPaused { _ = try fixture.pool.lease(sourceDirectory: fixture.source, destinationDirectory: fixture.registry) }
            XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
        }
    }

    func testLiveDeviceNumberChangeKeepsUUIDIdentityAndDoesNotChargeAnotherRoot() throws {
        try withFixture { fixture in
            let before = try Data(contentsOf: fixture.journal)
            XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("\"device\""))
            let shifted = ScreenshotStagingPool(
                registryDirectory: fixture.registry,
                volumeInspector: PoolTestVolumeInspector(deviceOffset: 1_024),
                liveDeviceReader: { descriptor in
                    var info = stat()
                    guard fstat(descriptor, &info) == 0 else { throw PoolTestFailure.injected }
                    return UInt64(UInt32(bitPattern: info.st_dev)) + 1_024
                }
            )
            let lease = try shifted.lease(sourceDirectory: fixture.source, destinationDirectory: fixture.destination)
            try publishing(lease)
            assertClean(lease.reset())
            XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
            XCTAssertEqual(try fixture.rootRecords().count, 1)
            let replacement = fixture.base.appendingPathComponent("second-root-after-remount", isDirectory: true)
            try expectPaused { try shifted.registerRoot(at: replacement, sourceDirectory: fixture.source,
                                                       destinationDirectory: fixture.destination, ordinaryLocalDestinationReviewed: true) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.path))
            XCTAssertEqual(try fixture.rootRecords().count, 1)
            let normal = try fixture.lease()
            try publishing(normal)
            assertClean(normal.reset())
        }
    }

    func testUnsupportedOrUnknownDestinationCapabilityConsumesNoRootReservation() throws {
        for unsupported in PoolTestUnsupportedVolume.allCases {
            try withFixture(register: false) { fixture in
                var info = stat()
                XCTAssertEqual(stat(fixture.destination.path, &info), 0)
                let pool = ScreenshotStagingPool(registryDirectory: fixture.registry,
                    volumeInspector: PoolTestVolumeInspector(unsupportedInode: UInt64(info.st_ino), unsupported: unsupported))
                let before = try Data(contentsOf: fixture.journal)
                try expectPaused { try pool.registerRoot(at: fixture.root, sourceDirectory: fixture.source,
                                                        destinationDirectory: fixture.destination, ordinaryLocalDestinationReviewed: true) }
                XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
                XCTAssertTrue(try fixture.rootRecords().isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
            }
        }
    }

    func testOldSchemaMissingUUIDAndDuplicateUUIDNeverRelearnOrResetRegistry() throws {
        for invalid in 0..<3 {
            try withFixture { fixture in
                try fixture.editJournal { journal in
                    if invalid == 0 { journal["version"] = 1; return }
                    var roots = journal["roots"] as! [[String: Any]]
                    if invalid == 1 { roots[0].removeValue(forKey: "volumeUUID") }
                    else {
                        var duplicate = roots[0]
                        duplicate["path"] = fixture.base.appendingPathComponent("ambiguous-root").path
                        roots.append(duplicate)
                    }
                    journal["roots"] = roots
                }
                let before = try Data(contentsOf: fixture.journal)
                try expectPaused { _ = try fixture.lease() }
                XCTAssertThrowsError(try fixture.pool.initialize(legacyArtifactsAccountedFor: true))
                XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
            }
        }
    }

    func testDefaultUnreviewedDestinationRefusesBeforeRootReservation() throws {
        try withFixture(register: false) { fixture in
            let before = try Data(contentsOf: fixture.journal)
            try expectPaused { try fixture.pool.registerRoot(at: fixture.root, sourceDirectory: fixture.source,
                                                            destinationDirectory: fixture.destination) }
            XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
            XCTAssertTrue(try fixture.rootRecords().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        }
    }

    func testKnownProviderDestinationRefusesEvenWhenExplicitlyReviewed() throws {
        for relative in ["Library/CloudStorage/FixtureProvider/Images", "Library/Mobile Documents/com~apple~CloudDocs/Images"] {
            try withFixture(register: false) { fixture in
                let managed = fixture.base.appendingPathComponent(relative, isDirectory: true)
                try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
                let before = try Data(contentsOf: fixture.journal)
                try expectPaused { try fixture.pool.registerRoot(at: fixture.root, sourceDirectory: fixture.source,
                                                                destinationDirectory: managed, ordinaryLocalDestinationReviewed: true) }
                XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
            }
        }
    }

    func testDestinationPathChangeRequiresExplicitReplacementReviewWithoutAnotherRoot() throws {
        try withFixture { fixture in
            let changed = fixture.base.appendingPathComponent("new-reviewed-destination", isDirectory: true)
            try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: false)
            let before = try Data(contentsOf: fixture.journal)
            try expectPaused { _ = try fixture.pool.lease(sourceDirectory: fixture.source, destinationDirectory: changed) }
            try expectPaused { try fixture.pool.updateDestinationReview(at: changed, forRoot: fixture.root,
                                                                       sourceDirectory: fixture.source) }
            XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
            let stillAuthorized = try fixture.lease()
            try publishing(stillAuthorized)
            assertClean(stillAuthorized.reset())
            try fixture.pool.updateDestinationReview(at: changed, forRoot: fixture.root, sourceDirectory: fixture.source,
                                                     ordinaryLocalDestinationReviewed: true)
            XCTAssertEqual(try fixture.rootRecords().count, 1)
            try expectPaused { _ = try fixture.lease() }
            let lease = try fixture.pool.lease(sourceDirectory: fixture.source, destinationDirectory: changed)
            try publishing(lease)
            assertClean(lease.reset())
            XCTAssertEqual(try fixture.states(), ["clean", "clean"])
        }
    }

    func testMalformedOrMismatchedDestinationReviewPausesWithoutRelearning() throws {
        for invalid in 0..<3 {
            try withFixture { fixture in
                try fixture.editJournal { journal in
                    var roots = journal["roots"] as! [[String: Any]]
                    var review = roots[0]["destinationReview"] as! [String: Any]
                    if invalid == 0 { review["path"] = "relative/destination" }
                    else if invalid == 1 { review["path"] = fixture.destination.path + "/../destination" }
                    else { review["volumeUUID"] = UUID().uuidString }
                    roots[0]["destinationReview"] = review
                    journal["roots"] = roots
                }
                let before = try Data(contentsOf: fixture.journal)
                try expectPaused { _ = try fixture.lease() }
                XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
            }
        }
    }

    func testResetBeforePublicationRetiresAndPreservesBytes() throws {
        try withFixture { fixture in
            let lease = try fixture.lease()
            try lease.transition(.writing)
            let bytes = Data("unpublished bytes".utf8)
            try write(bytes, to: lease.descriptor)
            assertRetired(lease.reset())
            XCTAssertEqual(try Data(contentsOf: fixture.slot(0)), bytes)
            XCTAssertEqual(try fixture.states(), ["retired", "clean"])
        }
    }

    func testHardlinkIntroducedAtPretruncateHookRetiresWithoutTruncatingAlias() throws {
        try withFixture { fixture in
            let stage = fixture.slot(0)
            let alias = fixture.destination.appendingPathComponent("linked-output")
            let failing = ScreenshotStagingPool(registryDirectory: fixture.registry, fault: { point in
                if case .beforeTruncate = point {
                    guard link(stage.path, alias.path) == 0 else { throw PoolTestFailure.injected }
                }
            })
            let lease = try failing.lease(sourceDirectory: fixture.source, destinationDirectory: fixture.destination)
            try lease.transition(.writing)
            let bytes = Data("aliased bytes must survive".utf8)
            try write(bytes, to: lease.descriptor)
            try lease.transition(.prepared)
            try lease.transition(.publishing)
            assertRetired(lease.reset())
            XCTAssertEqual(try Data(contentsOf: alias), bytes)
            XCTAssertEqual(try fixture.states(), ["retired", "clean"])
        }
    }

    func testNonemptyACLOnRegistryRootOrSlotBlocksAdmissionWithoutClearingACL() throws {
        for location in 0..<3 {
            try withFixture { fixture in
                let url = location == 0 ? fixture.registry : (location == 1 ? fixture.root : fixture.slot(0))
                let command = Process()
                command.executableURL = URL(fileURLWithPath: "/bin/chmod")
                command.arguments = ["+a", "everyone allow read", url.path]
                try command.run()
                command.waitUntilExit()
                XCTAssertEqual(command.terminationStatus, 0)
                try expectPaused { _ = try fixture.lease() }
                let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
                defer { close(descriptor) }
                let acl = try XCTUnwrap(acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED))
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                XCTAssertEqual(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry), 0)
            }
        }
    }

    func testCreationBaselineIsPersistedAndReusedAcrossPoolInstances() throws {
        try withFixture { fixture in
            let first = try fixture.lease()
            let baseline = first.baseline
            XCTAssertTrue(baseline.provenance == nil || baseline.provenance?.count == 11)
            XCTAssertLessThanOrEqual(baseline.chargedBytes, ScreenshotStagingLimits.maximumMetadataBytes)
            try publishing(first)
            assertClean(first.reset())
            let restarted = ScreenshotStagingPool(registryDirectory: fixture.registry)
            let second = try restarted.lease(sourceDirectory: fixture.source, destinationDirectory: fixture.destination)
            XCTAssertEqual(second.baseline, baseline)
            try publishing(second)
            assertClean(second.reset())
        }
    }

    func testMissingChangedAndInvalidLengthCreationBaselinePauseWithoutAdoption() throws {
        for kind in 0..<3 {
            try withFixture { fixture in
                try fixture.editJournal { journal in
                    var roots = journal["roots"] as! [[String: Any]]
                    var slots = roots[0]["slots"] as! [[String: Any]]
                    if kind == 0 {
                        slots[0].removeValue(forKey: "baseline")
                    } else {
                        let bad = Data(repeating: 0xA5, count: kind == 1 ? 11 : 10)
                        slots[0]["baseline"] = ["provenance": bad.base64EncodedString()]
                    }
                    roots[0]["slots"] = slots
                    journal["roots"] = roots
                }
                let before = try Data(contentsOf: fixture.journal)
                try expectPaused { _ = try fixture.lease() }
                XCTAssertEqual(try Data(contentsOf: fixture.journal), before)
            }
        }
    }

    func testUnknownCleanSlotMetadataIsRejectedWithoutClearingIt() throws {
        try withFixture { fixture in
            let descriptor = open(fixture.slot(0).path, O_RDWR | O_CLOEXEC)
            defer { close(descriptor) }
            let name = "com.macfleet.shotdrop.unexpected"
            let bytes = Data("unrecognized metadata".utf8)
            try setAttribute(name, value: bytes, descriptor: descriptor)
            try expectPaused { _ = try fixture.lease() }
            XCTAssertEqual(fgetxattr(descriptor, name, nil, 0, 0, 0), bytes.count)
        }
    }

    private func publishing(_ lease: ScreenshotStagingLease) throws {
        try lease.transition(.writing)
        try lease.transition(.prepared)
        try lease.transition(.publishing)
    }

    private func assertClean(_ result: ScreenshotStageHousekeeping, file: StaticString = #filePath, line: UInt = #line) {
        guard case .clean = result else { return XCTFail("Expected clean reset, got \(result)", file: file, line: line) }
    }

    private func assertRetired(_ result: ScreenshotStageHousekeeping, file: StaticString = #filePath, line: UInt = #line) {
        guard case .retired = result else { return XCTFail("Expected retired slot", file: file, line: line) }
    }

    private func expectPaused(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? ScreenshotCopyFailure)?.code, .stagingPaused, file: file, line: line)
        }
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        let count = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw PoolTestFailure.injected }
    }

    private func setAttribute(_ name: String, value: Data, descriptor: Int32) throws {
        let result = value.withUnsafeBytes { fsetxattr(descriptor, name, $0.baseAddress, $0.count, 0, 0) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func withFixture(register: Bool = true, legacyAccounted: Bool = true, _ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture(legacyAccounted: legacyAccounted)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        if register { try fixture.register() }
        try body(fixture)
    }

    private struct Fixture {
        let base: URL
        var registry: URL { base.appendingPathComponent("registry", isDirectory: true) }
        var root: URL { base.appendingPathComponent("pool", isDirectory: true) }
        var source: URL { base.appendingPathComponent("source", isDirectory: true) }
        var destination: URL { base.appendingPathComponent("destination", isDirectory: true) }
        var journal: URL { registry.appendingPathComponent("registry.json") }
        var pool: ScreenshotStagingPool { ScreenshotStagingPool(registryDirectory: registry) }

        init(legacyAccounted: Bool) throws {
            guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw PoolTestFailure.injected
            }
            defer { free(canonical) }
            base = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
                .appendingPathComponent("ShotDropPool-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try pool.initialize(legacyArtifactsAccountedFor: legacyAccounted)
        }

        func register() throws { try pool.registerRoot(at: root, sourceDirectory: source, destinationDirectory: destination, ordinaryLocalDestinationReviewed: true) }
        func lease() throws -> ScreenshotStagingLease { try pool.lease(sourceDirectory: source, destinationDirectory: destination) }
        func slot(_ index: Int) -> URL { root.appendingPathComponent("slot-\(index).stage") }
        func children(_ url: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }
        func mode(_ url: URL) throws -> mode_t {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw PoolTestFailure.injected }
            return info.st_mode & 0o7777
        }
        func inodes() throws -> [UInt64] {
            try (0..<2).map { index in
                var info = stat()
                guard lstat(slot(index).path, &info) == 0 else { throw PoolTestFailure.injected }
                return UInt64(info.st_ino)
            }
        }
        func rootRecords() throws -> [[String: Any]] {
            let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [String: Any]
            return contents["roots"] as! [[String: Any]]
        }
        func states() throws -> [String] {
            (try rootRecords()[0]["slots"] as! [[String: Any]]).map { $0["state"] as! String }
        }
        func editJournal(_ edit: (inout [String: Any]) throws -> Void) throws {
            var contents = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [String: Any]
            try edit(&contents)
            let bytes = try JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys])
            // In-place writes preserve the pinned journal identity in the manifest.
            let descriptor = open(journal.path, O_RDWR | O_CLOEXEC)
            guard descriptor >= 0 else { throw PoolTestFailure.injected }
            defer { close(descriptor) }
            let count = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
            guard count == bytes.count, ftruncate(descriptor, off_t(bytes.count)) == 0, fsync(descriptor) == 0 else {
                throw PoolTestFailure.injected
            }
        }
    }
}

private enum PoolTestFailure: Error { case injected }

private enum PoolTestUnsupportedVolume: CaseIterable, Sendable {
    case noCloning, unknownCloning, noPersistentIDs, unknownPersistentIDs, readOnly, network, notAPFS, missingUUID
}

private struct PoolTestVolumeInspector: ScreenshotStagingVolumeInspecting {
    var deviceOffset: UInt64 = 0
    var unsupportedInode: UInt64? = nil
    var unsupported: PoolTestUnsupportedVolume = .noCloning

    func inspect(_ descriptor: Int32) throws -> ScreenshotStagingVolume {
        let actual = try DarwinScreenshotStagingVolumeInspector().inspect(descriptor)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw PoolTestFailure.injected }
        let fail = unsupportedInode == UInt64(info.st_ino)
        return ScreenshotStagingVolume(
            volumeUUID: fail && unsupported == .missingUUID
                ? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) : actual.volumeUUID,
            device: actual.device + deviceOffset,
            isLocal: fail && unsupported == .network ? false : actual.isLocal,
            isReadOnly: fail && unsupported == .readOnly ? true : actual.isReadOnly,
            isInternal: actual.isInternal, isRemovable: actual.isRemovable, isEjectable: actual.isEjectable,
            fileSystemType: fail && unsupported == .notAPFS ? "hfs" : actual.fileSystemType,
            supportsCloning: fail && unsupported == .unknownCloning ? nil
                : (fail && unsupported == .noCloning ? false : actual.supportsCloning),
            supportsPersistentIDs: fail && unsupported == .unknownPersistentIDs ? nil
                : (fail && unsupported == .noPersistentIDs ? false : actual.supportsPersistentIDs)
        )
    }
}
