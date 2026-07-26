import AppKit

struct PinnedScreenshotGeometry {
    static let shadowOutset: CGFloat = 12
    static let screenMargin: CGFloat = 8
    static let maximumScreenFraction: CGFloat = 0.82
    static let minimumLongEdge: CGFloat = 96
    static let minimumCanvasSize = CGSize(width: 96, height: 48)
    static let minimumZoom: CGFloat = 0.25
    static let maximumZoom: CGFloat = 2

    static func initialImageSize(pointSize: CGSize, visibleFrame: CGRect) -> CGSize {
        guard pointSize.width > 0, pointSize.height > 0 else {
            return CGSize(width: minimumLongEdge, height: minimumLongEdge)
        }

        let maximumSize = CGSize(
            width: max(1, visibleFrame.width * maximumScreenFraction - shadowOutset * 2),
            height: max(1, visibleFrame.height * maximumScreenFraction - shadowOutset * 2)
        )
        let fitScale = min(1, maximumSize.width / pointSize.width, maximumSize.height / pointSize.height)
        let scale = min(
            maximumSize.width / pointSize.width,
            maximumSize.height / pointSize.height,
            fitScale
        )
        return CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }

    static func contentSize(imageSize: CGSize) -> CGSize {
        CGSize(
            width: max(imageSize.width, minimumCanvasSize.width) + shadowOutset * 2,
            height: max(imageSize.height, minimumCanvasSize.height) + shadowOutset * 2
        )
    }

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, zoom))
    }

    static func frame(
        for imageSize: CGSize,
        sourceRect: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        let size = contentSize(imageSize: imageSize)
        let preferredOrigin = CGPoint(
            x: sourceRect.minX - shadowOutset,
            y: sourceRect.minY - shadowOutset
        )
        return clampedFrame(CGRect(origin: preferredOrigin, size: size), to: visibleFrame)
    }

    static func resizedFrame(
        currentFrame: CGRect,
        imageSize: CGSize,
        anchor: CGPoint,
        visibleFrame: CGRect
    ) -> CGRect {
        let newSize = contentSize(imageSize: imageSize)
        let relativeX = currentFrame.width > 0 ? (anchor.x - currentFrame.minX) / currentFrame.width : 0.5
        let relativeY = currentFrame.height > 0 ? (anchor.y - currentFrame.minY) / currentFrame.height : 0.5
        let origin = CGPoint(
            x: anchor.x - newSize.width * relativeX,
            y: anchor.y - newSize.height * relativeY
        )
        return clampedFrame(CGRect(origin: origin, size: newSize), to: visibleFrame)
    }

    static func clampedFrame(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let available = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        var origin = frame.origin

        if frame.width <= available.width {
            origin.x = min(max(origin.x, available.minX), available.maxX - frame.width)
        } else {
            origin.x = min(max(origin.x, available.maxX - frame.width), available.minX)
        }

        if frame.height <= available.height {
            origin.y = min(max(origin.y, available.minY), available.maxY - frame.height)
        } else {
            origin.y = min(max(origin.y, available.maxY - frame.height), available.minY)
        }
        return CGRect(origin: origin, size: frame.size)
    }
}

