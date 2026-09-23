import Darwin
import Foundation

/// The caller explains destination access before a user selects or approves a folder.
enum ScreenshotDestinationAccess: Sendable {
    case needsExplanation
    case userApproved
}

struct ScreenshotSaveRequest: Sendable {
    let organization: ScreenshotOrganizationRequest
    let sourceDirectoryURL: URL
    var destinationAccess: ScreenshotDestinationAccess = .needsExplanation
}

enum ScreenshotOriginalStatus: Sendable {
    case available, changed, unavailable, notChecked
}

enum ScreenshotSaveRecoveryAction: String, Identifiable, Sendable {
    case retry, chooseDestination, revealOriginal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .retry: "Retry"
        case .chooseDestination: "Choose Destination…"
        case .revealOriginal: "Reveal Original"
        }
    }
}

struct ScreenshotSaveFailure: Sendable {
    enum Reason: Sendable {
        case accessRequired, destinationOverlap, invalidDestination, stagingPaused
        case unsupportedFilesystem, crossDeviceClone, noSpace, permissionDenied
        case verificationFailed, collision, invalidName, sourceUnavailable, sourceChanged, sourceOutsideFolder, ioFailure
    }
    let reason: Reason
    let detail: String
    let originalURL: URL
    let originalStatus: ScreenshotOriginalStatus
    /// An artifact may survive a failed publication. This is never a saved receipt and
    /// must not be used as a clipboard file until independently revalidated.
    let recoverableDestination: URL?

    var title: String { reason == .accessRequired ? "Choose where to save screenshots" : "Save couldn’t be confirmed" }

    var message: String {
        let explanation: String
        switch reason {
        case .accessRequired:
            explanation = "ShotDrop needs access to the folder you choose to save screenshot copies. Choose a destination when you’re ready."
        case .destinationOverlap:
            explanation = "Choose a destination separate from the screenshot source folder. Neither folder can contain the other."
        case .invalidDestination:
            explanation = "The destination folder is unavailable or invalid. Choose an accessible folder and retry."
        case .stagingPaused:
            explanation = "Saving is paused because its private staging storage is busy or needs attention. Retry after the current save finishes or staging storage has been checked."
        case .unsupportedFilesystem:
            explanation = "This destination doesn’t support the safe copy operation. Choose another destination."
        case .crossDeviceClone:
            explanation = "The safe copy operation couldn’t complete across these filesystem boundaries. Choose another destination."
        case .noSpace:
            explanation = "The destination has insufficient space. Free some space or choose another destination, then retry."
        case .permissionDenied:
            explanation = "Access to the screenshot or destination was denied. Check folder access or choose a destination, then retry."
        case .verificationFailed:
            explanation = "The destination copy couldn’t be verified. It has not been marked as saved."
        case .collision:
            explanation = "No unused filename was available. Change the naming template or destination, then retry."
        case .invalidName:
            explanation = "Correct the screenshot naming template in Settings, then retry."
        case .sourceUnavailable:
            explanation = "The source screenshot is unavailable. Restore access or locate the original before retrying."
        case .sourceChanged:
            explanation = "The source screenshot changed during this save attempt. Inspect the original before retrying."
        case .sourceOutsideFolder:
            explanation = "This screenshot is outside the selected source folder. Check the source folder before retrying."
        case .ioFailure:
            explanation = "The copy couldn’t be completed. Check the source and destination, then retry."
        }
        let original: String
        switch originalStatus {
        case .available: original = "The original is still available at the path below."
        case .changed: original = "The file at the original path changed; its earlier contents have not been verified."
        case .unavailable: original = "The original could not be verified at this path. It may have moved or become unreadable."
        case .notChecked: original = "Folder access has not been attempted."
        }
        return explanation + " " + original
    }

    var actions: [ScreenshotSaveRecoveryAction] {
        var result: [ScreenshotSaveRecoveryAction]
        switch reason {
        case .accessRequired: result = [.chooseDestination]
        case .unsupportedFilesystem, .crossDeviceClone, .destinationOverlap, .invalidDestination:
            result = [.chooseDestination, .retry]
        case .sourceUnavailable, .sourceChanged, .sourceOutsideFolder, .invalidName:
            result = [.retry]
        default:
            result = [.retry, .chooseDestination]
        }
        if originalStatus == .available { result.append(.revealOriginal) }
        return result
    }

    var requiresAccessExplanation: Bool { reason == .accessRequired || reason == .permissionDenied }
}

enum ScreenshotSaveOutcome: Sendable {
    case saved(ScreenshotOrganizationResult)
    case failed(ScreenshotSaveFailure)
    case cancelled(originalURL: URL)
}

