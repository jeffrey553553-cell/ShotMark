import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

final class CaptureHistoryWindowController: NSWindowController {
    private let viewModel: CaptureHistoryViewModel

    init(store: CaptureHistoryStore = .shared) {
        viewModel = CaptureHistoryViewModel(store: store)
        let hostingController = NSHostingController(rootView: CaptureHistoryView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "ShotMark 历史记录"
        window.setContentSize(CGSize(width: 780, height: 540))
        window.minSize = CGSize(width: 640, height: 420)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        viewModel.reload()
        super.showWindow(sender)
    }
}

private enum CaptureHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case images
    case videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .images: "图片"
        case .videos: "录屏"
        }
    }
}

private final class CaptureHistoryViewModel: ObservableObject {
    @Published private(set) var records: [CaptureHistoryRecord] = []
    @Published var query = ""
    @Published var filter: CaptureHistoryFilter = .all

    private let store: CaptureHistoryStore
    private var observer: NSObjectProtocol?

    init(store: CaptureHistoryStore) {
        self.store = store
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: .shotMarkHistoryDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var filteredRecords: [CaptureHistoryRecord] {
        records.filter { record in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .images:
                matchesFilter = record.mediaType == .image
            case .videos:
                matchesFilter = record.mediaType == .video
            }
            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            return record.displayName.localizedCaseInsensitiveContains(query)
                || record.kind.title.localizedCaseInsensitiveContains(query)
        }
    }

    func reload() {
        records = store.records
    }

    func thumbnail(for record: CaptureHistoryRecord) -> NSImage {
        if record.mediaType == .image,
           let url = store.resolvedURL(for: record, preferExternal: false),
           let thumbnail = CaptureHistoryThumbnailCache.shared.image(for: url) {
            return thumbnail
        }
        if let url = store.resolvedURL(for: record),
           let thumbnail = CaptureVideoThumbnailService.shared.cachedThumbnail(for: url) {
            return thumbnail
        }
        return NSWorkspace.shared.icon(for: .mpeg4Movie)
    }

    func requestVideoThumbnail(for record: CaptureHistoryRecord) {
        guard record.mediaType == .video,
              let url = store.resolvedURL(for: record),
              CaptureVideoThumbnailService.shared.cachedThumbnail(for: url) == nil else {
            return
        }
        CaptureVideoThumbnailService.shared.loadThumbnail(for: url) { [weak self] image in
            guard image != nil else { return }
            self?.objectWillChange.send()
        }
    }

    func isAvailable(_ record: CaptureHistoryRecord) -> Bool {
        store.resolvedURL(for: record) != nil
    }

    func dragItemProvider(for record: CaptureHistoryRecord) -> NSItemProvider {
        (try? CaptureDragItemProvider.shared.itemProvider(for: record, store: store))
            ?? NSItemProvider()
    }

    func copy(_ record: CaptureHistoryRecord) {
        perform {
            try CaptureHistoryActions.copy(record, store: store)
            ToastWindowController.show(message: record.mediaType == .image ? "已复制图片" : "已复制录屏文件")
        }
    }

    func open(_ record: CaptureHistoryRecord) {
        perform { try CaptureHistoryActions.open(record, store: store) }
    }

    func reveal(_ record: CaptureHistoryRecord) {
        perform { try CaptureHistoryActions.reveal(record, store: store) }
    }

    func remove(_ record: CaptureHistoryRecord) {
        perform {
            try store.delete(id: record.id)
            CaptureHistoryThumbnailCache.shared.removeAll()
        }
    }

    func clearHistory() {
        guard !records.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清空截图历史？"
        alert.informativeText = "只会删除 ShotMark 管理的历史副本，不会删除本地目录中已保存的截图和录屏。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空历史")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            try store.deleteAll()
            CaptureHistoryThumbnailCache.shared.removeAll()
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            let alert = NSAlert()
            alert.messageText = "操作失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

private struct CaptureHistoryView: View {
    @ObservedObject var viewModel: CaptureHistoryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(CaptureHistoryFilter.allCases) { filter in
                        Button {
                            viewModel.filter = filter
                        } label: {
                            Text(filter.title)
                                .font(.system(size: 12, weight: viewModel.filter == filter ? .semibold : .regular))
                                .frame(minWidth: 52)
                                .padding(.vertical, 5)
                                .foregroundStyle(viewModel.filter == filter ? Color.primary : Color.secondary)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(viewModel.filter == filter ? Color.primary.opacity(0.14) : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Color.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7))

                Spacer()

                Text("\(viewModel.filteredRecords.count) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button(action: viewModel.clearHistory) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("清空历史")
                .disabled(viewModel.records.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if viewModel.filteredRecords.isEmpty {
                ContentUnavailableView(
                    viewModel.query.isEmpty ? "暂无截图历史" : "没有匹配结果",
                    systemImage: viewModel.query.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                    description: Text(viewModel.query.isEmpty ? "完成截图或录屏后会显示在这里。" : "尝试其他关键词或筛选条件。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.filteredRecords) { record in
                    CaptureHistoryRow(record: record, viewModel: viewModel)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $viewModel.query, placement: .toolbar, prompt: "搜索截图历史")
        .frame(minWidth: 640, minHeight: 420)
    }
}

private struct CaptureHistoryRow: View {
    let record: CaptureHistoryRecord
    @ObservedObject var viewModel: CaptureHistoryViewModel

    var body: some View {
        let isAvailable = viewModel.isAvailable(record)
        HStack(spacing: 14) {
            historyThumbnail(isAvailable: isAvailable)

            VStack(alignment: .leading, spacing: 5) {
                Text(record.displayName)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Text(metadataText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isAvailable ? Color.secondary : Color.red)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            actionButton("doc.on.doc", help: "复制", disabled: !isAvailable) { viewModel.copy(record) }
            actionButton("arrow.up.forward.app", help: "打开", disabled: !isAvailable) { viewModel.open(record) }
            actionButton("folder", help: "在 Finder 中显示", disabled: !isAvailable) { viewModel.reveal(record) }
            actionButton("trash", help: "从历史记录移除") { viewModel.remove(record) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            viewModel.open(record)
        }
    }

    private func historyThumbnail(isAvailable: Bool) -> some View {
        let thumbnail = Image(nsImage: viewModel.thumbnail(for: record))
            .resizable()
            .scaledToFit()
            .frame(width: 104, height: 64)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                if isAvailable {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(4)
                        .background(.black.opacity(0.52))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                viewModel.requestVideoThumbnail(for: record)
            }
            .help(isAvailable ? "拖到其他 App" : "文件已移动或删除")

        return Group {
            if isAvailable {
                thumbnail.onDrag {
                    viewModel.dragItemProvider(for: record)
                } preview: {
                    Image(nsImage: viewModel.thumbnail(for: record))
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 120, maxHeight: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                thumbnail
            }
        }
    }

    private var metadataText: String {
        if !viewModel.isAvailable(record) {
            return "文件已移动或删除  ·  可从历史记录移除"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return [
            record.kind.title,
            formatter.string(from: record.createdAt),
            record.durationDescription,
            record.dimensionsDescription,
            record.fileSizeDescription
        ]
        .compactMap { $0 }
        .joined(separator: "  ·  ")
    }

    private func actionButton(
        _ symbol: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(disabled)
    }
}

private final class CaptureHistoryThumbnailCache {
    static let shared = CaptureHistoryThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 240,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
              ) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
