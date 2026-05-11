import AppKit
import CoreGraphics
import Foundation
import Vision

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

private struct FrameSample {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: CGImage, width: Int = 56, height: Int = 120) {
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let created = pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard created else { return nil }
        self.pixels = pixels
    }
}

private struct OverlapMatch {
    let rows: Int
    let score: Double
}

private struct FrameAppendPlan {
    let cropRect: CGRect
}

final class LongScreenshotSessionController {
    var onFinish: ((Result<(CaptureResult, LongScreenshotCommitAction), Error>) -> Void)?
    var onCancel: (() -> Void)?

    private let captureService = CaptureService()
    private let selection: CaptureSelection
    private var captures: [CaptureResult] = []
    private var stitchedSegments: [CGImage] = []
    private var lastAcceptedFrame: CGImage?
    private var stitchedImageCache: CGImage?
    private var window: NSPanel?
    private var controlView: LongScreenshotControlView?
    private var localScrollMonitor: Any?
    private var globalScrollMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var throttledScrollCaptureWorkItem: DispatchWorkItem?
    private var trailingScrollCaptureWorkItem: DispatchWorkItem?
    private var lastScrollCaptureAt = Date.distantPast
    private var isCapturing = false
    private var needsCaptureAfterCurrent = false
    private var finishAfterCapture = false
    private var pendingCommitAction: LongScreenshotCommitAction?
    private var frameWindow: NSPanel?
    private var previewWindow: NSPanel?
    private var previewView: LongScreenshotPreviewView?

    private let scrollCaptureInterval: TimeInterval = 0.075
    private let trailingCaptureDelay: TimeInterval = 0.09

    init(selection: CaptureSelection) {
        self.selection = selection
    }

    func start() {
        showSelectionFrameWindow()
        showControlWindow()
        showPreviewWindow()
        installScrollMonitors()
        installKeyMonitors()
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

        guard !captures.isEmpty else {
            cleanup()
            onFinish?(.failure(LongScreenshotSessionError.noFrames))
            return
        }

        guard let stitched = stitchedImageCache ?? stitch(captures.map(\.image)) else {
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
            self?.scheduleCaptureAfterScroll()
            return event
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.scheduleCaptureAfterScroll()
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
        updateControlView(status: "正在采集...")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            guard let self else { return }
            self.captureService.capture(selection: self.selection) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isCapturing = false

                    switch result {
                    case .success(let capture):
                        let cleaned = self.cleanedCapture(capture)
                        self.captures.append(cleaned)
                        self.acceptFrameForStitching(cleaned.image)
                        self.updateControlView(status: "滚动页面继续采集")
                        self.updatePreview(status: "继续滚动采集")
                    case .failure(let error):
                        self.cleanup()
                        self.onFinish?(.failure(error))
                        return
                    }

                    if self.finishAfterCapture {
                        self.finish(action: self.pendingCommitAction ?? .saveToFile)
                    } else if self.needsCaptureAfterCurrent {
                        self.captureFrame()
                    }
                }
            }
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

    private func stitch(_ images: [CGImage]) -> CGImage? {
        guard !images.isEmpty else { return nil }
        var segments: [CGImage] = [images[0]]
        var lastAcceptedFrame = images[0]

        for current in images.dropFirst() {
            guard
                let plan = appendPlan(previous: lastAcceptedFrame, current: current),
                let segment = current.cropping(to: plan.cropRect)
            else { continue }
            segments.append(segment)
            lastAcceptedFrame = current
        }

        return composeSegments(segments)
    }

    private func acceptFrameForStitching(_ image: CGImage) {
        guard let previous = lastAcceptedFrame else {
            stitchedSegments = [image]
            lastAcceptedFrame = image
            stitchedImageCache = composeSegments(stitchedSegments)
            return
        }

        guard
            let plan = appendPlan(previous: previous, current: image),
            let segment = image.cropping(to: plan.cropRect)
        else {
            return
        }

        stitchedSegments.append(segment)
        lastAcceptedFrame = image
        stitchedImageCache = composeSegments(stitchedSegments)
    }

    private func appendPlan(previous: CGImage, current: CGImage) -> FrameAppendPlan? {
        guard previous.width == current.width, previous.height == current.height else { return nil }

        if let plan = translationalAppendPlan(previous: previous, current: current) {
            return plan
        }

        guard let match = verticalOverlap(previous: previous, current: current) else { return nil }
        let appendHeight = current.height - match.rows
        let minimumAppendHeight = max(14, current.height / 100)
        guard match.rows >= current.height / 10,
              match.score < 18,
              appendHeight >= minimumAppendHeight,
              appendHeight <= current.height * 3 / 4 else {
            return nil
        }

        return FrameAppendPlan(
            cropRect: CGRect(x: 0, y: match.rows, width: current.width, height: appendHeight)
        )
    }

