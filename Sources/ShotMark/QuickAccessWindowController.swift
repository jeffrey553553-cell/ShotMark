import AppKit
import UniformTypeIdentifiers

final class QuickAccessWindowController: NSObject {
    static let shared = QuickAccessWindowController()

    private var panel: QuickAccessPanel?
    private var contentView: QuickAccessContentView?
    private var dismissTimer: Timer?
    private var record: CaptureHistoryRecord?
    private var store: CaptureHistoryStore?
    private let sharePresenter = CaptureSharePresenter()

    override init() {
        super.init()
        sharePresenter.onVisibilityChanged = { [weak self] isVisible in
            guard let self, self.panel != nil else { return }
            if isVisible {
                self.pauseDismissTimer()
            } else {
                self.scheduleDismiss()
            }
        }
    }

    func show(
        record: CaptureHistoryRecord,
        store: CaptureHistoryStore = .shared,
        message: String,
        screen: NSScreen? = nil
    ) {
        dismiss()
        self.record = record
        self.store = store

        let size = CGSize(width: 360, height: 122)
        let contentView = QuickAccessContentView(frame: CGRect(origin: .zero, size: size))
        contentView.onMouseEntered = { [weak self] in self?.pauseDismissTimer() }
        contentView.onMouseExited = { [weak self] in self?.scheduleDismiss() }
        configure(contentView, record: record, store: store, message: message)

        let panel = QuickAccessPanel(
            contentRect: contentView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.identifier = NSUserInterfaceItemIdentifier("ShotMarkQuickAccessPanel")
        panel.contentView = contentView
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, screen: screen))
        panel.orderFrontRegardless()