final class PinnedScreenshotWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let pinnedView: PinnedScreenshotView
    private let pngData: Data
    private let createdAt: Date
    private let naturalImageSize: CGSize
    private let fitZoomFactor: CGFloat
    private let minimumAllowedZoom: CGFloat
    private var zoomFactor: CGFloat
    private var imageOpacity: CGFloat = 1
    private var isLocked = false
    private var localMouseMonitor: Any?
    private var passThroughTimer: Timer?

    init(
        image: NSImage,
        pngData: Data,
        pointSize: CGSize,
        sourceRect: CGRect,
        screen: NSScreen?,
        createdAt: Date
    ) {
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let displaySize = PinnedScreenshotGeometry.initialImageSize(
            pointSize: pointSize,
            visibleFrame: visibleFrame
        )
        self.pngData = pngData
        self.createdAt = createdAt
        naturalImageSize = pointSize
        let initialZoom = pointSize.width > 0 ? displaySize.width / pointSize.width : 1
        fitZoomFactor = initialZoom
        minimumAllowedZoom = min(PinnedScreenshotGeometry.minimumZoom, initialZoom)
        zoomFactor = initialZoom
        pinnedView = PinnedScreenshotView(image: image, displayImageSize: displaySize)
        pinnedView.zoomPercentage = Int((initialZoom * 100).rounded())

        let contentSize = PinnedScreenshotGeometry.contentSize(imageSize: displaySize)
        let window = FloatingEditorPanel(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = pinnedView
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        configureViewCallbacks()
        window.setFrame(
            PinnedScreenshotGeometry.frame(
                for: displaySize,
                sourceRect: sourceRect,
                visibleFrame: visibleFrame
            ),
            display: false
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeMouseMonitors()
    }

    func show() {
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func bringToFront() {
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        removeMouseMonitors()
        onClose?()
    }

    private func configureViewCallbacks() {
        pinnedView.onClose = { [weak self] in
            self?.window?.close()
        }
        pinnedView.onCopy = { [weak self] in
            self?.copyImage()
        }
        pinnedView.onSave = { [weak self] in
            self?.saveImage()
        }
        pinnedView.onToggleLock = { [weak self] in
            self?.setLocked(!(self?.isLocked ?? false))
        }
        pinnedView.onZoom = { [weak self] scale, anchor in
            self?.setZoom((self?.zoomFactor ?? 1) * scale, anchorInView: anchor)
        }
        pinnedView.onResetZoom = { [weak self] in
            self?.setZoom(1, anchorInView: nil)
        }
        pinnedView.onShowMenu = { [weak self] point in
            self?.showContextMenu(at: point)
        }
    }

    private func setZoom(_ requestedZoom: CGFloat, anchorInView: CGPoint?) {
        guard let window else { return }
        let newZoom = min(
            PinnedScreenshotGeometry.maximumZoom,
            max(minimumAllowedZoom, requestedZoom)
        )
        guard abs(newZoom - zoomFactor) > 0.001 else { return }

        let anchorScreen: CGPoint
        if let anchorInView {
            let anchorInWindow = pinnedView.convert(anchorInView, to: nil)
            anchorScreen = window.convertPoint(toScreen: anchorInWindow)
        } else {
            anchorScreen = CGPoint(x: window.frame.midX, y: window.frame.midY)
        }
        let imageSize = CGSize(
            width: naturalImageSize.width * newZoom,
            height: naturalImageSize.height * newZoom
        )
        pinnedView.displayImageSize = imageSize
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let newFrame = PinnedScreenshotGeometry.resizedFrame(
            currentFrame: window.frame,
            imageSize: imageSize,
            anchor: anchorScreen,
            visibleFrame: visibleFrame
        )
        zoomFactor = newZoom
        pinnedView.zoomPercentage = Int((newZoom * 100).rounded())
        window.setFrame(newFrame, display: true, animate: false)
        updateLockedPassThrough(at: NSEvent.mouseLocation)
    }

    private func setOpacity(_ opacity: CGFloat) {
        imageOpacity = min(1, max(0.25, opacity))
        pinnedView.imageOpacity = imageOpacity
    }

    private func setLocked(_ locked: Bool) {
        isLocked = locked
        pinnedView.isLocked = locked
        if locked {
            installMouseMonitors()
            updateLockedPassThrough(at: NSEvent.mouseLocation)
            ToastWindowController.show(message: "钉图已锁定，鼠标可穿透")
        } else {
            removeMouseMonitors()
            window?.ignoresMouseEvents = false
            ToastWindowController.show(message: "钉图已解锁")
        }
    }

    private func copyImage() {
        do {
            try ExportService().exportPNGData(pngData, to: .clipboard)
            ToastWindowController.show(message: "钉图已复制到剪切板")
        } catch {
            showExportError(error)
        }
    }

    private func saveImage() {
        do {
            let url = ExportService.defaultSaveURL(createdAt: createdAt)
            let exportService = ExportService()
            let format = AppSettings.shared.imageExportFormat
            let data = try exportService.transcodePNGData(pngData, to: format)
            try exportService.exportImageData(data, format: format, to: .file(url))
            let followUp = PostCaptureActions.copyImageAfterSavingIfNeeded(
                pngData: pngData
            ) { data in
                try exportService.exportPNGData(data, to: .clipboard)
            }
            ToastWindowController.show(
                message: PostCaptureActions.saveConfirmation(
                    for: url,
                    followUpResult: followUp
                )
            )
        } catch {
            showExportError(error)
        }
    }

    private func showExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "钉图操作失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showContextMenu(at point: CGPoint) {
        let menu = NSMenu()
        menu.addItem(menuItem(title: "复制", action: #selector(copyMenuAction), keyEquivalent: "c"))
        menu.addItem(menuItem(
            title: "保存到 \(AppSettings.shared.saveDirectory.lastPathComponent)",
            action: #selector(saveMenuAction),
            keyEquivalent: "s"
        ))
        menu.addItem(.separator())

        let zoomMenu = NSMenu()
        let fitItem = menuItem(
            title: "适合屏幕（\(Int((fitZoomFactor * 100).rounded()))%）",
            action: #selector(fitZoomMenuAction)
        )
        fitItem.state = abs(fitZoomFactor - zoomFactor) < 0.01 ? .on : .off
        zoomMenu.addItem(fitItem)
        zoomMenu.addItem(.separator())
        for percentage in [50, 75, 100, 125, 150, 200] {
            let item = menuItem(
                title: "\(percentage)%",
                action: #selector(zoomMenuAction(_:)),
                representedObject: NSNumber(value: percentage)
            )
            item.state = abs(CGFloat(percentage) / 100 - zoomFactor) < 0.01 ? .on : .off
            zoomMenu.addItem(item)
        }
        let zoomItem = NSMenuItem(title: "缩放 \(Int((zoomFactor * 100).rounded()))%", action: nil, keyEquivalent: "")
        zoomItem.submenu = zoomMenu
        menu.addItem(zoomItem)

        let opacityMenu = NSMenu()
        for percentage in [40, 60, 80, 100] {
            let item = menuItem(
                title: "\(percentage)%",
                action: #selector(opacityMenuAction(_:)),
                representedObject: NSNumber(value: percentage)
            )
            item.state = abs(CGFloat(percentage) / 100 - imageOpacity) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "透明度 \(Int((imageOpacity * 100).rounded()))%", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: isLocked ? "解除锁定" : "锁定并允许鼠标穿透",
            action: #selector(toggleLockMenuAction)
        ))
        menu.addItem(menuItem(title: "关闭钉图", action: #selector(closeMenuAction), keyEquivalent: "\u{1b}"))
        menu.popUp(positioning: nil, at: point, in: pinnedView)
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        representedObject: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.representedObject = representedObject
        return item
    }

    @objc private func copyMenuAction() {
        copyImage()
    }

    @objc private func saveMenuAction() {
        saveImage()
    }

    @objc private func toggleLockMenuAction() {
        setLocked(!isLocked)
    }

    @objc private func closeMenuAction() {
        window?.close()
    }

    @objc private func zoomMenuAction(_ sender: NSMenuItem) {
        guard let percentage = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        setZoom(CGFloat(percentage / 100), anchorInView: nil)
    }

    @objc private func fitZoomMenuAction() {
        setZoom(fitZoomFactor, anchorInView: nil)
    }

    @objc private func opacityMenuAction(_ sender: NSMenuItem) {
        guard let percentage = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        setOpacity(CGFloat(percentage / 100))
    }

    private func installMouseMonitors() {
        guard localMouseMonitor == nil, passThroughTimer == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] event in
            self?.updateLockedPassThrough(at: NSEvent.mouseLocation)
            return event
        }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updateLockedPassThrough(at: NSEvent.mouseLocation)
        }
        passThroughTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        passThroughTimer?.invalidate()
        passThroughTimer = nil
    }

    private func updateLockedPassThrough(at mouseLocation: CGPoint) {
        guard isLocked, let window else { return }
        let controlOriginInWindow = pinnedView.convert(pinnedView.controlBarFrame.origin, to: nil)
        let controlOriginOnScreen = window.convertPoint(toScreen: controlOriginInWindow)
        let controlFrameOnScreen = CGRect(origin: controlOriginOnScreen, size: pinnedView.controlBarFrame.size)
        window.ignoresMouseEvents = !controlFrameOnScreen.insetBy(dx: -6, dy: -6).contains(mouseLocation)
    }
}

final class PinnedScreenshotView: NSView {
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onToggleLock: (() -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onResetZoom: (() -> Void)?
    var onShowMenu: ((CGPoint) -> Void)?

    var imageOpacity: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    var displayImageSize: CGSize {
        didSet { needsDisplay = true }
    }
    var zoomPercentage = 100 {
        didSet { needsDisplay = true }
    }
    var isLocked = false {
        didSet { needsDisplay = true }
    }

    private let image: NSImage
    private let buttonSize: CGFloat = 24
    private var isHovered = false
    private var trackingAreaReference: NSTrackingArea?

    init(image: NSImage, displayImageSize: CGSize) {
        self.image = image
        self.displayImageSize = displayImageSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityLabel("钉图")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeButtonFrame.insetBy(dx: -5, dy: -5).contains(point) {
            onClose?()
            return
        }
        if lockButtonFrame.insetBy(dx: -5, dy: -5).contains(point) {
            onToggleLock?()
            return
        }
        if event.clickCount == 2 {
            onResetZoom?()
            return
        }
        window?.makeKey()
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onShowMenu?(convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.012 : 0.06
        let factor = exp(delta * sensitivity)
        onZoom?(factor, convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(max(0.2, 1 + event.magnification), convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command), characters == "c" {
            onCopy?()
            return
        }
        if event.modifierFlags.contains(.command), characters == "s" {
            onSave?()
            return
        }
        switch characters {
        case "\u{1b}":
            onClose?()
        case "+", "=":
            onZoom?(1.1, CGPoint(x: bounds.midX, y: bounds.midY))
        case "-":
            onZoom?(1 / 1.1, CGPoint(x: bounds.midX, y: bounds.midY))
        case "0":
            onResetZoom?()
        case "l":
            onToggleLock?()
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let imageFrame = imageFrame
        let imagePath = NSBezierPath(roundedRect: imageFrame, xRadius: 6, yRadius: 6)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = CGSize(width: 0, height: -7)
        shadow.set()
        NSColor.black.withAlphaComponent(0.18).setFill()
        imagePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        imagePath.addClip()
        image.draw(in: imageFrame, from: .zero, operation: .sourceOver, fraction: imageOpacity)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.24).setStroke()
        imagePath.lineWidth = 1
        imagePath.stroke()

        if isHovered || isLocked {
            drawChrome()
        }
    }

    var controlBarFrame: CGRect {
        CGRect(
            x: bounds.maxX - PinnedScreenshotGeometry.shadowOutset - buttonSize * 2 - 9,
            y: bounds.maxY - PinnedScreenshotGeometry.shadowOutset - buttonSize,
            width: buttonSize * 2 + 9,
            height: buttonSize
        )
    }

    private var imageFrame: CGRect {
        CGRect(
            x: bounds.midX - displayImageSize.width / 2,
            y: bounds.midY - displayImageSize.height / 2,
            width: displayImageSize.width,
            height: displayImageSize.height
        )
    }

    private var closeButtonFrame: CGRect {
        CGRect(
            x: controlBarFrame.maxX - buttonSize,
            y: controlBarFrame.minY,
            width: buttonSize,
            height: buttonSize
        )
    }

    private var lockButtonFrame: CGRect {
        CGRect(
            x: controlBarFrame.minX,
            y: controlBarFrame.minY,
            width: buttonSize,
            height: buttonSize
        )
    }

    private func drawChrome() {
        drawZoomBadge()
        drawCircularButton(in: lockButtonFrame)
        drawLock(in: lockButtonFrame)
        drawCircularButton(in: closeButtonFrame)
        drawClose(in: closeButtonFrame)
    }

    private func drawZoomBadge() {
        let text = "\(zoomPercentage)%"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: controlBarFrame.minX - size.width - 17,
            y: controlBarFrame.midY - 10,
            width: size.width + 12,
            height: 20
        )
        guard rect.minX >= bounds.minX + PinnedScreenshotGeometry.shadowOutset else { return }
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        text.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawCircularButton(in rect: CGRect) {
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    private func drawClose(in rect: CGRect) {
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        path.move(to: CGPoint(x: rect.minX + 8, y: rect.minY + 8))
        path.line(to: CGPoint(x: rect.maxX - 8, y: rect.maxY - 8))
        path.move(to: CGPoint(x: rect.maxX - 8, y: rect.minY + 8))
        path.line(to: CGPoint(x: rect.minX + 8, y: rect.maxY - 8))
        path.stroke()
    }

    private func drawLock(in rect: CGRect) {
        let body = CGRect(x: rect.midX - 4.5, y: rect.midY - 4, width: 9, height: 8)
        let shackle = NSBezierPath()
        shackle.lineWidth = 1.5
        shackle.lineCapStyle = .round
        shackle.move(to: CGPoint(x: rect.midX - 3, y: body.maxY))
        shackle.curve(
            to: CGPoint(x: rect.midX + 3, y: body.maxY),
            controlPoint1: CGPoint(x: rect.midX - 3, y: body.maxY + (isLocked ? 5 : 3)),
            controlPoint2: CGPoint(x: rect.midX + 3, y: body.maxY + (isLocked ? 5 : 3))
        )
        if !isLocked {
            shackle.transform(using: AffineTransform(
                translationByX: 2,
                byY: 0
            ))
        }
        NSColor.white.withAlphaComponent(0.92).setStroke()
        shackle.stroke()
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: body, xRadius: 1.8, yRadius: 1.8).fill()
    }
}
