import Darwin
import Foundation

protocol ScreenshotDestinationValidating: Sendable {
    func validate(sourceDirectory: URL, destinationDirectory: URL) throws
}

struct ScreenshotDestinationValidationFailure: Error, Sendable {
    enum Code: Sendable {
        case overlap, invalidPath, sourceUnavailable, destinationUnavailable
    }

    let code: Code
    let detail: String
    var posixCode: Int32? = nil
}

/// Read-only directory separation check. Invoke away from MainActor and repeat for each save.
struct LocalScreenshotDestinationValidator: ScreenshotDestinationValidating {
    func validate(sourceDirectory: URL, destinationDirectory: URL) throws {
        try validatePath(sourceDirectory)
        try validatePath(destinationDirectory)
        let sourceFD = try openDirectory(sourceDirectory.path, failure: .sourceUnavailable)
        defer { close(sourceFD) }
        let sourceIdentity = try identity(sourceFD, failure: .sourceUnavailable)
        let anchor = try existingDestinationAnchor(destinationDirectory)
        defer { close(anchor.descriptor) }
        let destinationIdentity = try identity(anchor.descriptor, failure: .destinationUnavailable)

        // A missing destination is still inside its nearest existing ancestor. It cannot
        // already be an ancestor of the existing source, so only the first check applies.
        if try hasAncestor(sourceIdentity, startingAt: anchor.descriptor, failure: .destinationUnavailable)
            || (anchor.isComplete && hasAncestor(destinationIdentity, startingAt: sourceFD,
                                                 failure: .sourceUnavailable)) {
            throw ScreenshotDestinationValidationFailure(
                code: .overlap,
                detail: "Choose a destination outside the screenshot source folder and its parent folders."
            )
        }

        // Detect replacement or movement during validation without creating a destination.
        try confirmPath(sourceDirectory.path, identity: sourceIdentity, failure: .sourceUnavailable)
        try confirmPath(anchor.path, identity: destinationIdentity, failure: .destinationUnavailable)
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Anchor {
        let descriptor: Int32
        let path: String
        let isComplete: Bool
    }

    private func validatePath(_ url: URL) throws {
        let path = url.path
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ScreenshotDestinationValidationFailure(
                code: .invalidPath, detail: "Screenshot folders must be absolute local paths without dot components."
            )
        }
    }

    private func existingDestinationAnchor(_ destination: URL) throws -> Anchor {
        var path = destination.path
        var isComplete = true
        while true {
            var info = stat()
            if lstat(path, &info) == 0 {
                // Follow an existing symlink only through open; dangling links and links to
                // files fail here instead of being mistaken for missing destination folders.
                let descriptor = try openDirectory(path, failure: .destinationUnavailable)
                return Anchor(descriptor: descriptor, path: path, isComplete: isComplete)
            }
            let code = errno
            guard code == ENOENT, path != "/" else {
                throw failure(.destinationUnavailable, "Inspect destination folder", code: code)
            }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else {
                throw failure(.destinationUnavailable, "Find destination parent", code: code)
            }
            path = parent
            isComplete = false
        }
    }

    private func openDirectory(_ path: String, failure code: ScreenshotDestinationValidationFailure.Code) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(code, "Open screenshot folder", code: errno) }
        return descriptor
    }

    private func identity(_ descriptor: Int32, failure code: ScreenshotDestinationValidationFailure.Code) throws -> DirectoryIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure(code, "Inspect screenshot folder", code: errno) }
        return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private func hasAncestor(
        _ expected: DirectoryIdentity, startingAt descriptor: Int32,
        failure code: ScreenshotDestinationValidationFailure.Code
    ) throws -> Bool {
        var current = dup(descriptor)
        guard current >= 0 else { throw failure(code, "Inspect folder ancestry", code: errno) }
        defer { close(current) }
        for _ in 0..<1_024 {
            let currentIdentity = try identity(current, failure: code)
            if currentIdentity == expected { return true }
            let parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { throw failure(code, "Open folder ancestor", code: errno) }
            let parentIdentity: DirectoryIdentity
            do { parentIdentity = try identity(parent, failure: code) }
            catch { close(parent); throw error }
            if parentIdentity == currentIdentity {
                close(parent)
                return false
            }
            close(current)
            current = parent
        }
        throw ScreenshotDestinationValidationFailure(
            code: code, detail: "Folder ancestry could not be validated within the safety limit."
        )
    }

    private func confirmPath(
        _ path: String, identity expected: DirectoryIdentity,
        failure code: ScreenshotDestinationValidationFailure.Code
    ) throws {
        let descriptor = try openDirectory(path, failure: code)
        defer { close(descriptor) }
        guard try identity(descriptor, failure: code) == expected else {
            throw ScreenshotDestinationValidationFailure(code: code, detail: "A screenshot folder changed during validation.")
        }
    }

    private func failure(
        _ code: ScreenshotDestinationValidationFailure.Code, _ operation: String, code posix: Int32
    ) -> ScreenshotDestinationValidationFailure {
        ScreenshotDestinationValidationFailure(
            code: code, detail: "\(operation): \(String(cString: strerror(posix))).", posixCode: posix
        )
    }
}
