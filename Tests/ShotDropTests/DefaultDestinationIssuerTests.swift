import Darwin
import Foundation
import XCTest
@testable import ShotDrop

final class DefaultDestinationIssuerTests: XCTestCase {
    func testCrashCheckpointsPreserveBoundedRecoveryAndSource() throws {
        for point in [DefaultDestinationIssuerCheckpoint.beforeIntent, .afterIntent, .afterCreation,
                      .afterCreatedReceipt, .afterRegistration] {
            let f = try Fixture(); defer { f.remove() }
            let issuer = DefaultDestinationIssuer(inspector: f.inspector, journal: f.journal, pool: f.pool,
                checkpoint: { current in
                    if current == point { throw DefaultDestinationIssuerIssue.needsReview }
                })
            XCTAssertThrowsError(try issuer.createAndEnroll(sourceDirectory: f.source, stagingRoot: f.staging))
            XCTAssertEqual(try f.rootCount(), point == .afterRegistration ? 1 : 0)
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.destination.path),
                           point != .beforeIntent && point != .afterIntent)
            XCTAssertEqual(try Data(contentsOf: f.original), Data("original".utf8))
            if point != .beforeIntent {
                XCTAssertThrowsError(try f.issuer.createAndEnroll(sourceDirectory: f.source, stagingRoot: f.staging))
                XCTAssertThrowsError(try f.issuer.resumeEnrolled(sourceDirectory: f.source, stagingRoot: f.staging))
            }
        }
    }

    func testFreshEnrollmentAndRestartKeepOneRootAndOriginal() throws {
        let f = try Fixture(); defer { f.remove() }
        let initial = try f.issuer.createAndEnroll(sourceDirectory: f.source, stagingRoot: f.staging)
        let resumed = try f.issuer.resumeEnrolled(sourceDirectory: f.source, stagingRoot: f.staging)
        XCTAssertEqual(initial.binding, resumed.binding)
        XCTAssertEqual(try f.rootCount(), 1)
        XCTAssertEqual(try Data(contentsOf: f.original), Data("original".utf8))
        guard case .enrolled = try f.journal.load() else { return XCTFail("Expected durable enrollment") }
        XCTAssertThrowsError(try f.issuer.createAndEnroll(sourceDirectory: f.source, stagingRoot: f.staging))
        XCTAssertEqual(try f.rootCount(), 1)
    }

    func testUnboundExistingDirectoryNeverGetsAdoptedOrCharged() throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false)
        XCTAssertThrowsError(try f.issuer.createAndEnroll(sourceDirectory: f.source, stagingRoot: f.staging)) {
            XCTAssertEqual($0 as? DefaultDestinationIssuerIssue, .collision)
        }
        XCTAssertEqual(try f.rootCount(), 0)
        XCTAssertEqual(try f.journal.load(), .empty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.path))
    }

    func testReplacementAfterCreationIsPreservedWithoutAttestationOrCharge() throws {
        let f = try Fixture(); defer { f.remove() }
        let destination = f.destination
        let retained = f.pictures.appendingPathComponent("retained")
        let issuer = DefaultDestinationIssuer(inspector: f.inspector, journal: f.journal, pool: f.pool,
            checkpoint: { point in
                if point == .afterCreation {
                    try FileManager.default.moveItem(at: destination, to: retained)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                }
            })
        XCTAssertThrowsError(try issuer.createAndEnroll(sourceDirectory: f.source, stagingRoot: f.staging))
        XCTAssertEqual(try f.rootCount(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testInterruptedIntentBlocksRetryWithoutCreatingLeaf() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.inspector.withInspectedParent { _, parent in
            let identity = ShotDropSetupDirectoryIdentity(path: parent.path.path,
                device: parent.identity.device, inode: parent.identity.inode,
                birthSeconds: parent.identity.birthSeconds, birthNanoseconds: parent.identity.birthNanoseconds)
            try f.journal.begin(.init(destination: parent.childPath,
                                     volumeUUID: parent.volume.volumeUUID, parent: identity))
        }
        XCTAssertThrowsError(try f.issuer.createAndEnroll(sourceDirectory: f.source, stagingRoot: f.staging))
        XCTAssertThrowsError(try f.issuer.resumeEnrolled(sourceDirectory: f.source, stagingRoot: f.staging))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        XCTAssertEqual(try f.rootCount(), 0)
    }

    func testRegistrationFailureKeepsChargedIntentAndCreatedFolder() throws {
        let f = try Fixture(); defer { f.remove() }
        let pool = ScreenshotStagingPool(registryDirectory: f.registry,
            defaultPolicyInspector: f.inspector, fault: { stage in
                if case .beforeRootCreation = stage { throw DefaultDestinationIssuerIssue.enrollmentPaused }
            })
        let issuer = DefaultDestinationIssuer(inspector: f.inspector, journal: f.journal, pool: pool)
        XCTAssertThrowsError(try issuer.createAndEnroll(sourceDirectory: f.source, stagingRoot: f.staging)) {
            XCTAssertEqual($0 as? DefaultDestinationIssuerIssue, .enrollmentCharged)
        }
        XCTAssertEqual(try f.rootCount(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.path))
        guard case .created = try f.journal.load() else { return XCTFail("Keep unenrolled receipt") }
        XCTAssertThrowsError(try issuer.resumeEnrolled(sourceDirectory: f.source, stagingRoot: f.staging))
        XCTAssertEqual(try Data(contentsOf: f.original), Data("original".utf8))
    }

    func testReplacedDestinationCannotResumeOrLease() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.issuer.createAndEnroll(sourceDirectory: f.source, stagingRoot: f.staging)
        let retained = f.pictures.appendingPathComponent("retained")
        try FileManager.default.moveItem(at: f.destination, to: retained)
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try f.issuer.resumeEnrolled(sourceDirectory: f.source, stagingRoot: f.staging))
        XCTAssertThrowsError(try f.pool.lease(sourceDirectory: f.source, destinationDirectory: f.destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertEqual(try f.rootCount(), 1)
    }

    func testSourceOverlapPausesBeforeIntentAndCreation() throws {
        let f = try Fixture(); defer { f.remove() }
        XCTAssertThrowsError(try f.issuer.createAndEnroll(sourceDirectory: f.pictures, stagingRoot: f.staging))
        XCTAssertEqual(try f.journal.load(), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        XCTAssertEqual(try f.rootCount(), 0)
    }

    private struct Fixture {
        let root: URL
        var accounts: URL { root.appendingPathComponent("Users") }
        var home: URL { accounts.appendingPathComponent("fixture") }
        var pictures: URL { home.appendingPathComponent("Pictures") }
        var destination: URL { pictures.appendingPathComponent("ShotDrop") }
        var source: URL { root.appendingPathComponent("source") }
        var original: URL { source.appendingPathComponent("original.png") }
        var registry: URL { root.appendingPathComponent("registry") }
        var staging: URL { root.appendingPathComponent("staging") }
        var journal: DefaultDestinationJournal { .init(directory: root.appendingPathComponent("journal")) }
        var inspector: DefaultDestinationPolicyPathInspector {
            .init(accountsRoot: accounts, accountName: "fixture", accountRecordHome: home,
                  requestedHome: home, standardPictures: pictures,
                  operations: .init(isUbiquitous: { _ in false }))
        }
        var pool: ScreenshotStagingPool {
            .init(registryDirectory: registry, defaultPolicyInspector: inspector)
        }
        var issuer: DefaultDestinationIssuer { .init(inspector: inspector, journal: journal, pool: pool) }

        init() throws {
            root = try resolvedStagingTemporaryDirectory().appendingPathComponent("ShotDropIssuer-\(UUID())")
            for directory in [pictures, source, journal.directory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try Data("original".utf8).write(to: original)
            try pool.initialize(legacyArtifactsAccountedFor: true)
        }

        func rootCount() throws -> Int {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: registry.appendingPathComponent("registry.json"))) as? [String: Any]
            return (json?["roots"] as? [Any])?.count ?? -1
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
