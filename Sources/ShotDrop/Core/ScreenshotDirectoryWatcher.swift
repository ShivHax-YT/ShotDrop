import CoreServices
import Foundation

enum ScreenshotWatchEvent: Sendable, Equatable {
    case paths([URL])
    case rescanRequired
    case rootChanged
}

protocol ScreenshotWatching: Sendable {
    func start(
        in directory: URL,
        onEvent: @escaping @Sendable (ScreenshotWatchEvent) -> Void
    ) async throws
    func stop() async
}

/// Owns one event stream. Events are hints; the consumer validates and deduplicates files.
actor ScreenshotDirectoryWatcher: ScreenshotWatching {
    enum WatchError: Error, LocalizedError {
        case invalidDirectoryURL
        case creationFailed
        case startFailed

        var errorDescription: String? {
            switch self {
            case .invalidDirectoryURL: "The screenshot watch location must be a file URL."
            case .creationFailed: "macOS could not create the screenshot folder event stream."
            case .startFailed: "macOS could not start watching the screenshot folder."
            }
        }
    }

    private var resource: ScreenshotEventStream?

    func start(
        in directory: URL,
        onEvent: @escaping @Sendable (ScreenshotWatchEvent) -> Void
    ) async throws {
        resource = nil
        guard directory.isFileURL else { throw WatchError.invalidDirectoryURL }
        try Task.checkCancellation()
        resource = try ScreenshotEventStream(directory: directory, onEvent: onEvent)
    }

    func stop() async {
        // Releasing this sole reference synchronously stops, invalidates, and releases.
        resource = nil
    }

    /// Separate from C pointer decoding so exceptional-event handling is testable.
    nonisolated static func events(paths: [URL], flags: [FSEventStreamEventFlags]) -> [ScreenshotWatchEvent] {
        let rootMask = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        let scanMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
        )
        var rootChanged = false
        var rescanRequired = false
        var hints: [URL] = []
        for (path, flag) in zip(paths, flags) {
            rootChanged = rootChanged || flag & rootMask != 0
            rescanRequired = rescanRequired || flag & scanMask != 0
            if flag & (rootMask | scanMask | FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)) == 0 {
                hints.append(path)
            }
        }
        var result: [ScreenshotWatchEvent] = []
        if rootChanged { result.append(.rootChanged) }
        if rescanRequired { result.append(.rescanRequired) }
        if !hints.isEmpty { result.append(.paths(hints)) }
        return result
    }
}

/// Shared with the C callback, but contains only an immutable Sendable closure.
private final class ScreenshotEventContext: Sendable {
    let onEvent: @Sendable (ScreenshotWatchEvent) -> Void

    init(onEvent: @escaping @Sendable (ScreenshotWatchEvent) -> Void) {
        self.onEvent = onEvent
    }
}

/// This non-Sendable resource never escapes its owning actor. Its deinitializer
/// also protects cleanup if the actor itself is released without an explicit stop.
private final class ScreenshotEventStream {
    private let stream: FSEventStreamRef
    private let queue: DispatchQueue

    init(directory: URL, onEvent: @escaping @Sendable (ScreenshotWatchEvent) -> Void) throws {
        let callbackContext = ScreenshotEventContext(onEvent: onEvent)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<ScreenshotEventContext>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<ScreenshotEventContext>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        // Keep the local strong reference until FSEvents has invoked its retain hook.
        let createdStream = withExtendedLifetime(callbackContext) {
            FSEventStreamCreate(
                nil,
                { _, info, count, eventPaths, eventFlags, _ in
                    guard let info else { return }
                    let callback = Unmanaged<ScreenshotEventContext>.fromOpaque(info).takeUnretainedValue()
                    // No UseCFTypes flag: FSEvents supplies an array of C path strings.
                    let strings = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                    let paths = (0..<count).map { URL(fileURLWithPath: String(cString: strings[$0])) }
                    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
                    for event in ScreenshotDirectoryWatcher.events(paths: paths, flags: flags) {
                        callback.onEvent(event)
                    }
                },
                &context,
                [directory.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
                createFlags
            )
        }
        guard let createdStream else { throw ScreenshotDirectoryWatcher.WatchError.creationFailed }
        let callbackQueue = DispatchQueue(label: "com.macfleet.shotdrop.screenshot-events", qos: .utility)
        FSEventStreamSetDispatchQueue(createdStream, callbackQueue)
        guard FSEventStreamStart(createdStream) else {
            // Stop is valid only for a successfully started stream.
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            throw ScreenshotDirectoryWatcher.WatchError.startFailed
        }
        stream = createdStream
        queue = callbackQueue
    }

    deinit {
        // Apple's lifecycle guarantees no further callbacks after Stop. Invalidate
        // unschedules the queue; Release balances Create and releases the context.
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
