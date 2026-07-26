import Foundation
import UniformTypeIdentifiers

enum ImageExportFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg
    case heic
    case tiff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .tiff: "tiff"
        }
    }

    var uniformType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        }
    }

    var supportsQualityAdjustment: Bool {
        self == .jpeg || self == .heic
    }
}

enum ExportMediaKind {
    case screenshot
    case longScreenshot
    case recording

    var filenameType: String {
        switch self {
        case .screenshot: "Screenshot"
        case .longScreenshot: "Long Screenshot"
        case .recording: "Recording"
        }
    }
}

enum ExportNaming {
    static let defaultTemplate = "{type} {date} {time}"

    static func filename(
        template: String,
        kind: ExportMediaKind,
        createdAt: Date,
        fileExtension: String,
        randomToken: String = String(UUID().uuidString.prefix(6)).lowercased()
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH.mm.ss"

        var baseName = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseName.isEmpty {
            baseName = defaultTemplate
        }
        let replacements = [
            "{type}": kind.filenameType,
            "{date}": dateFormatter.string(from: createdAt),
            "{time}": timeFormatter.string(from: createdAt),
            "{random}": randomToken
        ]
        for (placeholder, value) in replacements {
            baseName = baseName.replacingOccurrences(of: placeholder, with: value)
        }
        baseName = sanitizedBaseName(baseName)
        if baseName.isEmpty {
            baseName = kind.filenameType
        }
        return "\(baseName).\(fileExtension)"
    }

    static func uniqueURL(
        directory: URL,
        template: String,
        kind: ExportMediaKind,
        createdAt: Date,
        fileExtension: String,
        fileManager: FileManager = .default
    ) -> URL {
        let filename = filename(
            template: template,
            kind: kind,
            createdAt: createdAt,
            fileExtension: fileExtension
        )
        let initialURL = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: initialURL.path) else {
            return initialURL
        }

        let baseName = initialURL.deletingPathExtension().lastPathComponent
        let pathExtension = initialURL.pathExtension
        for suffix in 2...9_999 {
            let candidate = directory.appendingPathComponent(
                "\(baseName) \(suffix).\(pathExtension)"
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent(
            "\(baseName) \(UUID().uuidString.lowercased()).\(pathExtension)"
        )
    }

    private static func sanitizedBaseName(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)
        let components = value.components(separatedBy: invalidCharacters)
        let collapsed = components.joined(separator: "-")
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
        return collapsed.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ".")
            )
        )
    }
}
