import Foundation

/// Spotlight is a secondary source of candidates, never a source of startup replay.
@MainActor
final class ScreenshotMetadataReconciler: NSObject {
    private var query: NSMetadataQuery?
    private var onCandidates: (@Sendable ([URL]) -> Void)?
    private var finishedInitialGathering = false

    @discardableResult
    func start(in directory: URL, onCandidates: @escaping @Sendable ([URL]) -> Void) -> Bool {
        stop()
        guard directory.isFileURL else { return false }
        let query = NSMetadataQuery()
        query.searchScopes = [directory]
        query.predicate = NSPredicate(format: "%K == 1", "kMDItemIsScreenCapture")
        // Query lifecycle and notifications remain on the main operation queue.
        // Only copied URLs are exposed to a consumer; NSMetadataItem never crosses actors.
        query.operationQueue = .main
        query.notificationBatchingInterval = 0.1
        self.query = query
        self.onCandidates = onCandidates
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(didFinishGathering(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: query
        )
        center.addObserver(
            self, selector: #selector(didUpdate(_:)),
            name: .NSMetadataQueryDidUpdate, object: query
        )
        guard query.start() else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if let query {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
            query.stop()
        }
        query = nil
        onCandidates = nil
        finishedInitialGathering = false
    }

    @objc private func didFinishGathering(_ notification: Notification) {
        guard let query, notification.object as? NSMetadataQuery === query else { return }
        // Deliberately do not enumerate or publish the initial results.
        finishedInitialGathering = true
    }

    @objc private func didUpdate(_ notification: Notification) {
        guard let query, notification.object as? NSMetadataQuery === query,
              finishedInitialGathering, !query.isGathering else { return }
        query.disableUpdates()
        let candidates: [URL]
        do {
            defer { query.enableUpdates() }
            let added = notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let changed = notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? []
            candidates = (added + changed).compactMap { item in
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                return URL(fileURLWithPath: path)
            }
        }
        if !candidates.isEmpty { onCandidates?(candidates) }
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        query?.stop()
    }
}
