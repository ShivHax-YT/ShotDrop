import Foundation
import Observation

enum CopyMode: String, CaseIterable, Identifiable, Sendable {
    case image
    case file
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "Image"
        case .file: "File"
        case .both: "Image and file"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let destinationPath = "destinationPath"
        static let renameTemplate = "renameTemplate"
        static let copyMode = "copyMode"
        static let organizeByDate = "organizeByDate"
        static let playSound = "playSound"
        static let hasPresentedSetup = "hasPresentedSetup"
        static let hasCompletedSetup = "hasCompletedSetup"
        static let hasDeferredSetup = "hasDeferredSetup"
        static let showShotDropThumbnail = "showShotDropThumbnail"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var sourcePath: String {
        didSet { defaults.set(sourcePath, forKey: "sourcePath") }
    }
    var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: "isPaused") }
    }

    var destinationPath: String {
        didSet { defaults.set(destinationPath, forKey: Key.destinationPath) }
    }

    var renameTemplate: String {
        didSet { defaults.set(renameTemplate, forKey: Key.renameTemplate) }
    }

    var copyMode: CopyMode {
        didSet { defaults.set(copyMode.rawValue, forKey: Key.copyMode) }
    }

    var organizeByDate: Bool {
        didSet { defaults.set(organizeByDate, forKey: Key.organizeByDate) }
    }

    var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Key.playSound) }
    }

    /// Presentation history only; never evidence of access, enrollment, or readiness.
    var hasPresentedSetup: Bool {
        didSet { defaults.set(hasPresentedSetup, forKey: Key.hasPresentedSetup) }
    }

    /// Completing the gated setup flow is distinct from showing or deferring it.
    /// This preference is presentation history, never authority to start processing.
    private(set) var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: Key.hasCompletedSetup) }
    }

    /// Explicit Not Now/title-bar deferral suppresses automatic presentation, not readiness checks.
    private(set) var hasDeferredSetup: Bool {
        didSet { defaults.set(hasDeferredSetup, forKey: Key.hasDeferredSetup) }
    }

    var shouldPresentSetupOnLaunch: Bool { !hasCompletedSetup && !hasDeferredSetup }

    func recordSetupDeferral() { hasDeferredSetup = true }

    /// An explicit Finish Setup/reopen action resumes presentation without claiming completion.
    func resumeSetupPresentation() { hasDeferredSetup = false }

    /// Called only when the setup model reports its explicit completed state.
    func recordSetupCompletion(ifTerminalSuccess completed: Bool) {
        guard completed else { return }
        hasCompletedSetup = true
        hasDeferredSetup = false
    }

    var showShotDropThumbnail: Bool {
        didSet { defaults.set(showShotDropThumbnail, forKey: Key.showShotDropThumbnail) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourcePath = defaults.string(forKey: "sourcePath") ?? ""
        isPaused = defaults.bool(forKey: "isPaused")
        destinationPath = defaults.string(forKey: Key.destinationPath)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/ShotDrop", isDirectory: true).path
        renameTemplate = defaults.string(forKey: Key.renameTemplate) ?? "{app}-{date}-{time}"
        copyMode = defaults.string(forKey: Key.copyMode).flatMap(CopyMode.init(rawValue:)) ?? .both
        organizeByDate = defaults.bool(forKey: Key.organizeByDate)
        playSound = defaults.bool(forKey: Key.playSound)
        hasPresentedSetup = defaults.bool(forKey: Key.hasPresentedSetup)
        // An older installation having displayed setup never implies completion.
        hasCompletedSetup = defaults.bool(forKey: Key.hasCompletedSetup)
        hasDeferredSetup = defaults.bool(forKey: Key.hasDeferredSetup)
        showShotDropThumbnail = defaults.object(forKey: Key.showShotDropThumbnail) as? Bool ?? true
    }
}
