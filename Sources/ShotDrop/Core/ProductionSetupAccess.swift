import Darwin
import Foundation

/// Setup checks run only after the user advances past the access explanation.
struct ProductionSetupAccess: ShotDropSetupAccessServing {
    var createDefaultIfMissing = false
    private let service = LocalShotDropSetupAccessService()
    func discoverSource() async -> ShotDropSetupSourceResolution {
        let discovered = await service.discoverSource()
        if case .known = discovered { return discovered }
        return .known(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
    }
    func checkSource(_ url: URL, expecting: ShotDropSetupDirectoryIdentity?) async -> ShotDropSetupSourceAccessResult {
        await service.checkSource(url, expecting: expecting)
    }
    @concurrent
    func checkDestination(_ url: URL, source: URL?, sourceIdentity: ShotDropSetupDirectoryIdentity?) async -> ShotDropSetupDestinationAccessResult {
        do {
            let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/ShotDrop")
            if createDefaultIfMissing, url.standardizedFileURL == defaultURL.standardizedFileURL,
               !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            let result = await service.checkDestination(url, source: source, sourceIdentity: sourceIdentity)
            guard case .needsReview = result else { return result }
            let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { return .unavailable(.denied) }
            defer { close(fd) }
            let name = ".shotdrop-access-\(UUID().uuidString)"
            let probe = openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard probe >= 0 else { return .unavailable(.denied) }
            defer { close(probe); _ = unlinkat(fd, name, 0) }
            let data = Data("ShotDrop folder check".utf8)
            let written = data.withUnsafeBytes { write(probe, $0.baseAddress, $0.count) }
            guard written == data.count, fsync(probe) == 0 else { return .unavailable(.unavailable) }
            return result
        } catch { return .unavailable(.unavailable) }
    }
}

struct ProductionSetupGate: ShotDropSetupReadinessGating {
    var permitsRetry: Bool { true }
    let start: @MainActor @Sendable (ShotDropSetupReadinessBinding) async -> Bool
    func evaluate(_ binding: ShotDropSetupReadinessBinding) async -> ShotDropSetupReadiness {
        let ready = await start(binding)
        return .init(binding: binding, destinationReady: ready, pipelineReady: ready, boundReviewApproved: ready)
    }
}
