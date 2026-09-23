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
    }

    @ObservationIgnored private let defaults: UserDefaults

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        destinationPath = defaults.string(forKey: Key.destinationPath)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/ShotDrop", isDirectory: true).path
        renameTemplate = defaults.string(forKey: Key.renameTemplate) ?? "{app}-{date}-{time}"
        copyMode = defaults.string(forKey: Key.copyMode).flatMap(CopyMode.init(rawValue:)) ?? .both
        organizeByDate = defaults.bool(forKey: Key.organizeByDate)
        playSound = defaults.bool(forKey: Key.playSound)
    }
}
