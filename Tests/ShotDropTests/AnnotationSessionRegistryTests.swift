import Foundation
import XCTest
@testable import ShotDrop

final class AnnotationSessionRegistryTests: XCTestCase {
    func testDuplicateReusesReservationEvenAtCapacity() throws {
        var registry = AnnotationSessionRegistry()
        let identity = try identity()
        let token = try opened(registry.admit(identity))
        for _ in 1..<AnnotationSessionRegistry.maximumSessions {
            _ = try opened(registry.admit(try self.identity()))
        }
        XCTAssertEqual(registry.admit(identity), .existing(token))
        XCTAssertEqual(registry.count, 3)
        XCTAssertEqual(registry.admit(try self.identity()), .full)
    }

    func testCaptureRevisionAndReferenceRemainDistinct() throws {
        var registry = AnnotationSessionRegistry()
        let original = try identity()
        let first = try opened(registry.admit(original))
        let revision = AnnotationSessionIdentity(captureID: original.captureID, revision: original.revision + 1, reference: original.reference)
        let second = try opened(registry.admit(revision))
        let reference = try identity(captureID: original.captureID, revision: original.revision, path: "/changed.png")
        let third = try opened(registry.admit(reference))
        XCTAssertEqual(Set([first, second, third]).count, 3)
        XCTAssertEqual(registry.count, 3)
    }

    func testDifferentCaptureWithSameRevisionAndReferenceGetsOwnSession() throws {
        var registry = AnnotationSessionRegistry()
        let original = try identity()
        let first = try opened(registry.admit(original))
        let otherCapture = AnnotationSessionIdentity(captureID: UUID(), revision: original.revision, reference: original.reference)
        let second = try opened(registry.admit(otherCapture))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(registry.count, 2)
    }

    func testClosingRetainsCapacityAndRequiresExactTokenToRelease() throws {
        var registry = AnnotationSessionRegistry()
        let identity = try identity()
        let token = try opened(registry.admit(identity))
        _ = try opened(registry.admit(try self.identity()))
        _ = try opened(registry.admit(try self.identity()))
        XCTAssertFalse(registry.releaseAfterDrain(token: token))
        XCTAssertTrue(registry.beginClosing(token: token))
        XCTAssertTrue(registry.isClosing(token: token))
        XCTAssertEqual(registry.admit(identity), .closing(token))
        XCTAssertEqual(registry.admit(try self.identity()), .full)
        XCTAssertFalse(registry.beginClosing(token: UUID()))
        XCTAssertFalse(registry.releaseAfterDrain(token: UUID()))
        XCTAssertEqual(registry.count, 3)
        XCTAssertTrue(registry.releaseAfterDrain(token: token))
        XCTAssertFalse(registry.releaseAfterDrain(token: token))
        let replacement = try opened(registry.admit(identity))
        XCTAssertNotEqual(replacement, token)
        XCTAssertFalse(registry.releaseAfterDrain(token: token))
        XCTAssertEqual(registry.admit(identity), .existing(replacement))
    }

    private func opened(_ admission: AnnotationSessionRegistry.Admission) throws -> UUID {
        guard case let .opened(token) = admission else {
            XCTFail("Expected a new reservation, got \(admission)")
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return token
    }

    private func identity(captureID: UUID = UUID(), revision: UInt64 = 1, path: String = "/source.png") throws -> AnnotationSessionIdentity {
        let data = try JSONSerialization.data(withJSONObject: [
            "bookmarkData": Data([1]).base64EncodedString(), "lastKnownPath": path,
            "role": "savedCopy", "volumeUUID": UUID().uuidString,
            "persistentFileID": 1, "birthSeconds": 1, "birthNanoseconds": 0,
            "byteCount": 1, "sha256": String(repeating: "a", count: 64)
        ])
        return AnnotationSessionIdentity(captureID: captureID, revision: revision,
            reference: try JSONDecoder().decode(RecentFileReference.self, from: data))
    }
}
