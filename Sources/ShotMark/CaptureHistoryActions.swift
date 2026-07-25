import AppKit
import Foundation

enum CaptureHistoryActionError: LocalizedError {
    case fileMissing
    case clipboardFailed

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            "记录对应的文件已经不存在。"
        case .clipboardFailed:
            "无法复制到剪切板。"
        }
    }
}

enum CaptureHistoryActions {
    static func copy(
        _ record: CaptureHistoryRecord,
        store: CaptureHistoryStore = .shared
    ) throws {
        guard let url = store.resolvedURL(for: record) else {
            throw CaptureHistoryActionError.fileMissing
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch record.mediaType {
        case .image:
            let data = try Data(contentsOf: url)
            guard pasteboard.setData(data, forType: .png) else {
                throw CaptureHistoryActionError.clipboardFailed
            }
        case .video:
            guard pasteboard.writeObjects([url as NSURL]) else {
                throw CaptureHistoryActionError.clipboardFailed
            }
        }
    }

    static func open(
        _ record: CaptureHistoryRecord,
        store: CaptureHistoryStore = .shared
    ) throws {
        guard let url = store.resolvedURL(for: record) else {
            throw CaptureHistoryActionError.fileMissing
        }
        NSWorkspace.shared.open(url)
    }

    static func reveal(
        _ record: CaptureHistoryRecord,
        store: CaptureHistoryStore = .shared
    ) throws {
        guard let url = store.resolvedURL(for: record) else {
            throw CaptureHistoryActionError.fileMissing
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
