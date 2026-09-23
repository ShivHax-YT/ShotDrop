import Darwin
import Foundation
import XCTest
@testable import ShotDrop

final class DefaultDestinationJournalTests: XCTestCase {
    func testIntentSurvivesReloadAndBlocksAnotherCreation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let intent = try fixture.intent()
        try fixture.journal.begin(intent)
        XCTAssertEqual(try fixture.journal.load(), .intent(intent))
        XCTAssertThrowsError(try DefaultDestinationJournal(directory: fixture.journal.directory).begin(try fixture.intent())) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .priorOperationNeedsReview)
        }
    }

    func testCreatedReceiptPreservesExactBindingAndCannotBeResetByBegin() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let intent = try fixture.intent()
        try fixture.journal.begin(intent)
        let created = fixture.createdIdentity()
        try fixture.journal.recordCreated(intent, created: created)
        XCTAssertEqual(try fixture.journal.load(), .created(.init(intent: intent, created: .init(created))))
        XCTAssertThrowsError(try fixture.journal.begin(intent)) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .priorOperationNeedsReview)
        }
    }

    func testCreatedButUnenrolledSurvivesRestartAndNeedsSeparateEnrollment() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let intent = try fixture.intent()
        let created = fixture.createdIdentity()
        try fixture.journal.begin(intent)
        try fixture.journal.recordCreated(intent, created: created)
        let restarted = DefaultDestinationJournal(directory: fixture.journal.directory)
        XCTAssertEqual(try restarted.load(), .created(.init(intent: intent, created: .init(created))))
        XCTAssertThrowsError(try restarted.begin(try fixture.intent())) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .priorOperationNeedsReview)
        }
    }

    func testEnrolledMarkerSurvivesRepeatedRestartAndCannotBeReplayed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let intent = try fixture.intent()
        let created = fixture.createdIdentity()
        try fixture.journal.begin(intent)
        try fixture.journal.recordCreated(intent, created: created)
        try fixture.journal.recordEnrolled(intent, created: created)
        for _ in 0..<3 {
            let restarted = DefaultDestinationJournal(directory: fixture.journal.directory)
            XCTAssertEqual(try restarted.load(), .enrolled(.init(intent: intent, created: .init(created))))
            XCTAssertThrowsError(try restarted.recordEnrolled(intent, created: created)) {
                XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .mismatchedOperation)
            }
        }
    }

    func testEnrollmentRejectsMissingReceiptAndDifferentCreatedObject() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let intent = try fixture.intent()
        let created = fixture.createdIdentity()
        try fixture.journal.begin(intent)
        XCTAssertThrowsError(try fixture.journal.recordEnrolled(intent, created: created)) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .mismatchedOperation)
        }
        try fixture.journal.recordCreated(intent, created: created)
        let replacement = ShotDropSetupDirectoryIdentity(path: created.path, device: created.device,
            inode: created.inode + 1, birthSeconds: created.birthSeconds,
            birthNanoseconds: created.birthNanoseconds)
        XCTAssertThrowsError(try fixture.journal.recordEnrolled(intent, created: replacement)) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .mismatchedOperation)
        }
        XCTAssertEqual(try fixture.journal.load(), .created(.init(intent: intent, created: .init(created))))
    }

    func testStaleOperationCannotRecordReceipt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let intent = try fixture.intent()
        try fixture.journal.begin(intent)
        XCTAssertThrowsError(try fixture.journal.recordCreated(try fixture.intent(), created: fixture.createdIdentity())) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .mismatchedOperation)
        }
        XCTAssertEqual(try fixture.journal.load(), .intent(intent))
    }

    func testReceiptRejectsWrongObjectWithoutChangingIntent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let intent = try fixture.intent()
        try fixture.journal.begin(intent)
        let wrong = ShotDropSetupDirectoryIdentity(path: fixture.destination.appendingPathComponent("other").path,
            device: fixture.parent.device, inode: 1001, birthSeconds: 1, birthNanoseconds: 0)
        XCTAssertThrowsError(try fixture.journal.recordCreated(intent, created: wrong)) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .invalidBinding)
        }
        XCTAssertEqual(try fixture.journal.load(), .intent(intent))
    }

    func testPendingWriteBlocksEvenWhenPrimaryRecordLooksValid() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let intent = try fixture.intent()
        try fixture.journal.begin(intent)
        try Data("interrupted".utf8).write(to: fixture.journal.directory.appendingPathComponent("default-destination.pending"))
        XCTAssertThrowsError(try fixture.journal.load()) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .corruptOrUnsupported)
        }
    }

    func testCorruptAndOversizedRecordsBlock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let path = fixture.journal.directory.appendingPathComponent("default-destination.json")
        try Data("broken".utf8).write(to: path)
        XCTAssertThrowsError(try fixture.journal.load()) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .corruptOrUnsupported)
        }
        try Data(repeating: 32, count: DefaultDestinationJournal.maximumBytes + 1).write(to: path)
        XCTAssertThrowsError(try fixture.journal.load()) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .corruptOrUnsupported)
        }
    }

    func testRejectsDestinationOutsideBoundParent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        XCTAssertThrowsError(try DefaultDestinationJournal.Intent(
            destination: fixture.root.deletingLastPathComponent().appendingPathComponent("wrong"),
            volumeUUID: UUID(), parent: fixture.parent
        )) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .invalidBinding)
        }
        XCTAssertEqual(try fixture.journal.load(), .empty)
    }

    private final class Fixture {
        let root: URL
        let destination: URL
        let parent: ShotDropSetupDirectoryIdentity
        let journal: DefaultDestinationJournal

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("ShotDropJournal-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard let resolved = realpath(base.path, nil) else { throw DefaultDestinationJournal.Fault.unavailable }
            let canonical = URL(fileURLWithPath: String(cString: resolved))
            free(resolved)
            root = canonical
            destination = canonical.appendingPathComponent("Screenshots", isDirectory: true)
            let journalDirectory = canonical.appendingPathComponent("journal", isDirectory: true)
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            journal = DefaultDestinationJournal(directory: journalDirectory)
            var info = stat()
            guard stat(canonical.path, &info) == 0 else { throw DefaultDestinationJournal.Fault.unavailable }
            parent = ShotDropSetupDirectoryIdentity(path: canonical.path,
                device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                birthSeconds: Int64(info.st_birthtimespec.tv_sec),
                birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
        }

        func intent() throws -> DefaultDestinationJournal.Intent {
            try .init(destination: destination, volumeUUID: UUID(), parent: parent)
        }

        func createdIdentity() -> ShotDropSetupDirectoryIdentity {
            ShotDropSetupDirectoryIdentity(path: destination.path, device: parent.device,
                inode: parent.inode + 1, birthSeconds: parent.birthSeconds + 1, birthNanoseconds: 0)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
