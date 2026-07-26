import AppKit
import Foundation

enum CaptureDragItemProviderError: LocalizedError {
    case fileMissing
    case couldNotCreateProvider

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            "记录对应的文件已经不存在。"
        case .couldNotCreateProvider:
            "无法创建拖拽项目。"
        }
    }
}

final class CaptureDragItemProvider {
    static let shared = CaptureDragItemProvider()

    private let cacheRootURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        cacheRootURL: URL = CaptureDragItemProvider.defaultCacheRootURL,
        fileManager: FileManager = .default
    ) {
        self.cacheRootURL = cacheRootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    static var defaultCacheRootURL: URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("ShotMark", isDirectory: true)
            .appendingPathComponent("DragExports", isDirectory: true)
    }

    func dragURL(
        for record: CaptureHistoryRecord,
        store: CaptureHistoryStore = .shared
    ) throws -> URL {
        if let externalPath = record.externalFilePath,
           let externalURL = store.resolvedURL(for: record, preferExternal: true),
           externalURL.path == URL(fileURLWithPath: externalPath).standardizedFileURL.path {
            return externalURL
        }

        guard let sourceURL = store.resolvedURL(for: record, preferExternal: false) else {
            throw CaptureDragItemProviderError.fileMissing
        }
        guard record.mediaType == .image else {
            return sourceURL
        }

        return try lock.withLock {
            let itemDirectory = cacheRootURL
                .appendingPathComponent(record.id.uuidString, isDirectory: true)
            let destinationURL = itemDirectory.appendingPathComponent(
                semanticFileName(for: record),
                isDirectory: false
            )

            try fileManager.createDirectory(
                at: itemDirectory,
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
            return destinationURL
        }
    }

    func itemProvider(
        for record: CaptureHistoryRecord,
        store: CaptureHistoryStore = .shared
    ) throws -> NSItemProvider {
        let url = try dragURL(for: record, store: store)
        guard let provider = NSItemProvider(contentsOf: url) else {
            throw CaptureDragItemProviderError.couldNotCreateProvider
        }
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    private func semanticFileName(for record: CaptureHistoryRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"

        let prefix: String
        switch record.kind {
        case .screenshot:
            prefix = "Screenshot"
        case .longScreenshot:
            prefix = "Long Screenshot"
        case .pinnedScreenshot:
            prefix = "Pinned Screenshot"
        case .recording:
            prefix = "Recording"
        }
        return "\(prefix) \(formatter.string(from: record.createdAt)).png"
    }
}

private extension NSLocking {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