    private func composeSegments(_ segments: [CGImage]) -> CGImage? {
        guard !segments.isEmpty else { return nil }
        let width = segments.map(\.width).max() ?? 0
        let height = segments.reduce(0) { $0 + $1.height }
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var y = height
        for image in segments {
            y -= image.height
            context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
        }

        return context.makeImage()
    }

    private func translationalAppendPlan(previous: CGImage, current: CGImage) -> FrameAppendPlan? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: current, options: [:])
        let handler = VNImageRequestHandler(cgImage: previous, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let transform = request.results?.first?.alignmentTransform else { return nil }
        guard abs(transform.tx) <= CGFloat(current.width) * 0.12 else { return nil }
        let verticalDelta = abs(transform.ty)
        let appendHeight = Int(verticalDelta.rounded())
        let minimumAppendHeight = max(14, current.height / 100)
        guard appendHeight >= minimumAppendHeight,
              appendHeight <= current.height * 3 / 4 else {
            return nil
        }

        let overlapRows = current.height - appendHeight
        let score = overlapQualityScore(previous: previous, current: current, overlapRows: overlapRows)
        guard score < 22 else { return nil }

        return FrameAppendPlan(
            cropRect: CGRect(x: 0, y: overlapRows, width: current.width, height: appendHeight)
        )
    }

    private func verticalOverlap(previous: CGImage, current: CGImage) -> OverlapMatch? {
        guard previous.width == current.width, previous.height == current.height else { return nil }
        guard
            let previousSample = FrameSample(image: previous, width: 72, height: 160),
            let currentSample = FrameSample(image: current, width: 72, height: 160)
        else {
            return nil
        }

        let maximumRows = max(8, previousSample.height - 2)
        let minimumRows = max(8, previousSample.height / 8)
        var bestRows = 0
        var bestScore = Double.greatestFiniteMagnitude

        for rows in stride(from: maximumRows, through: minimumRows, by: -1) {
            let score = overlapScore(
                previous: previousSample,
                current: currentSample,
                rows: rows
            )
            let sizeBias = Double(maximumRows - rows) * 0.015
            let biasedScore = score + sizeBias
            if biasedScore < bestScore {
                bestScore = biasedScore
                bestRows = rows
            }
        }

        guard bestRows > 0 else { return nil }
        let ratio = CGFloat(bestRows) / CGFloat(previousSample.height)
        let imageRows = min(current.height - 1, max(0, Int((CGFloat(current.height) * ratio).rounded())))
        return OverlapMatch(rows: imageRows, score: bestScore)
    }

    private func overlapQualityScore(previous: CGImage, current: CGImage, overlapRows: Int) -> Double {
        guard previous.width == current.width, previous.height == current.height else {
            return Double.greatestFiniteMagnitude
        }
        guard
            let previousSample = FrameSample(image: previous, width: 72, height: 160),
            let currentSample = FrameSample(image: current, width: 72, height: 160)
        else {
            return Double.greatestFiniteMagnitude
        }

        let ratio = CGFloat(overlapRows) / CGFloat(current.height)
        let sampleRows = min(
            previousSample.height - 2,
            max(8, Int((CGFloat(previousSample.height) * ratio).rounded()))
        )
        return overlapScore(previous: previousSample, current: currentSample, rows: sampleRows)
    }

    private func overlapScore(previous: FrameSample, current: FrameSample, rows: Int) -> Double {
        var total = 0
        var count = 0
        let previousStart = previous.height - rows
        for row in 0..<rows {
            let previousOffset = (previousStart + row) * previous.width
            let currentOffset = row * current.width
            for column in 0..<previous.width {
                total += abs(Int(previous.pixels[previousOffset + column]) - Int(current.pixels[currentOffset + column]))
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) : Double.greatestFiniteMagnitude
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
        window?.orderOut(nil)
        window = nil
        controlView = nil
        frameWindow?.orderOut(nil)
        frameWindow = nil
        previewWindow?.orderOut(nil)
        previewWindow = nil
        previewView = nil
        stitchedSegments.removeAll()
        lastAcceptedFrame = nil
        stitchedImageCache = nil
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
