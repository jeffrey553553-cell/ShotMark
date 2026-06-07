import AppKit
import Carbon
import CoreGraphics
import Foundation

enum LongScreenshotSessionError: LocalizedError {
    case noFrames
    case stitchingFailed

    var errorDescription: String? {
        switch self {
        case .noFrames:
            return "还没有采集到长截图内容。"
        case .stitchingFailed:
            return "长截图拼接失败。"
        }
    }
}

enum LongScreenshotCommitAction {
    case copyToClipboard
    case saveToFile
}

private extension LongScreenshotStitchUpdate {
    var isAccepted: Bool {
        switch outcome {
        case .initialized, .appended:
            true
        case .ignoredNoMovement, .ignoredAlignmentFailed:
            false
        }
    }

    var statusText: String {
        switch outcome {
        case .initialized:
            "已锁定首帧"
        case .appended(let deltaY):
            "已追加 \(deltaY)px，继续滚动"
        case .ignoredNoMovement:
            "未检测到新内容"
        case .ignoredAlignmentFailed:
            "拼接置信度低，放慢滚动"
        }
    }

    var previewStatusText: String {
        switch outcome {
        case .initialized:
            "首帧已采集"
        case .appended:
            "预览已更新"
        case .ignoredNoMovement:
            "无新增内容"
        case .ignoredAlignmentFailed:
            "等待更清晰的重叠区域"
        }
    }
}

private enum LongScreenshotHotKeyAction {
    case cancel
}

private final class LongScreenshotHotKeyService {
    var onAction: ((LongScreenshotHotKeyAction) -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let signature: OSType = 0x4C53484B // LSHK
    private let cancelHotKeyID: UInt32 = 1

    func registerCancelHotKey() {
        guard eventHandlerRef == nil, hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData else { return noErr }
                let service = Unmanaged<LongScreenshotHotKeyService>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard hotKeyID.signature == service.signature else { return noErr }
                if hotKeyID.id == service.cancelHotKeyID {
                    DispatchQueue.main.async {
                        service.onAction?(.cancel)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else { return }

        let id = EventHotKeyID(signature: signature, id: cancelHotKeyID)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            unregister()
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}

final class LongScreenshotSessionController {
    var onFinish: ((Result<(CaptureResult, LongScreenshotCommitAction), Error>) -> Void)?
    var onCancel: (() -> Void)?

    private let captureService = CaptureService()
    private let stitcher = LongScreenshotStitcher()
    private let frameSource = LongScreenshotFrameSource()
    private let frameRing = LongScreenshotFrameRing()
    private let selection: CaptureSelection
    private var captures: [CaptureResult] = []
    private var stitchedImageCache: CGImage?
    private var window: NSPanel?
    private var controlView: LongScreenshotControlView?
    private var localScrollMonitor: Any?
    private var globalScrollMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var hotKeyService: LongScreenshotHotKeyService?
    private var throttledScrollCaptureWorkItem: DispatchWorkItem?
    private var trailingScrollCaptureWorkItem: DispatchWorkItem?
    private var lastScrollCaptureAt = Date.distantPast
    private var pendingExpectedScrollDeltaPixels = 0
    private var primaryScrollDirectionSign: CGFloat?
    private var isStreamCaptureEnabled = true
    private var isStreamSourceReady = false
    private var isCapturing = false
    private var needsCaptureAfterCurrent = false
    private var finishAfterCapture = false
    private var pendingCommitAction: LongScreenshotCommitAction?
    private var frameWindow: NSPanel?
    private var previewWindow: NSPanel?
    private var previewView: LongScreenshotPreviewView?

    private let scrollCaptureInterval: TimeInterval = 0.075
    private let trailingCaptureDelay: TimeInterval = 0.09
    private let scrollDirectionThreshold: CGFloat = 0.1

    init(selection: CaptureSelection) {
        self.selection = selection
        isStreamCaptureEnabled = ProcessInfo.processInfo.environment["SHOTMARK_LONGSHOT_V1"] != "1"
    }

    func start() {
        showSelectionFrameWindow()
        showControlWindow()
        showPreviewWindow()
        installScrollMonitors()
        installKeyMonitors()
        installHotKeys()
        startFrameSourceIfNeeded()
        captureFrame()
    }

    func cancel() {
        cleanup()
        onCancel?()
    }

    private func finish(action: LongScreenshotCommitAction) {
        if isCapturing {
            finishAfterCapture = true
            pendingCommitAction = action
            updateControlView(status: "正在完成...")
            return
        }

        guard stitcher.acceptedFrameCount > 0 else {
            cleanup()
            onFinish?(.failure(LongScreenshotSessionError.noFrames))
            return
        }

        guard let stitched = stitchedImageCache ?? stitcher.mergedImage() else {
            cleanup()
            onFinish?(.failure(LongScreenshotSessionError.stitchingFailed))
            return
        }

        let result = CaptureResult(
            image: stitched,
            selectionRectInScreen: selection.rectInScreen,
            screenScale: selection.screen.backingScaleFactor,
            createdAt: Date()
        )
        cleanup()
        onFinish?(.success((result, action)))
    }

    private func installScrollMonitors() {
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
            return event
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
        }
    }

    private func installKeyMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleKey(event)
        }
    }

    private func installHotKeys() {
        let service = LongScreenshotHotKeyService()
        service.onAction = { [weak self] action in
            switch action {
            case .cancel:
                self?.cancel()
            }
        }
        service.registerCancelHotKey()
        hotKeyService = service
    }

    private func startFrameSourceIfNeeded() {
        guard isStreamCaptureEnabled else {
            updatePreview(status: "兼容模式采集")
            return
        }

        frameSource.onFrame = { [weak self] frame in
            self?.frameRing.append(frame)
        }
        frameSource.onFailure = { [weak self] _ in
            self?.isStreamSourceReady = false
            self?.isStreamCaptureEnabled = false
            self?.updatePreview(status: "帧流异常，已回退")
        }
        frameSource.start(selection: selection) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.isStreamSourceReady = true
                self.updatePreview(status: "实时帧流已启动")
            case .failure:
                self.isStreamSourceReady = false
                self.isStreamCaptureEnabled = false
                self.updatePreview(status: "帧流不可用，兼容采集")
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            cancel()
            return true
        }
        if event.keyCode == 49 {
            finish(action: .saveToFile)
            return true
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            finish(action: .copyToClipboard)
            return true
        }
        return false
    }

