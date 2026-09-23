import Darwin
import Foundation

enum DefaultDestinationPreparationResult: Sendable, Equatable {
    case enrolledPaused, reviewRequired, reservedRecovery, unreservedRecovery, missingPictures, unsupported, retryable
    case cloudStatusUnknown, providerStatusUnknown

    var message: String {
        switch self {
        case .enrolledPaused:
            "The default folder is prepared. Saving remains paused until existing staging storage has been accounted for and automatic processing is complete. Your originals stay in place."
        case .reviewRequired:
            "The default folder or an earlier setup attempt needs review. ShotDrop kept it intact. Automatic retry cannot approve or replace it."
        case .reservedRecovery:
            "Setup stopped after reserving staging storage. That reservation and your default folder were kept for review. Saving is paused; retry cannot create replacement storage."
        case .unreservedRecovery:
            "The default folder was created, but staging storage was not reserved. The folder was kept for review and saving is paused."
        case .missingPictures:
            "Your Pictures folder is missing. Restore that folder before retrying; ShotDrop can only prepare its own child folder."
        case .unsupported:
            "The default folder cannot be safely prepared on this setup. Saving is paused and your original screenshots stay in place."
        case .retryable:
            "The default folder could not be checked. Restore access or availability, then retry the check. Saving remains paused."
        case .cloudStatusUnknown:
            "ShotDrop could not confirm whether this folder is stored in iCloud. Keep the folder in place and retry when it is accessible. Saving remains paused."
        case .providerStatusUnknown:
            "ShotDrop could not confirm whether another storage provider manages this folder. Keep the folder in place and retry when it is accessible. Saving remains paused."
        }
    }

    var permitsRetry: Bool { self == .retryable || self == .missingPictures || self == .cloudStatusUnknown || self == .providerStatusUnknown }

    var detailsActionTitle: String { self == .unsupported ? "View Requirements…" : "View Setup Details…" }

    var detailsTitle: String {
        switch self {
        case .enrolledPaused: "Default folder prepared"
        case .reviewRequired: "Review needed before saving"
        case .reservedRecovery: "Storage reservation needs review"
        case .unreservedRecovery: "Created folder needs review"
        case .unsupported: "Default location unavailable"
        case .missingPictures, .retryable, .cloudStatusUnknown, .providerStatusUnknown: "Check paused"
        }
    }

    var reviewGuidance: String {
        switch self {
        case .enrolledPaused:
            "Earlier screenshot storage may exist in other locations. ShotDrop’s developer must provide a reviewed storage-accounting and processing update before saving can start. Keep this folder and its setup records intact."
        case .reviewRequired:
            "An existing folder or interrupted setup cannot be approved automatically. Ask ShotDrop’s developer to review this setup state before trying to prepare it again. Do not rename, replace, or delete the folder or its setup records."
        case .reservedRecovery:
            "Staging storage has already been reserved. Ask ShotDrop’s developer to review the preserved reservation and setup records. Creating another folder or removing those records cannot safely resume this setup."
        case .unreservedRecovery:
            "The folder was created, but staging storage was not reserved. Ask ShotDrop’s developer to review the preserved folder and setup records before another preparation attempt. Keep them intact."
        case .unsupported:
            "The default must be the exact Pictures/ShotDrop folder in the standard local /Users account home, on a writable internal APFS volume. Folder ownership, permissions, identity, and cloud checks must pass. ShotDrop cannot identify which requirement failed from this result. Ask ShotDrop’s developer to review compatibility with this Mac. No alternate location is approved by this setup path."
        case .missingPictures:
            "Restore your Pictures folder, then return to setup and retry the check."
        case .retryable:
            "Restore folder access or availability, then return to setup and retry the check."
        case .cloudStatusUnknown, .providerStatusUnknown:
            "Retry the check when the folder is accessible. If the same message persists, close setup and ask ShotDrop’s developer to review the location check. Do not move or delete folders to clear this message."
        }
    }
}

protocol DefaultDestinationSetupPreparing: Sendable {
    var proposedDestination: URL { get }
    func prepare(source: ShotDropSetupDirectoryIdentity) async -> DefaultDestinationPreparationResult
    func reviewState() async -> DefaultDestinationPreparationResult?
}

extension DefaultDestinationSetupPreparing {
    func reviewState() async -> DefaultDestinationPreparationResult? { nil }
}

