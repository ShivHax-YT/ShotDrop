import Foundation

/// Publication can succeed even when a private slot must remain charged and retired.
enum ScreenshotStageHousekeeping: Sendable, Equatable {
    case clean
    case retired(String)
}

struct VerifiedScreenshotCopy: Sendable {
    let destinationURL: URL
    let identity: ScreenshotFileIdentity
    let outputToken: UUID
    var housekeeping: ScreenshotStageHousekeeping = .clean
}

/// Copied with the staged file so output suppression survives cloning to a new inode.
enum ScreenshotOutputMarker {
    static let attributeName = "com.macfleet.shotdrop.output-token"
}

struct ScreenshotCopyFailure: Error, LocalizedError, Sendable {
    enum Code: String, Sendable {
        case collision, sourceUnavailable, sourceChanged, destinationUnavailable
        case permissionDenied, verificationFailed, invalidName, ioFailure, stagingPaused
    }
    let code: Code
    let detail: String
    var recoverableDestination: URL? = nil
    var posixCode: Int32? = nil
    var errorDescription: String? { detail }
}

/// A staged transaction is confined to the organizer actor. Never removes its source.
protocol ScreenshotStagedCopy: AnyObject {
    var identity: ScreenshotFileIdentity { get }
    var outputToken: UUID { get }
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

/// Runs at the formerly vulnerable gap between a pathname check and its mutation.
enum ScreenshotCopyRacePoint: Sendable, CaseIterable {
    case afterStageVerificationBeforePublish
    case afterCloneBeforeOutputOpen
    case afterStageIdentityCheckBeforeCleanup
}
