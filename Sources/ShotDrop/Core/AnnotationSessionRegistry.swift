import Foundation

/// A session never follows a newer capture revision or substitutes another source.
struct AnnotationSessionIdentity: Equatable, Sendable {
    let captureID: UUID
    let revision: UInt64
    let reference: RecentFileReference
}


/// Reserves a complete source allowance before loading. Closing sessions retain their
/// reservation until their asynchronous work drains; opening never evicts edits.
/// Three 32 MP RGBA sources bound source storage to 384 MB, not total process memory.
struct AnnotationSessionRegistry: Sendable {
    static let maximumSessions = 3
    static let maximumSourcePixelsPerSession = 32_000_000

    enum Admission: Equatable, Sendable {
        case opened(UUID)
        case existing(UUID)
        case closing(UUID)
        case full
    }

    private struct Entry: Sendable {
        let token: UUID
        let identity: AnnotationSessionIdentity
        var closing = false
    }

    private var entries: [Entry] = []
    var count: Int { entries.count }

    mutating func admit(_ identity: AnnotationSessionIdentity) -> Admission {
        if let entry = entries.first(where: { $0.identity == identity }) {
            return entry.closing ? .closing(entry.token) : .existing(entry.token)
        }
        guard entries.count < Self.maximumSessions else { return .full }
        let token = UUID()
        entries.append(Entry(token: token, identity: identity))
        return .opened(token)
    }

    func isClosing(token: UUID) -> Bool {
        entries.first(where: { $0.token == token })?.closing == true
    }

    @discardableResult
    mutating func beginClosing(token: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.token == token }) else { return false }
        entries[index].closing = true
        return true
    }

    /// Only the exact reservation can be released after its owner has drained work.
    @discardableResult
    mutating func releaseAfterDrain(token: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.token == token }), entries[index].closing else { return false }
        entries.remove(at: index)
        return true
    }
}