    private func handleScroll(_ event: NSEvent) {
        let verticalDelta = dominantVerticalScrollDelta(event)
        guard abs(verticalDelta) >= scrollDirectionThreshold else { return }
        let sign: CGFloat = verticalDelta > 0 ? 1 : -1

        if let primaryScrollDirectionSign, primaryScrollDirectionSign != sign {
            pauseCaptureForReverseScroll()
            return
        }

        if primaryScrollDirectionSign == nil {
            primaryScrollDirectionSign = sign
        }
        pendingExpectedScrollDeltaPixels += expectedScrollDeltaPixels(from: event, verticalDelta: verticalDelta)
        scheduleCaptureAfterScroll()
    }

    private func dominantVerticalScrollDelta(_ event: NSEvent) -> CGFloat {
        let preciseY = event.scrollingDeltaY
        let legacyY = event.deltaY
        let vertical = abs(preciseY) >= abs(legacyY) ? preciseY : legacyY
        let preciseX = event.scrollingDeltaX
        let legacyX = event.deltaX
        let horizontal = abs(preciseX) >= abs(legacyX) ? preciseX : legacyX
        return abs(vertical) >= abs(horizontal) ? vertical : 0
    }

    private func expectedScrollDeltaPixels(from event: NSEvent, verticalDelta: CGFloat) -> Int {
        let pointDelta = abs(verticalDelta) * (event.hasPreciseScrollingDeltas ? 1 : 18)
        let scale = max(1, selection.screen.backingScaleFactor)
        return max(1, Int((pointDelta * scale).rounded()))
    }

    private func pauseCaptureForReverseScroll() {
        throttledScrollCaptureWorkItem?.cancel()
        throttledScrollCaptureWorkItem = nil
        trailingScrollCaptureWorkItem?.cancel()
        trailingScrollCaptureWorkItem = nil
        needsCaptureAfterCurrent = false
        pendingExpectedScrollDeltaPixels = 0
        updateControlView(status: "反向滚动，暂停采集")
        updatePreview(status: "反向滚动暂停")
    }

