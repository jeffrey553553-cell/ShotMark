import Foundation

extension Notification.Name {
    static let shotMarkHistoryDidChange = Notification.Name("ShotMarkHistoryDidChange")
}

enum CaptureHistoryMediaType: String, Codable, CaseIterable {
    case image
    case video
}

enum CaptureHistoryKind: String, Codable {
    case screenshot
    case longScreenshot
    case recording
    case pinnedScreenshot

    var title: String {
        switch self {
        case .screenshot:
            "截图"
        case .longScreenshot:
            "长截图"
        case .recording:
            "录屏"
        case .pinnedScreenshot:
            "钉住截图"
        }
    }
}

struct CaptureHistoryRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let mediaType: CaptureHistoryMediaType
    let kind: CaptureHistoryKind
    let createdAt: Date
    let storedFileName: String?
    let externalFilePath: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let duration: TimeInterval?
    let fileSize: Int64

    var dimensionsDescription: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var fileSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var durationDescription: String? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        let seconds = Int(duration.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var displayName: String {
        if let externalFilePath {
            return URL(fileURLWithPath: externalFilePath).lastPathComponent
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(kind.title) \(formatter.string(from: createdAt))"
    }
}

struct CaptureHistoryRetentionPolicy: Equatable {
    var maximumItemCount: Int
    var maximumAge: TimeInterval

    static let `default` = CaptureHistoryRetentionPolicy(
        maximumItemCount: 200,
        maximumAge: 30 * 24 * 60 * 60
    )
}

enum CaptureHistoryStoreError: LocalizedError {
    case mediaFileMissing
    case invalidStoredFileName

    var errorDescription: String? {
        switch self {
        case .mediaFileMissing:
            "历史记录对应的文件已经不存在。"
        case .invalidStoredFileName:
            "历史记录文件名无效。"
        }
    }
}

final class CaptureHistoryStore {
    static let shared = CaptureHistoryStore()

    private struct Index: Codable {
        var version: Int
        var records: [CaptureHistoryRecord]
    }

    private let rootURL: URL
    private let mediaDirectoryURL: URL
    private let indexURL: URL
    private let retentionPolicy: CaptureHistoryRetentionPolicy
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private var storedRecords: [CaptureHistoryRecord] = []

    init(
        rootURL: URL = CaptureHistoryStore.defaultRootURL,
        retentionPolicy: CaptureHistoryRetentionPolicy = .default,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        mediaDirectoryURL = rootURL.appendingPathComponent("Media", isDirectory: true).standardizedFileURL
        indexURL = rootURL.appendingPathComponent("index.json").standardizedFileURL
        self.retentionPolicy = retentionPolicy
        self.fileManager = fileManager
        loadIndex()
        try? prune()
    }

    static var defaultRootURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("ShotMark", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    var records: [CaptureHistoryRecord] {
        lock.withLock { storedRecords }
    }

    @discardableResult
    func addImage(
        data: Data,
        kind: CaptureHistoryKind,
        createdAt: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        externalURL: URL? = nil
    ) throws -> CaptureHistoryRecord {
        try lock.withLock {
            try ensureDirectories()
            let id = UUID()
            let storedFileName = "\(id.uuidString).png"
            let storedURL = try safeStoredURL(fileName: storedFileName)
            try data.write(to: storedURL, options: .atomic)

            let record = CaptureHistoryRecord(
                id: id,
                mediaType: .image,
                kind: kind,
                createdAt: createdAt,
                storedFileName: storedFileName,
                externalFilePath: externalURL?.standardizedFileURL.path,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                duration: nil,
                fileSize: Int64(data.count)
            )
            storedRecords.insert(record, at: 0)
            try pruneLocked(now: Date())
            try persistIndex()
            postChangeNotification()
            return record
        }
    }

    @discardableResult
    func addVideo(
        url: URL,
        createdAt: Date,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        duration: TimeInterval? = nil
    ) throws -> CaptureHistoryRecord {
        try lock.withLock {
            let standardizedURL = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardizedURL.path) else {
                throw CaptureHistoryStoreError.mediaFileMissing
            }
            let values = try? standardizedURL.resourceValues(forKeys: [.fileSizeKey])
            let record = CaptureHistoryRecord(
                id: UUID(),
                mediaType: .video,
                kind: .recording,
                createdAt: createdAt,
                storedFileName: nil,
                externalFilePath: standardizedURL.path,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                duration: duration,
                fileSize: Int64(values?.fileSize ?? 0)
            )
            storedRecords.insert(record, at: 0)
            try pruneLocked(now: Date())
            try persistIndex()
            postChangeNotification()
            return record
        }
    }

    func resolvedURL(for record: CaptureHistoryRecord, preferExternal: Bool = true) -> URL? {
        lock.withLock {
            if preferExternal, let external = existingExternalURL(for: record) {
                return external
            }
            if let storedFileName = record.storedFileName,
               let storedURL = try? safeStoredURL(fileName: storedFileName),
               fileManager.fileExists(atPath: storedURL.path) {
                return storedURL
            }
            return existingExternalURL(for: record)
        }
    }

    func delete(id: UUID) throws {
        try lock.withLock {
            guard let index = storedRecords.firstIndex(where: { $0.id == id }) else { return }
            let record = storedRecords.remove(at: index)
            try deleteManagedMedia(for: record)
            try persistIndex()
            postChangeNotification()
        }
    }

    func deleteAll() throws {
        try lock.withLock {
            for record in storedRecords {
                try deleteManagedMedia(for: record)
            }
            storedRecords.removeAll()
            try persistIndex()
            postChangeNotification()
        }
    }

    func prune(now: Date = Date()) throws {
        try lock.withLock {
            let changed = try pruneLocked(now: now)
            if changed {
                try persistIndex()
                postChangeNotification()
            }
        }
    }

    private func loadIndex() {
        lock.withLock {
            guard let data = try? Data(contentsOf: indexURL),
                  let index = try? JSONDecoder.shotMarkHistory.decode(Index.self, from: data),
                  index.version == 1 else {
                storedRecords = []
                return
            }
            storedRecords = index.records.sorted { $0.createdAt > $1.createdAt }
        }
    }

    @discardableResult
    private func pruneLocked(now: Date) throws -> Bool {
        let cutoff = now.addingTimeInterval(-max(0, retentionPolicy.maximumAge))
        let sorted = storedRecords.sorted { $0.createdAt > $1.createdAt }
        let retained = sorted.enumerated().compactMap { index, record -> CaptureHistoryRecord? in
            let insideCountLimit = retentionPolicy.maximumItemCount <= 0
                || index < retentionPolicy.maximumItemCount
            let insideAgeLimit = retentionPolicy.maximumAge <= 0
                || record.createdAt >= cutoff
            return insideCountLimit && insideAgeLimit ? record : nil
        }
        let retainedIDs = Set(retained.map(\.id))
        let removed = sorted.filter { !retainedIDs.contains($0.id) }
        for record in removed {
            try deleteManagedMedia(for: record)
        }
        storedRecords = retained
        return !removed.isEmpty
    }

    private func persistIndex() throws {
        try ensureDirectories()
        let index = Index(version: 1, records: storedRecords)
        let data = try JSONEncoder.shotMarkHistory.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: mediaDirectoryURL, withIntermediateDirectories: true)
    }

    private func safeStoredURL(fileName: String) throws -> URL {
        guard !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent else {
            throw CaptureHistoryStoreError.invalidStoredFileName
        }
        let candidate = mediaDirectoryURL.appendingPathComponent(fileName).standardizedFileURL
        let mediaPath = mediaDirectoryURL.path.hasSuffix("/")
            ? mediaDirectoryURL.path
            : mediaDirectoryURL.path + "/"
        guard candidate.path.hasPrefix(mediaPath) else {
            throw CaptureHistoryStoreError.invalidStoredFileName
        }
        return candidate
    }

    private func existingExternalURL(for record: CaptureHistoryRecord) -> URL? {
        guard let externalFilePath = record.externalFilePath else { return nil }
        let url = URL(fileURLWithPath: externalFilePath).standardizedFileURL
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func deleteManagedMedia(for record: CaptureHistoryRecord) throws {
        guard let storedFileName = record.storedFileName else { return }
        let url = try safeStoredURL(fileName: storedFileName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func postChangeNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shotMarkHistoryDidChange, object: self)
        }
    }
}

private extension NSLocking {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}

private extension JSONEncoder {
    static var shotMarkHistory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var shotMarkHistory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
