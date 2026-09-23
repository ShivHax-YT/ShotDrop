import Foundation

struct VerifiedScreenshotCopy: Sendable {
    let destinationURL: URL
    let identity: ScreenshotFileIdentity
}

struct ScreenshotCopyFailure: Error, LocalizedError, Sendable {
    enum Code: String, Sendable {
        case collision, sourceUnavailable, sourceChanged, destinationUnavailable
        case permissionDenied, verificationFailed, invalidName, ioFailure
    }
    let code: Code
    let detail: String
    var recoverableDestination: URL? = nil
    var errorDescription: String? { detail }
}

/// A staged transaction is confined to the organizer actor. Never removes its source.
protocol ScreenshotStagedCopy: AnyObject {
    var identity: ScreenshotFileIdentity { get }
    func publish(named filename: String) throws -> VerifiedScreenshotCopy
    func discard()
}

protocol ScreenshotOrganizationFileSystem: Sendable {
    func stageCopy(
        source: URL,
        destinationRoot: URL,
        subdirectories: [String],
        expectedIdentity: ScreenshotFileIdentity?
    ) throws -> any ScreenshotStagedCopy
}

/// Narrow fault-injection boundary for deterministic data-preservation tests.
enum ScreenshotCopyPhase: Sendable, CaseIterable {
    case beforeCopy, afterCopy, beforeVerification, beforePublish, afterPublish
}