    private func scheduleCaptureAfterScroll() {
        guard !finishAfterCapture else { return }
        updateControlView(status: "滚动中采集...")
        updatePreview(status: "滚动中")

        let now = Date()
        let elapsed = now.timeIntervalSince(lastScrollCaptureAt)
        if elapsed >= scrollCaptureInterval {
            lastScrollCaptureAt = now
            captureFrame()
        } else if throttledScrollCaptureWorkItem == nil {
            let delay = max(0.04, scrollCaptureInterval - elapsed)
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.finishAfterCapture else { return }
                self.throttledScrollCaptureWorkItem = nil
                self.lastScrollCaptureAt = Date()
                self.captureFrame()
            }
            throttledScrollCaptureWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        trailingScrollCaptureWorkItem?.cancel()
        let trailingWorkItem = DispatchWorkItem { [weak self] in
            guard let self, !self.finishAfterCapture else { return }
            self.trailingScrollCaptureWorkItem = nil
            self.lastScrollCaptureAt = Date()
            self.captureFrame()
        }
        trailingScrollCaptureWorkItem = trailingWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + trailingCaptureDelay, execute: trailingWorkItem)
    }

    private func captureFrame() {
        guard !finishAfterCapture else { return }
        if isCapturing {
            needsCaptureAfterCurrent = true
            return
        }

        isCapturing = true
        needsCaptureAfterCurrent = false
        let expectedDeltaPixels = pendingExpectedScrollDeltaPixels > 0 ? pendingExpectedScrollDeltaPixels : nil
        pendingExpectedScrollDeltaPixels = 0
        updateControlView(status: "正在采集...")

        if commitLatestStreamFrame(expectedDeltaPixels: expectedDeltaPixels) {
            finishCaptureTurn()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            guard let self else { return }
            self.captureService.capture(selection: self.selection) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isCapturing = false

                    switch result {
                    case .success(let capture):
                        let cleaned = self.cleanedCapture(capture)
                        self.commitImage(cleaned.image, createdAt: cleaned.createdAt, expectedDeltaPixels: expectedDeltaPixels, sequenceNumber: nil)
                    case .failure(let error):
                        self.cleanup()
                        self.onFinish?(.failure(error))
                        return
                    }

                    self.finishCaptureTurn()
                }
            }
        }
    }

    private func commitLatestStreamFrame(expectedDeltaPixels: Int?) -> Bool {
        guard isStreamCaptureEnabled, isStreamSourceReady else { return false }
        guard let frame = frameRing.latestFrame(after: frameRing.lastCommittedSequenceNumber) else { return false }
        commitImage(frame.image, createdAt: frame.capturedAt, expectedDeltaPixels: expectedDeltaPixels, sequenceNumber: frame.sequenceNumber)
        return true
    }

    private func commitImage(_ image: CGImage, createdAt: Date, expectedDeltaPixels: Int?, sequenceNumber: Int?) {
        let update = stitcher.append(image, expectedDeltaPixels: expectedDeltaPixels)
        stitchedImageCache = update?.mergedImage
        frameRing.markCommitted(sequenceNumber: sequenceNumber)
        if update?.isAccepted == true {
            captures.append(CaptureResult(
                image: image,
                selectionRectInScreen: selection.rectInScreen,
                screenScale: selection.screen.backingScaleFactor,
                createdAt: createdAt
            ))
            updateControlView(status: update?.statusText ?? "滚动页面继续采集")
            updatePreview(status: update?.previewStatusText ?? "继续滚动采集")
        } else {
            updateControlView(status: update?.statusText ?? "未检测到新内容")
            updatePreview(status: update?.previewStatusText ?? "未追加")
        }
    }

    private func finishCaptureTurn() {
        isCapturing = false
        if finishAfterCapture {
            finish(action: pendingCommitAction ?? .saveToFile)
        } else if needsCaptureAfterCurrent {
            captureFrame()
        }
    }

    private func showControlWindow() {
        let size = CGSize(width: 126, height: 40)
        let frame = toolbarFrame(size: size)

        let view = LongScreenshotControlView(frame: CGRect(origin: .zero, size: size))
        view.onCopy = { [weak self] in self?.finish(action: .copyToClipboard) }
        view.onSave = { [weak self] in self?.finish(action: .saveToFile) }
        view.onCancel = { [weak self] in self?.cancel() }
        controlView = view

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: selection.screen
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel
    }

    private func updateControlView(status: String) {
        controlView?.frameCount = captures.count
        controlView?.status = status
        controlView?.needsDisplay = true

        if let window {
            window.setFrame(toolbarFrame(size: window.frame.size), display: true)
        }
    }

    private func toolbarFrame(size: CGSize) -> CGRect {
        let usable = selection.screen.visibleFrame
        let spacing: CGFloat = 10
        let margin: CGFloat = 10
        let rect = selection.rectInScreen
        let centeredX = rect.midX - size.width / 2
        let candidates = [
            CGPoint(x: centeredX, y: rect.minY - size.height - spacing),
            CGPoint(x: centeredX, y: rect.maxY + spacing),
            CGPoint(x: centeredX, y: rect.minY + 14),
            CGPoint(x: centeredX, y: rect.maxY - size.height - 14),
            CGPoint(x: usable.midX - size.width / 2, y: usable.minY + margin)
        ]

        var origin = candidates.first { candidate in
            usable.insetBy(dx: margin, dy: margin).contains(CGRect(origin: candidate, size: size))
        } ?? candidates.last ?? CGPoint(x: centeredX, y: usable.minY + margin)

        origin.x = min(max(origin.x, usable.minX + margin), usable.maxX - size.width - margin)
        origin.y = min(max(origin.y, usable.minY + margin), usable.maxY - size.height - margin)
        return CGRect(origin: origin, size: size)
    }

    private func showSelectionFrameWindow() {
        let screenFrame = selection.screen.frame
        let localSelectionRect = selection.rectInScreen.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let view = LongScreenshotSelectionFrameView(
            frame: CGRect(origin: .zero, size: screenFrame.size),
            selectionRect: localSelectionRect
        )

        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: selection.screen
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.sharingType = .none
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        panel.orderFrontRegardless()
        frameWindow = panel
    }

    private func showPreviewWindow() {
        let size = previewSize(for: nil)
        let view = LongScreenshotPreviewView(frame: CGRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        previewView = view

        let panel = NSPanel(
            contentRect: previewFrame(size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: selection.screen
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        panel.orderFrontRegardless()
        previewWindow = panel
        updatePreview(status: "准备采集")
    }

    private func previewFrame(size: CGSize) -> CGRect {
        let margin: CGFloat = 12
        let usableFrame = selection.screen.visibleFrame.insetBy(dx: margin, dy: margin)
        let selectionRect = selection.rectInScreen
        let anchoredY = min(max(selectionRect.minY, usableFrame.minY), usableFrame.maxY - size.height)
        let rightX = selectionRect.maxX + margin
        let leftX = selectionRect.minX - size.width - margin
        let alignedRightX = selectionRect.maxX - size.width
        let candidates = [
            CGPoint(x: rightX, y: anchoredY),
            CGPoint(x: leftX, y: anchoredY),
            CGPoint(x: alignedRightX, y: selectionRect.minY - size.height - margin),
            CGPoint(x: alignedRightX, y: selectionRect.maxY + margin)
        ]

        let outsideCandidates = candidates
            .map { CGRect(origin: clampedOrigin($0, size: size, in: usableFrame), size: size) }
            .filter { usableFrame.contains($0) }
            .sorted { lhs, rhs in
                intersectionArea(lhs, selectionRect) < intersectionArea(rhs, selectionRect)
            }

        if let frame = outsideCandidates.first, !frame.intersects(selectionRect) {
            return frame
        }

        return outsideCandidates.first ?? CGRect(
            origin: clampedOrigin(CGPoint(x: rightX, y: anchoredY), size: size, in: usableFrame),
            size: size
        )
    }

    private func clampedOrigin(_ origin: CGPoint, size: CGSize, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, rect.minX), rect.maxX - size.width),
            y: min(max(origin.y, rect.minY), rect.maxY - size.height)
        )
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func updatePreview(status: String) {
        previewView?.frameCount = captures.count
        previewView?.status = status
        let stitchedImage = stitchedImageCache
        previewView?.image = stitchedImage
        previewView?.needsDisplay = true

        if let previewWindow {
            let size = previewSize(for: stitchedImage)
            previewWindow.contentView?.frame = CGRect(origin: .zero, size: size)
            previewWindow.setFrame(previewFrame(size: size), display: true)
        }
    }

    private func previewSize(for image: CGImage?) -> CGSize {
        let width: CGFloat = 152
        let minimumHeight: CGFloat = 188
        let chromeHeight: CGFloat = 62
        let screenFrame = selection.screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let maximumHeight = min(max(minimumHeight, screenFrame.height * 0.72), 560)

        guard let image, image.width > 0 else {
            return CGSize(width: width, height: min(minimumHeight, maximumHeight))
        }

        let previewImageWidth = width - 20
        let contentHeight = previewImageWidth * CGFloat(image.height) / CGFloat(image.width)
        let height = min(max(minimumHeight, contentHeight + chromeHeight), maximumHeight)
        return CGSize(width: width, height: height)
    }

    private func cleanedCapture(_ capture: CaptureResult) -> CaptureResult {
        let scale = max(1, capture.screenScale)
        let inset = max(2, Int((scale * 2).rounded()))
        let image = capture.image
        guard image.width > inset * 2 + 8, image.height > inset * 2 + 8 else {
            return capture
        }

        let cropRect = CGRect(
            x: inset,
            y: inset,
            width: image.width - inset * 2,
            height: image.height - inset * 2
        )
        guard let cropped = image.cropping(to: cropRect) else {
            return capture
        }

        let pointInset = CGFloat(inset) / scale
        return CaptureResult(
            image: cropped,
            selectionRectInScreen: capture.selectionRectInScreen.insetBy(dx: pointInset, dy: pointInset),
            screenScale: capture.screenScale,
            createdAt: capture.createdAt
        )
    }

    private func cleanup() {
        throttledScrollCaptureWorkItem?.cancel()
        throttledScrollCaptureWorkItem = nil
        trailingScrollCaptureWorkItem?.cancel()
        trailingScrollCaptureWorkItem = nil
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        frameSource.stop()
        frameSource.onFrame = nil
        frameSource.onFailure = nil
        frameRing.reset()
        hotKeyService?.unregister()
        hotKeyService = nil
        window?.orderOut(nil)
        window = nil
        controlView = nil
        frameWindow?.orderOut(nil)
        frameWindow = nil
        previewWindow?.orderOut(nil)
        previewWindow = nil
        previewView = nil
        stitchedImageCache = nil
        pendingExpectedScrollDeltaPixels = 0
        primaryScrollDirectionSign = nil
        isStreamSourceReady = false
        stitcher.reset()
        isCapturing = false
        needsCaptureAfterCurrent = false
        finishAfterCapture = false
        pendingCommitAction = nil
    }
}

