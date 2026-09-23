import Foundation
import OSLog

struct ScreenshotOrganizationRequest: Sendable {
    let sourceURL: URL
    let destinationRoot: URL
    let template: String
    let namingContext: ScreenshotNamingContext
    var organizeByDate = false
    var expectedIdentity: ScreenshotFileIdentity? = nil
}

struct ScreenshotOrganizationResult: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let destinationIdentity: ScreenshotFileIdentity
    let outputToken: UUID
    /// Cleanup of originals is a separate, future opt-in feature.
    let sourceWasRemoved = false
}

/// Source-preserving organization. All blocking file operations stay off MainActor.
actor ScreenshotOrganizer {
    private let fileSystem: any ScreenshotOrganizationFileSystem
    private let collisionLimit: Int
    private let logger = Logger(subsystem: "com.macfleet.shotdrop", category: "Organization")

    init(
        fileSystem: any ScreenshotOrganizationFileSystem = LocalScreenshotOrganizationFileSystem(),
        collisionLimit: Int = 1_000
    ) {
        self.fileSystem = fileSystem
        self.collisionLimit = max(1, collisionLimit)
    }

    func organize(
        _ request: ScreenshotOrganizationRequest,
        beforePublishing: @Sendable (UUID) async throws -> Void = { _ in }
    ) async throws -> ScreenshotOrganizationResult {
        try Task.checkCancellation()
        let plan = try ScreenshotNaming.plan(
            template: request.template,
            sourceExtension: request.sourceURL.pathExtension,
            context: request.namingContext,
            organizeByDate: request.organizeByDate
        )
        let staged = try fileSystem.stageCopy(
            source: request.sourceURL,
            destinationRoot: request.destinationRoot,
            subdirectories: plan.directoryComponents,
            expectedIdentity: request.expectedIdentity
        )
        defer { staged.discard() }

        // Cloning creates a new inode. Register the marker that travels with the copy
        // before any visible filename can trigger detection in the source folder.
        try await beforePublishing(staged.outputToken)
        try Task.checkCancellation()

        for index in 0..<collisionLimit {
            do {
                try Task.checkCancellation()
                let copy = try staged.publish(named: plan.filename(collisionIndex: index))
                logger.info("Verified screenshot destination published; original retained; collision suffix index=\(index).")
                return ScreenshotOrganizationResult(
                    sourceURL: request.sourceURL,
                    destinationURL: copy.destinationURL,
                    destinationIdentity: copy.identity,
                    outputToken: copy.outputToken
                )
            } catch let error as ScreenshotCopyFailure where error.code == .collision {
                continue
            } catch {
                logger.error("Screenshot organization failed; no source removal was attempted.")
                throw error
            }
        }
        throw ScreenshotCopyFailure(
            code: .collision,
            detail: "No unused screenshot filename was found after \(collisionLimit) attempts. The original has not been removed."
        )
    }
}
