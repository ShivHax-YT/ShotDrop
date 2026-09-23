import Darwin
import Foundation
import XCTest
@testable import ShotDrop

final class DefaultDestinationJournalReadOnlyTests: XCTestCase {
    func testAbsentDirectoryReturnsEmptyWithoutCreatingAnything() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        let missing = fixture.root.appendingPathComponent("missing/child", isDirectory: true)
        XCTAssertEqual(try DefaultDestinationJournal(directory: missing).loadReadOnly(), .empty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("missing").path))
    }

    func testEmptyDirectoryDoesNotCreateLockOrJournal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for _ in 0..<3 { XCTAssertEqual(try fixture.journal.loadReadOnly(), .empty) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.journal.directory.path), [])
    }

    func testIntentCreatedAndEnrolledAreReadWithoutChangingBytesOrNames() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        let created = fixture.created
        try fixture.journal.begin(intent)
        try assertPreserved(fixture, expected: .intent(intent))
        try fixture.journal.recordCreated(intent, created: created)
        let receipt = DefaultDestinationJournal.Receipt(intent: intent, created: .init(created))
        try assertPreserved(fixture, expected: .created(receipt))
        try fixture.journal.recordEnrolled(intent, created: created)
        try assertPreserved(fixture, expected: .enrolled(receipt))
    }

    func testExistingLockWithoutReceiptReadsEmptyWithoutNewFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.journal.load(), .empty) // Fixture setup creates the lock.
        let before = try fixture.files()
        XCTAssertEqual(try fixture.journal.loadReadOnly(), .empty)
        XCTAssertEqual(try fixture.files(), before)
    }

    func testOrphanedMalformedAndPendingEvidenceNeverLooksEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let journalURL = fixture.journal.directory.appendingPathComponent("default-destination.json")
        try Data("broken".utf8).write(to: journalURL)
        let before = try fixture.files()
        XCTAssertThrowsError(try fixture.journal.loadReadOnly()) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .corruptOrUnsupported)
        }
        XCTAssertEqual(try fixture.files(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.directory.appendingPathComponent("default-destination.lock").path))
        try FileManager.default.removeItem(at: journalURL)
        try fixture.journal.begin(fixture.intent())
        try Data("bad JSON".utf8).write(to: journalURL)
        XCTAssertThrowsError(try fixture.journal.loadReadOnly())
        let pendingURL = fixture.journal.directory.appendingPathComponent("default-destination.pending")
        try Data("interrupted".utf8).write(to: pendingURL)
        let pendingBefore = try fixture.files()
        XCTAssertThrowsError(try fixture.journal.loadReadOnly())
        XCTAssertEqual(try fixture.files(), pendingBefore)
    }

    func testExclusiveWriterLockReturnsUnavailableAndDoesNotModifyReceipt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.journal.begin(fixture.intent())
        let before = try fixture.files()
        let fd = open(fixture.journal.directory.appendingPathComponent("default-destination.lock").path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { flock(fd, LOCK_UN) }
        XCTAssertThrowsError(try fixture.journal.loadReadOnly()) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .unavailable)
        }
        XCTAssertEqual(try fixture.files(), before)
    }

    func testUnsafeDirectoryAndDanglingSymlinkFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(chmod(fixture.journal.directory.path, 0o755), 0)
        XCTAssertThrowsError(try fixture.journal.loadReadOnly()) {
            XCTAssertEqual($0 as? DefaultDestinationJournal.Fault, .unavailable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.journal.directory.path), [])
        let link = fixture.root.appendingPathComponent("link")
        XCTAssertEqual(symlink("absent", link.path), 0)
        XCTAssertThrowsError(try DefaultDestinationJournal(directory: link).loadReadOnly())
    }

    private func assertPreserved(_ fixture: Fixture, expected: DefaultDestinationJournal.State) throws {
        let before = try fixture.files()
        XCTAssertEqual(try DefaultDestinationJournal(directory: fixture.journal.directory).loadReadOnly(), expected)
        XCTAssertEqual(try fixture.files(), before)
    }

    private struct Fixture {
        let root: URL
        let journal: DefaultDestinationJournal
        let parent: ShotDropSetupDirectoryIdentity
        var created: ShotDropSetupDirectoryIdentity {
            .init(path: root.appendingPathComponent("Screenshots").path, device: parent.device,
                  inode: parent.inode + 1, birthSeconds: parent.birthSeconds + 1, birthNanoseconds: 0)
        }
        init() throws {
            guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw DefaultDestinationJournal.Fault.unavailable
            }
            defer { free(path) }
            root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                .appendingPathComponent("journal-readonly-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let directory = root.appendingPathComponent("journal", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            journal = DefaultDestinationJournal(directory: directory)
            var info = stat()
            guard stat(root.path, &info) == 0 else { throw DefaultDestinationJournal.Fault.unavailable }
            parent = .init(path: root.path, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
        }
        func intent() throws -> DefaultDestinationJournal.Intent {
            try .init(destination: root.appendingPathComponent("Screenshots"), volumeUUID: UUID(), parent: parent)
        }
        func files() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: journal.directory.path)
                .map { ($0, try Data(contentsOf: journal.directory.appendingPathComponent($0))) })
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