final class LongScreenshotControlView: NSView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var frameCount = 0
    var status = "准备采集..."

    private var copyFrame: CGRect {
        CGRect(x: bounds.minX + 7, y: bounds.midY - 15, width: 32, height: 30)
    }

    private var saveFrame: CGRect {
        CGRect(x: bounds.minX + 44, y: bounds.midY - 15, width: 32, height: 30)
    }

    private var cancelFrame: CGRect {
        CGRect(x: bounds.minX + 87, y: bounds.midY - 15, width: 32, height: 30)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if copyFrame.contains(point) {
            onCopy?()
        } else if saveFrame.contains(point) {
            onSave?()
        } else if cancelFrame.contains(point) {
            onCancel?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawToolbarBackground()
        drawIconButton(kind: .copy, in: copyFrame)
        drawIconButton(kind: .save, in: saveFrame)
        drawSeparator(x: cancelFrame.minX - 6)
        drawIconButton(kind: .cancel, in: cancelFrame)
    }

    private enum IconKind {
        case copy
        case save
        case cancel
    }

    private func drawToolbarBackground() {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = CGSize(width: 0, height: -5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
        shadow.set()

        NSColor(calibratedWhite: 0.08, alpha: 0.86).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.12).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 14, yRadius: 14)
        border.lineWidth = 1
        border.stroke()
    }

    private func drawSeparator(x: CGFloat) {
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: x, y: bounds.minY + 8))
        path.line(to: CGPoint(x: x, y: bounds.maxY - 8))
        path.stroke()
    }

    private func drawIconButton(kind: IconKind, in rect: CGRect) {
        let color = kind == .cancel
            ? NSColor.white.withAlphaComponent(0.60)
            : NSColor.white.withAlphaComponent(0.86)

        switch kind {
        case .copy:
            drawSystemIcon("doc.on.doc", in: rect.insetBy(dx: 9, dy: 8), color: color)
        case .save:
            drawSystemIcon("square.and.arrow.down", in: rect.insetBy(dx: 9, dy: 8), color: color)
        case .cancel:
            drawSystemIcon("xmark", in: rect.insetBy(dx: 9, dy: 8), color: color)
        }
    }

    private func drawSystemIcon(_ symbolName: String, in rect: CGRect, color: NSColor) {
        guard
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15.2, weight: .medium))
        else { return }

        var proposedRect = rect
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext.current?.cgContext else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        context.clip(to: rect, mask: cgImage)
        color.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCopyIcon(in rect: CGRect, color: NSColor) {
        color.setStroke()
        let back = NSBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.minY + 4, width: rect.width - 4, height: rect.height - 4), xRadius: 2, yRadius: 2)
        back.lineWidth = 1.6
        back.stroke()
        let front = NSBezierPath(roundedRect: CGRect(x: rect.minX + 4, y: rect.minY, width: rect.width - 4, height: rect.height - 4), xRadius: 2, yRadius: 2)
        front.lineWidth = 1.6
        front.stroke()
    }

    private func drawSaveIcon(in rect: CGRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.midX, y: rect.minY + 5))
        path.move(to: CGPoint(x: rect.midX - 4, y: rect.minY + 9))
        path.line(to: CGPoint(x: rect.midX, y: rect.minY + 5))
        path.line(to: CGPoint(x: rect.midX + 4, y: rect.minY + 9))
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 1))
        path.line(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 1))
        path.stroke()
    }

    private func drawCancelIcon(in rect: CGRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.minY + 2))
        path.line(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 2))
        path.move(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 2))
        path.line(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
        path.stroke()
    }
}