struct LocalDefaultDestinationSetupPreparation: DefaultDestinationSetupPreparing {
    var proposedDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/ShotDrop")
    }

    @concurrent
    func reviewState() async -> DefaultDestinationPreparationResult? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.macfleet.shotdrop/DefaultDestination")
        do {
            switch try DefaultDestinationJournal(directory: directory).loadReadOnly() {
            case .empty: return nil
            case .enrolled: return .enrolledPaused
            case .intent, .created: return .reviewRequired
            }
        } catch { return .reviewRequired }
    }

    @concurrent
    func prepare(source: ShotDropSetupDirectoryIdentity) async -> DefaultDestinationPreparationResult {
        let sourceURL = URL(fileURLWithPath: source.path, isDirectory: true)
        guard case .accessible = await LocalShotDropSetupAccessService().checkSource(sourceURL, expecting: source),
              !Task.isCancelled else { return .retryable }
        do {
            let inspector = DefaultDestinationPolicyPathInspector()
            // Check eligibility and separation before creating any private setup metadata.
            try inspector.withInspectedParent { _, parent in
                try LocalScreenshotDestinationValidator().validate(sourceDirectory: sourceURL,
                                                                   destinationDirectory: parent.childPath)
            }
            try Task.checkCancellation()
            let home = FileManager.default.homeDirectoryForCurrentUser
            let supportParent = home.appendingPathComponent("Library/Application Support")
            let support = supportParent.appendingPathComponent("com.macfleet.shotdrop")
            try LocalScreenshotDestinationValidator().validate(sourceDirectory: sourceURL,
                                                               destinationDirectory: support)
            let parentFD = open(supportParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard parentFD >= 0 else { return .retryable }
            defer { close(parentFD) }
            var parentInfo = stat()
            guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_uid == geteuid(),
                  parentInfo.st_mode & 0o022 == 0 else { return .unsupported }
            let supportFD = try privateDirectory("com.macfleet.shotdrop", parent: parentFD)
            defer { close(supportFD) }
            let journalFD = try privateDirectory("DefaultDestination", parent: supportFD)
            defer { close(journalFD) }
            let registry = support.appendingPathComponent("StagingRegistry")
            let pool = ScreenshotStagingPool(registryDirectory: registry)
            var info = stat()
            if fstatat(supportFD, "StagingRegistry", &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { return .retryable }
                // Main #672: a new registry is not evidence of absent legacy artifacts.
                try pool.initialize(legacyArtifactsAccountedFor: false)
            }
            let journal = DefaultDestinationJournal(directory: support.appendingPathComponent("DefaultDestination"))
            let issuer = DefaultDestinationIssuer(inspector: inspector, journal: journal, pool: pool)
            let root = support.appendingPathComponent("DefaultStaging")
            try Task.checkCancellation()
            switch try journal.load() {
            case .empty:
                _ = try issuer.createAndEnroll(sourceDirectory: sourceURL, stagingRoot: root)
            case .enrolled:
                _ = try issuer.resumeEnrolled(sourceDirectory: sourceURL, stagingRoot: root)
            case .intent, .created:
                return .reviewRequired
            }
            return .enrolledPaused
        } catch let issue as DefaultDestinationPolicyIssue {
            switch issue {
            case .missingPictures: return .missingPictures
            case .cloudStatusUnknown: return .cloudStatusUnknown
            case .providerStatusUnknown: return .providerStatusUnknown
            case .changed: return .reviewRequired
            default: return .unsupported
            }
        } catch let issue as DefaultDestinationIssuerIssue {
            switch issue {
            case .enrollmentCharged: return .reservedRecovery
            case .enrollmentUncharged: return .unreservedRecovery
            default: return .reviewRequired
            }
        } catch is DefaultDestinationJournal.Fault {
            return .reviewRequired
        } catch { return .retryable }
    }

    private func privateDirectory(_ name: String, parent: Int32) throws -> Int32 {
        try Task.checkCancellation()
        guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else {
            throw DefaultDestinationJournal.Fault.unavailable
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { throw DefaultDestinationJournal.Fault.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              fsync(descriptor) == 0, fsync(parent) == 0 else {
            close(descriptor)
            throw DefaultDestinationJournal.Fault.unavailable
        }
        return descriptor
    }
}
