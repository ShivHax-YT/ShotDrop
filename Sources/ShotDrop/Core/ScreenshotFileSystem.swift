import Darwin
import Foundation
import ImageIO

struct ScreenshotFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let birthNanoseconds: Int64
}

struct ScreenshotFileSnapshot: Equatable, Sendable {
    let identity: ScreenshotFileIdentity
    let size: Int64
    let modifiedNanoseconds: Int64
    let isScreenshot: Bool
    let isCompleteImage: Bool
}

protocol ScreenshotFileSystemReading: Sendable {
    func contents(of directory: URL) throws -> [URL]
    func identity(at url: URL) throws -> ScreenshotFileIdentity?
    func snapshot(at url: URL) throws -> ScreenshotFileSnapshot?
}

extension ScreenshotFileSystemReading {
    func identity(at url: URL) throws -> ScreenshotFileIdentity? {
        try snapshot(at: url)?.identity
    }
}

enum ScreenshotFileFilter {
    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath,
              !url.lastPathComponent.hasPrefix(".") else { return false }
        return ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased())
    }
}

struct LocalScreenshotFileSystem: ScreenshotFileSystemReading {
    func identity(at url: URL) throws -> ScreenshotFileIdentity? {
        guard ScreenshotFileFilter.accepts(url), let state = try fileState(at: url),
              state.isRegular else { return nil }
        return state.identity
    }

    func contents(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter(ScreenshotFileFilter.accepts)
    }

    func snapshot(at url: URL) throws -> ScreenshotFileSnapshot? {
        guard ScreenshotFileFilter.accepts(url), let initial = try fileState(at: url),
              initial.isRegular else { return nil }

        // Pin reads to one inode; O_NOFOLLOW also rejects a symlink substituted after lstat.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else {
            if Self.isTransient(errno) || errno == ELOOP { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let opened = FileState(openedStat)
        guard opened.isRegular, initial == opened else { return nil }

        let isScreenshot = Self.hasScreenshotMetadata(descriptor: descriptor)
        // Most directory changes are unrelated files. Only ask ImageIO to read confirmed candidates.
        let isCompleteImage = isScreenshot && Self.isCompleteImage(descriptor: descriptor)

        var finalStat = stat()
        guard fstat(descriptor, &finalStat) == 0 else { return nil }
        guard opened == FileState(finalStat), let finalPath = try fileState(at: url),
              opened == finalPath else { return nil }

        return ScreenshotFileSnapshot(
            identity: opened.identity, size: opened.size,
            modifiedNanoseconds: opened.modifiedNanoseconds,
            isScreenshot: isScreenshot, isCompleteImage: isCompleteImage
        )
    }

    private func fileState(at url: URL) throws -> FileState? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        guard result == 0 else {
            if Self.isTransient(errno) { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileState(info)
    }

    private static func isTransient(_ error: Int32) -> Bool {
        error == ENOENT || error == ENOTDIR
    }

    private static func hasScreenshotMetadata(descriptor: Int32) -> Bool {
        // A boolean plist is tiny. A fixed cap rejects malformed or unexpectedly large metadata.
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = bytes.withUnsafeMutableBytes { buffer in
            fgetxattr(descriptor, "com.apple.metadata:kMDItemIsScreenCapture",
                      buffer.baseAddress, buffer.count, 0, 0)
        }
        guard count > 0 else { return false }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let value = try? PropertyListSerialization.propertyList(
            from: Data(bytes.prefix(count)), options: [], format: &format
        ), format == .binary, let number = value as? NSNumber else { return false }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        let integerEncodings: Set<String> = ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]
        return integerEncodings.contains(String(cString: number.objCType)) && number == 1
    }

    private static func isCompleteImage(descriptor: Int32) -> Bool {
        // /dev/fd keeps ImageIO on the already-open file, even if the original path is replaced.
        let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(descriptorURL as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return false }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) != nil else { return false }
        return CGImageSourceGetStatus(source) == .statusComplete
            && CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }

    private struct FileState: Equatable {
        let identity: ScreenshotFileIdentity
        let size: Int64
        let modifiedNanoseconds: Int64
        let changedNanoseconds: Int64
        let isRegular: Bool

        init(_ info: stat) {
            identity = ScreenshotFileIdentity(
                device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                birthNanoseconds: Self.nanoseconds(info.st_birthtimespec)
            )
            size = info.st_size
            modifiedNanoseconds = Self.nanoseconds(info.st_mtimespec)
            changedNanoseconds = Self.nanoseconds(info.st_ctimespec)
            isRegular = (info.st_mode & S_IFMT) == S_IFREG
        }

        private static func nanoseconds(_ time: timespec) -> Int64 {
            Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
        }
    }
}

enum ScreenshotDirectoryResolver {
    static func resolve(location: String?, homeDirectory: URL) -> URL {
        let fallback = homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty, !location.contains("\0") else { return fallback }
        if location == "~" { return homeDirectory.standardizedFileURL }
        if location.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(location.dropFirst(2)), isDirectory: true)
                .standardizedFileURL
        }
        guard location.hasPrefix("/") else { return fallback }
        return URL(fileURLWithPath: location, isDirectory: true).standardizedFileURL
    }

    /// Synchronous process I/O: invoke from the detector actor, never the main actor.
    static func systemLocation() throws -> URL {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.screencapture", "location"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain before waiting so a full stdout pipe cannot stall the child process.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let location = process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
        return resolve(location: location, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }
}