final class LongScreenshotSelectionFrameView: NSView {
    private let selectionRect: CGRect

    init(frame frameRect: NSRect, selectionRect: CGRect) {
        self.selectionRect = selectionRect
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = selectionRect.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = CGSize(width: 0, height: -1)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.controlAccentColor.setStroke()
        path.stroke()

        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        for point in handlePoints(for: rect) {
            let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSBezierPath(ovalIn: handle).fill()
            let outline = NSBezierPath(ovalIn: handle)
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    private func handlePoints(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }
}

final class LongScreenshotPreviewView: NSView {
    var image: CGImage?
    var frameCount = 0
    var status = "准备采集"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let panelRect = bounds.insetBy(dx: 1, dy: 1)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: panelRect, xRadius: 14, yRadius: 14).fill()

        NSColor.white.withAlphaComponent(0.16).setStroke()
        let border = NSBezierPath(roundedRect: panelRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        border.lineWidth = 1
        border.stroke()

        let title = "长截图预览"
        title.draw(
            at: CGPoint(x: 12, y: bounds.maxY - 24),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ]
        )

        let imageSlot = CGRect(x: 10, y: 35, width: bounds.width - 20, height: bounds.height - 68)
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: imageSlot, xRadius: 9, yRadius: 9).fill()

        if let image {
            NSGraphicsContext.current?.imageInterpolation = .high
            let imageSize = CGSize(width: image.width, height: image.height)
            let scale = min(imageSlot.width / imageSize.width, imageSlot.height / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let drawRect = CGRect(
                x: imageSlot.midX - drawSize.width / 2,
                y: imageSlot.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            )

            NSGraphicsContext.current?.cgContext.saveGState()
            NSBezierPath(roundedRect: imageSlot, xRadius: 9, yRadius: 9).addClip()
            NSGraphicsContext.current?.cgContext.draw(image, in: drawRect)
            NSGraphicsContext.current?.cgContext.restoreGState()
        } else {
            "等待首张".draw(
                at: CGPoint(x: imageSlot.midX - 22, y: imageSlot.midY - 7),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.45)
                ]
            )
        }

        let footer = "\(frameCount) 张 · \(status)"
        footer.draw(
            at: CGPoint(x: 12, y: 13),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.64)
            ]
        )
    }
}