/// No completion/dedup cache: an explicit retry always creates a fresh save attempt.
/// This service never changes the clipboard, screenshot defaults, or access permissions.
actor ScreenshotSaveService {
    private let organizer: ScreenshotOrganizer
    private let validator: any ScreenshotDestinationValidating

    init(
        organizer: ScreenshotOrganizer = ScreenshotOrganizer(),
        validator: any ScreenshotDestinationValidating = LocalScreenshotDestinationValidator()
    ) {
        self.organizer = organizer
        self.validator = validator
    }

    func save(
        _ request: ScreenshotSaveRequest,
        beforePublishing: @Sendable (UUID) async throws -> Void = { _ in }
    ) async -> ScreenshotSaveOutcome {
        let source = request.organization.sourceURL
        guard !Task.isCancelled else { return .cancelled(originalURL: source) }
        guard request.destinationAccess == .userApproved else {
            return .failed(ScreenshotSaveFailure(reason: .accessRequired, detail: "Destination access has not been explained and approved.",
                                                originalURL: source, originalStatus: .notChecked, recoverableDestination: nil))
        }
        let initial = RecoverySourceState.read(source)
        guard let initial else {
            return .failed(ScreenshotSaveFailure(reason: .sourceUnavailable, detail: "The original is not an accessible regular file.",
                                                originalURL: source, originalStatus: .unavailable, recoverableDestination: nil))
        }
        if let expected = request.organization.expectedIdentity, expected != initial.identity {
            return .failed(ScreenshotSaveFailure(reason: .sourceChanged, detail: "The source identity no longer matches the detected screenshot.",
                                                originalURL: source, originalStatus: .changed, recoverableDestination: nil))
        }
        do {
            try Self.validateSourceLocation(source, directory: request.sourceDirectoryURL)
            let validator = self.validator
            try validator.validate(sourceDirectory: request.sourceDirectoryURL, destinationDirectory: request.organization.destinationRoot)
            var organization = request.organization
            organization.expectedIdentity = initial.identity
            let result = try await organizer.organize(organization) { token in
                try await beforePublishing(token)
                // Revalidate after the caller's asynchronous hook as well; a settings-time
                // check alone is insufficient, and original availability must not be stale.
                try Self.validateSourceLocation(source, directory: request.sourceDirectoryURL)
                try validator.validate(sourceDirectory: request.sourceDirectoryURL, destinationDirectory: request.organization.destinationRoot)
                guard RecoverySourceState.read(source) == initial else {
                    throw ScreenshotCopyFailure(code: .sourceChanged, detail: "The original changed while the save was being prepared.")
                }
            }
            return .saved(result)
        } catch is CancellationError {
            return .cancelled(originalURL: source)
        } catch {
            let current = RecoverySourceState.read(source)
            let status: ScreenshotOriginalStatus = current == nil ? .unavailable : current == initial ? .available : .changed
            return .failed(ScreenshotSaveFailure(
                reason: Self.reason(for: error), detail: (error as? ScreenshotDestinationValidationFailure)?.detail ?? error.localizedDescription,
                originalURL: source, originalStatus: status,
                recoverableDestination: (error as? ScreenshotCopyFailure)?.recoverableDestination
            ))
        }
    }

    private static func validateSourceLocation(_ source: URL, directory: URL) throws {
        guard directory.isFileURL, !directory.path.contains("\0"),
              directory.host == nil || directory.host == "" || directory.host == "localhost" else {
            throw SourceLocationFailure()
        }
        let parentFD = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { throw sourceFolderFailure() }
        defer { close(parentFD) }
        let declaredFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard declaredFD >= 0 else { throw sourceFolderFailure() }
        defer { close(declaredFD) }
        var parent = stat()
        var declared = stat()
        guard fstat(parentFD, &parent) == 0, fstat(declaredFD, &declared) == 0 else {
            throw sourceFolderFailure()
        }
        guard parent.st_dev == declared.st_dev, parent.st_ino == declared.st_ino else {
            throw SourceLocationFailure()
        }
    }

    private static func sourceFolderFailure() -> ScreenshotCopyFailure {
        let code = errno
        return ScreenshotCopyFailure(code: code == EACCES || code == EPERM ? .permissionDenied : .sourceUnavailable,
                                     detail: "The selected source folder is unavailable or unreadable.", posixCode: code)
    }

    private struct SourceLocationFailure: Error, LocalizedError {
        var errorDescription: String? { "The screenshot does not belong to the selected source folder." }
    }

    private static func reason(for error: Error) -> ScreenshotSaveFailure.Reason {
        if error is SourceLocationFailure { return .sourceOutsideFolder }
        if (error as? ScreenshotCopyFailure)?.code == .stagingPaused { return .stagingPaused }
        let code = (error as? ScreenshotCopyFailure)?.posixCode
            ?? (error as? ScreenshotDestinationValidationFailure)?.posixCode
        if let code {
            switch code {
            case ENOTSUP: return .unsupportedFilesystem
            case EXDEV: return .crossDeviceClone
            case ENOSPC, EDQUOT: return .noSpace
            case EACCES, EPERM: return .permissionDenied
            default: break
            }
        }
        if let failure = error as? ScreenshotCopyFailure {
            switch failure.code {
            case .sourceUnavailable: return .sourceUnavailable
            case .sourceChanged: return .sourceChanged
            case .destinationUnavailable: return .invalidDestination
            case .permissionDenied: return .permissionDenied
            case .verificationFailed: return .verificationFailed
            case .collision: return .collision
            case .invalidName: return .invalidName
            case .ioFailure: return .ioFailure
            case .stagingPaused: return .stagingPaused
            }
        }
        if let failure = error as? ScreenshotDestinationValidationFailure {
            switch failure.code {
            case .overlap: return .destinationOverlap
            case .sourceUnavailable: return .sourceUnavailable
            case .invalidPath, .destinationUnavailable: return .invalidDestination
            }
        }
        if error is ScreenshotNamingError { return .invalidName }
        return .ioFailure
    }
}

/// Readable regular-file snapshots distinguish unavailable/replaced/in-place changed
/// originals before recovery actions are offered. File I/O stays on the save actor.
private struct RecoverySourceState: Equatable, Sendable {
    let identity: ScreenshotFileIdentity
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let mode: mode_t

    init(_ info: stat) {
        identity = ScreenshotFileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                                          birthNanoseconds: Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec))
        size = info.st_size
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        mode = info.st_mode
    }

    static func read(_ url: URL) -> Self? {
        guard url.isFileURL, !url.path.contains("\0"),
              url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var opened = stat()
        var path = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              lstat(url.path, &path) == 0, Self(opened) == Self(path) else { return nil }
        return Self(opened)
    }
}
