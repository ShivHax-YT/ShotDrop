import Darwin
import Foundation
import XCTest
@testable import ShotDrop

final class DefaultDestinationPolicyPathTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let accounts: URL
        let home: URL
        let pictures: URL

        init(picturesExists: Bool = true) throws {
            let raw = FileManager.default.temporaryDirectory
                .appendingPathComponent("shotdrop-policy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            guard let physical = realpath(raw.path, nil) else { throw DefaultDestinationPolicyIssue.unsafePath }
            root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            free(physical)
            accounts = root.appendingPathComponent("Users", isDirectory: true)
            home = accounts.appendingPathComponent("alice", isDirectory: true)
            pictures = home.appendingPathComponent("Pictures", isDirectory: true)
            try FileManager.default.createDirectory(at: picturesExists ? pictures : home,
                                                    withIntermediateDirectories: true)
        }

        func inspector(
            home requestedHome: URL? = nil,
            recordHome: URL? = nil,
            standardPictures: URL? = nil,
            cloud: @escaping @Sendable (URL) throws -> Bool? = { _ in false },
            provider: @escaping @Sendable (URL, Int32) throws -> Bool? = { _, _ in false },
            volume: @escaping @Sendable (Int32) throws -> ScreenshotStagingVolume = DefaultDestinationPolicyPathTests.supportedVolume
        ) -> DefaultDestinationPolicyPathInspector {
            DefaultDestinationPolicyPathInspector(
                accountsRoot: accounts, accountName: "alice", accountRecordHome: recordHome ?? home,
                requestedHome: requestedHome ?? home, standardPictures: standardPictures ?? pictures,
                operations: DefaultDestinationPolicyOperations(
                    inspectVolume: volume, isUbiquitous: cloud, isProviderManaged: provider
                )
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func supportedVolume(_ fd: Int32) throws -> ScreenshotStagingVolume {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw DefaultDestinationPolicyIssue.unsupported }
        return ScreenshotStagingVolume(
            volumeUUID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            device: UInt64(UInt32(bitPattern: info.st_dev)), isLocal: true, isReadOnly: false,
            isInternal: true, isRemovable: false, isEjectable: false, fileSystemType: "apfs",
            supportsCloning: true, supportsPersistentIDs: true
        )
    }

    func testExactDefaultParentReturnsPinnedBindingWithoutTouchingChild() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = fixture.inspector()
        try inspector.withInspectedParent { fd, parent in
        XCTAssertEqual(parent.path.path, fixture.pictures.path)
        XCTAssertEqual(parent.childPath.path, fixture.pictures.appendingPathComponent("ShotDrop").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.childPath.path))
        XCTAssertEqual(try DefaultDestinationDirectoryIdentity(fd), parent.identity)
        try inspector.revalidate(parent, parentDescriptor: fd)
        }
    }

    func testMissingPicturesAndRedirectedHomeFailClosed() throws {
        let missing = try Fixture(picturesExists: false); defer { missing.remove() }
        XCTAssertThrowsError(try missing.inspector().withInspectedParent { _, _ in }) { XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .missingPictures) }
        let fixture = try Fixture(); defer { fixture.remove() }
        let alternate = fixture.root.appendingPathComponent("other", isDirectory: true)
        XCTAssertThrowsError(try fixture.inspector(home: alternate).withInspectedParent { _, _ in }) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .redirectedHome)
        }
        XCTAssertThrowsError(try fixture.inspector(recordHome: alternate).withInspectedParent { _, _ in }) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .redirectedHome)
        }
        XCTAssertThrowsError(try fixture.inspector(standardPictures: alternate).withInspectedParent { _, _ in }) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .redirectedHome)
        }
    }

    func testSymlinkPicturesIsNeverFollowed() throws {
        let fixture = try Fixture(picturesExists: false); defer { fixture.remove() }
        let elsewhere = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.pictures, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try fixture.inspector().withInspectedParent { _, _ in }) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .unsafePath)
        }
    }

    func testCloudTrueUnknownAndErrorAllReject() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.inspector(cloud: { _ in true }).withInspectedParent { _, _ in }) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .unsupported)
        }
        XCTAssertThrowsError(try fixture.inspector(cloud: { _ in nil }).withInspectedParent { _, _ in }) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .cloudStatusUnknown)
        }
        XCTAssertThrowsError(try fixture.inspector(cloud: { _ in throw DefaultDestinationPolicyIssue.unsupported }).withInspectedParent { _, _ in }) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .cloudStatusUnknown)
        }
    }

    func testProviderNegativeAllowedButPositiveUnknownAndErrorReject() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.inspector(provider: { _, _ in false }).withInspectedParent { _, _ in }
        XCTAssertThrowsError(try fixture.inspector(provider: { _, _ in true }).withInspectedParent { _, _ in }) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .unsupported)
        }
        XCTAssertThrowsError(try fixture.inspector(provider: { _, _ in nil }).withInspectedParent { _, _ in }) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .providerStatusUnknown)
        }
        XCTAssertThrowsError(try fixture.inspector(provider: { _, _ in throw DefaultDestinationPolicyIssue.unsupported }).withInspectedParent { _, _ in }) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .providerStatusUnknown)
        }
    }

    func testUnsupportedVolumeMatrixRejects() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let base = try fixture.inspector().withInspectedParent { fd, _ in try Self.supportedVolume(fd) }
        let variants: [ScreenshotStagingVolume] = [
            .init(volumeUUID: UUID(), device: base.device, isLocal: true, isReadOnly: true, isInternal: true,
                  isRemovable: false, isEjectable: false, fileSystemType: "apfs", supportsCloning: true, supportsPersistentIDs: true),
            .init(volumeUUID: UUID(), device: base.device, isLocal: true, isReadOnly: false, isInternal: false,
                  isRemovable: false, isEjectable: false, fileSystemType: "apfs", supportsCloning: true, supportsPersistentIDs: true),
            .init(volumeUUID: UUID(), device: base.device, isLocal: true, isReadOnly: false, isInternal: true,
                  isRemovable: true, isEjectable: false, fileSystemType: "apfs", supportsCloning: true, supportsPersistentIDs: true),
            .init(volumeUUID: UUID(), device: base.device, isLocal: true, isReadOnly: false, isInternal: true,
                  isRemovable: false, isEjectable: false, fileSystemType: "apfs", supportsCloning: nil, supportsPersistentIDs: true),
            .init(volumeUUID: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), device: base.device,
                  isLocal: true, isReadOnly: false, isInternal: true, isRemovable: false, isEjectable: false,
                  fileSystemType: "apfs", supportsCloning: true, supportsPersistentIDs: true)
        ]
        for variant in variants {
            XCTAssertThrowsError(try fixture.inspector(volume: { _ in variant }).withInspectedParent { _, _ in }) {
                XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .unsupported)
            }
        }
    }

    func testPathReplacementInvalidatesPinnedBinding() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = fixture.inspector()
        try inspector.withInspectedParent { fd, parent in
        let moved = fixture.home.appendingPathComponent("Pictures-old", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.pictures, to: moved)
        try FileManager.default.createDirectory(at: fixture.pictures, withIntermediateDirectories: false)
        XCTAssertThrowsError(try inspector.revalidate(parent, parentDescriptor: fd)) {
            XCTAssertEqual($0 as? DefaultDestinationPolicyIssue, .changed)
        }
        }
    }
}