        self.panel = panel
        self.contentView = contentView
        scheduleDismiss()
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
        contentView = nil
        record = nil
        store = nil
        sharePresenter.close()
    }

    private func configure(
        _ view: QuickAccessContentView,
        record: CaptureHistoryRecord,
        store: CaptureHistoryStore,
        message: String
    ) {
        view.titleLabel.stringValue = message
        view.detailLabel.stringValue = detailText(for: record)
        view.thumbnailView.image = thumbnail(for: record, store: store)
        view.thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        view.dragURLProvider = {
            try? CaptureDragItemProvider.shared.dragURL(for: record, store: store)
        }
        view.onDragStarted = { [weak self] in
            self?.pauseDismissTimer()
        }
        view.onDragEnded = { [weak self] succeeded in
            if succeeded {
                self?.dismiss()
            } else {
                self?.scheduleDismiss()
            }
        }
        view.thumbnailView.toolTip = "拖到其他 App"
        if record.mediaType == .video, let url = store.resolvedURL(for: record) {
            CaptureVideoThumbnailService.shared.loadThumbnail(for: url) { [weak self] image in
                guard self?.record?.id == record.id, let image else { return }
                self?.contentView?.thumbnailView.image = image
            }
        }

        configureButton(view.copyButton, symbol: "doc.on.doc", help: "复制", action: #selector(copyItem))
        configureButton(view.openButton, symbol: "arrow.up.forward.app", help: "打开", action: #selector(openItem))
        configureButton(view.revealButton, symbol: "folder", help: "在 Finder 中显示", action: #selector(revealItem))
        configureButton(view.shareButton, symbol: "square.and.arrow.up", help: "分享", action: #selector(shareItem))
        configureButton(view.removeButton, symbol: "trash", help: "从历史记录移除", action: #selector(removeItem))
        configureButton(view.closeButton, symbol: "xmark", help: "关闭", action: #selector(closeCard))
    }

    private func configureButton(_ button: NSButton, symbol: String, help: String, action: Selector) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(configuration)
        button.toolTip = help
        button.target = self
        button.action = action
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
    }

    private func detailText(for record: CaptureHistoryRecord) -> String {
        [record.kind.title, record.durationDescription, record.dimensionsDescription, record.fileSizeDescription]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }

    private func thumbnail(for record: CaptureHistoryRecord, store: CaptureHistoryStore) -> NSImage? {
        if record.mediaType == .image,
           let url = store.resolvedURL(for: record, preferExternal: false),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSWorkspace.shared.icon(for: .mpeg4Movie)
    }

    private func origin(for size: CGSize, screen: NSScreen?) -> CGPoint {
        let targetScreen = screen ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 18
        return CGPoint(
            x: visibleFrame.maxX - size.width - margin,
            y: visibleFrame.minY + margin
        )
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: 8, target: self, selector: #selector(closeCard), userInfo: nil, repeats: false)
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pauseDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    @objc private func copyItem() {
        guard let record, let store else { return }
        do {
            try CaptureHistoryActions.copy(record, store: store)
            contentView?.titleLabel.stringValue = record.mediaType == .image ? "已复制图片" : "已复制录屏文件"
            scheduleDismiss()
        } catch {
            showActionError(error)
        }
    }

    @objc private func openItem() {
        guard let record, let store else { return }
        do {
            try CaptureHistoryActions.open(record, store: store)
            dismiss()
        } catch {
            showActionError(error)
        }
    }

    @objc private func revealItem() {
        guard let record, let store else { return }
        do {
            try CaptureHistoryActions.reveal(record, store: store)
            dismiss()
        } catch {
            showActionError(error)
        }
    }

    @objc private func shareItem() {
        guard let record, let store, let button = contentView?.shareButton else { return }
        do {
            let items = try CaptureSharingService.items(for: record, store: store)
            sharePresenter.present(
                items: items,
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        } catch {
            showActionError(error)
        }
    }

    @objc private func removeItem() {
        guard let record, let store else { return }
        do {
            try store.delete(id: record.id)
            dismiss()
        } catch {
            showActionError(error)
        }
    }

    @objc private func closeCard() {
        dismiss()
    }

    private func showActionError(_ error: Error) {
        contentView?.titleLabel.stringValue = error.localizedDescription
        contentView?.titleLabel.textColor = .systemRed
        scheduleDismiss()
    }
}

private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class QuickAccessContentView: NSVisualEffectView, NSDraggingSource {
    let thumbnailView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let copyButton = NSButton()
    let openButton = NSButton()
    let revealButton = NSButton()
    let shareButton = NSButton()
    let removeButton = NSButton()
    let closeButton = NSButton()
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    var dragURLProvider: (() -> URL?)?
    private var trackingAreaReference: NSTrackingArea?
    private var dragStartPoint: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 6
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        [thumbnailView, titleLabel, detailLabel, copyButton, openButton, revealButton, shareButton, removeButton, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        let actionButtons = [copyButton, openButton, revealButton, shareButton, removeButton]
        for button in actionButtons {
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28)
            ])
        }

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            thumbnailView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            thumbnailView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            thumbnailView.widthAnchor.constraint(equalToConstant: 128),
            thumbnailView.heightAnchor.constraint(equalToConstant: 98),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),

            copyButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            copyButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            openButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 8),
            openButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            revealButton.leadingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: 8),
            revealButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            shareButton.leadingAnchor.constraint(equalTo: revealButton.trailingAnchor, constant: 8),
            shareButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: shareButton.trailingAnchor, constant: 8),
            removeButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = thumbnailView.frame.contains(point) ? point : nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint,
              let url = dragURLProvider?(),
              hypot(
                convert(event.locationInWindow, from: nil).x - dragStartPoint.x,
                convert(event.locationInWindow, from: nil).y - dragStartPoint.y
              ) >= 4 else {
            return
        }
        self.dragStartPoint = nil
        onDragStarted?()
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let previewSize = dragPreviewSize(for: thumbnailView.image)
        let currentPoint = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            CGRect(
                x: currentPoint.x - previewSize.width / 2,
                y: currentPoint.y - previewSize.height / 2,
                width: previewSize.width,
                height: previewSize.height
            ),
            contents: thumbnailView.image
        )
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnded?(operation != [])
    }

    private func dragPreviewSize(for image: NSImage?) -> CGSize {
        let maximum = CGSize(width: 120, height: 80)
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return maximum
        }
        let scale = min(maximum.width / image.size.width, maximum.height / image.size.height)
        return CGSize(
            width: max(36, image.size.width * scale),
            height: max(28, image.size.height * scale)
        )
    }
}
