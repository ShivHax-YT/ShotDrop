import Foundation

/// The immutable capture metadata used to produce a screenshot name.
struct ScreenshotNamingContext: Sendable {
    let appName: String?
    let capturedAt: Date
    let timeZone: TimeZone
}

/// A safe relative destination name, with collision suffixes reserved in its byte budget.
struct ScreenshotNamePlan: Sendable {
    let directoryComponents: [String]
    let stem: String
    let fileExtension: String

    /// Returns the base filename for zero, or a numbered alternative beginning with “ (2)”.
    func filename(collisionIndex: Int) -> String {
        // Unsigned arithmetic permits Int.max without overflowing when adding one.
        let suffix = collisionIndex > 0 ? " (\(UInt(collisionIndex) + 1))" : ""
        return "\(stem)\(suffix).\(fileExtension)"
    }
}

enum ScreenshotNamingError: Error, LocalizedError, Equatable, Sendable {
    case emptyTemplate
    case unbalancedBraces
    case unknownToken(String)
    case unsupportedExtension(String)

    var errorDescription: String? {
        switch self {
        case .emptyTemplate:
            "Enter a screenshot name or a template using {app}, {date}, and {time}."
        case .unbalancedBraces:
            "The naming template has unmatched or nested braces. Use {app}, {date}, or {time}."
        case .unknownToken(let token):
            "Unknown naming token {\(token)}. Use {app}, {date}, or {time}."
        case .unsupportedExtension(let value):
            "Unsupported screenshot extension ‘\(value)’. Use PNG, JPG, JPEG, or HEIC."
        }
    }
}

enum ScreenshotNaming {
    /// Expands a template into safe filename and optional year/month directory components.
    static func plan(
        template: String,
        sourceExtension: String,
        context: ScreenshotNamingContext,
        organizeByDate: Bool
    ) throws -> ScreenshotNamePlan {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenshotNamingError.emptyTemplate
        }
        let fileExtension = sourceExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic"].contains(fileExtension) else {
            throw ScreenshotNamingError.unsupportedExtension(sourceExtension)
        }

        // This is a stable filesystem format, deliberately independent of the user's locale/calendar.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = context.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: context.capturedAt)
        formatter.dateFormat = "HH-mm-ss"
        let time = formatter.string(from: context.capturedAt)
        let app = sanitizedStem(context.appName ?? "")
        let expanded = try expand(template, tokens: ["app": app, "date": date, "time": time])

        // Stay strictly below 255 UTF-8 bytes, including the longest possible Int collision suffix.
        let maximumSuffix = " (\(UInt(Int.max) + 1))"
        let stemBudget = 254 - maximumSuffix.utf8.count - 1 - fileExtension.utf8.count
        let stem = utf8Prefix(sanitizedStem(expanded), maximumBytes: stemBudget)
        var directories: [String] = []
        if organizeByDate {
            formatter.dateFormat = "yyyy"
            directories.append(formatter.string(from: context.capturedAt))
            formatter.dateFormat = "MM"
            directories.append(formatter.string(from: context.capturedAt))
        }
        return ScreenshotNamePlan(
            directoryComponents: directories,
            stem: stem.isEmpty ? "Screenshot" : stem,
            fileExtension: fileExtension
        )
    }

    private static func expand(_ template: String, tokens: [String: String]) throws -> String {
        var result = ""
        var token: String?
        for scalar in template.unicodeScalars {
            switch scalar {
            case "{":
                guard token == nil else { throw ScreenshotNamingError.unbalancedBraces }
                token = ""
            case "}":
                guard let name = token else { throw ScreenshotNamingError.unbalancedBraces }
                guard let value = tokens[name] else { throw ScreenshotNamingError.unknownToken(name) }
                result.append(value)
                token = nil
            default:
                if token != nil {
                    token?.unicodeScalars.append(scalar)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        guard token == nil else { throw ScreenshotNamingError.unbalancedBraces }
        return result
    }

    private static func sanitizedStem(_ value: String) -> String {
        var result = ""
        for scalar in value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar == ":"
                || scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator {
                result.append("-")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        // Removing leading dots prevents hidden files and the special . / .. path components.
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        result = result.trimmingCharacters(in: edges)
        return result.isEmpty ? "Screenshot" : result
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var bytes = 0
        // Preserve entire grapheme clusters, including composed accents and joined emoji.
        for character in value {
            let count = character.utf8.count
            guard bytes + count <= maximumBytes else { break }
            result.append(character)
            bytes += count
        }
        return result
    }
}
