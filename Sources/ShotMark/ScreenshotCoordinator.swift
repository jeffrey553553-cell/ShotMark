import AppKit
import Foundation

final class ScreenshotCoordinator: SelectionOverlayControllerDelegate {
    var onRecordingStateChanged: ((RecordingUIState) -> Void)?
    var onPinnedCountChanged: ((Int) -> Void)?

    private var overlayController: SelectionOverlayController?
    private var editorController: EditorWindowController?
    private var pinnedControllers: [PinnedScreenshotWindowController] = []
    private var recordingOverlayController: RecordingRegionOverlayController?
    private var longScreenshotController: LongScreenshotSessionController?
    private let captureService = CaptureService()
    private let videoRecordingService = VideoRecordingService()
    private let historyStore = CaptureHistoryStore.shared
    private let quickAccessController = QuickAccessWindowController.shared
    private var recordingResultScreen: NSScreen?
    private var recordingCreatedAt: Date?
    private var recordingState: RecordingUIState = .idle {
        didSet {
            recordingOverlayController?.update(state: recordingState)
            onRecordingStateChanged?(recordingState)
        }
    }

    var hasActiveRecordingSession: Bool {
        switch recordingState {
        case .idle:
            return false
        case .starting, .recording, .pausing, .paused, .resuming, .stopping:
            return true
        }
    }

    var currentRecordingState: RecordingUIState {
        recordingState
    }

    var pinnedScreenshotCount: Int {
        pinnedControllers.count
    }

    func bringPinnedScreenshotsToFront() {
        pinnedControllers.forEach { $0.bringToFront() }
    }

    func closeAllPinnedScreenshots() {
        let controllers = pinnedControllers
        controllers.forEach { $0.close() }
    }

    func handlePrimaryShortcut() {
        switch recordingState {
        case .idle:
            beginCapture()
        case .recording, .paused:
            stopRecording()
        case .starting, .pausing, .resuming, .stopping:
            break
        }
    }

    func beginCapture() {
        guard case .idle = recordingState else { return }

        PermissionService.verifyScreenRecordingAccess { [weak self] isGranted in
            DispatchQueue.main.async {
                guard let self else { return }
                if isGranted {
                    self.captureFrozenScreensAndShowOverlay()
                } else {
                    PermissionService.requestScreenRecordingAccess()
                    self.showPermissionHelp()
                }
            }
        }
    }

    private func captureFrozenScreensAndShowOverlay() {
        let screens = NSScreen.screens
        captureService.captureSnapshots(screens: screens) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshots):
                    self.showSelectionOverlay(frozenSnapshots: snapshots)
                case .failure(let error):
                    self.showError(error, title: "截图失败")
                }
            }
        }
    }

    private func showSelectionOverlay(frozenSnapshots: [ScreenSnapshot]) {
        overlayController?.cancel()
        let controller = SelectionOverlayController(frozenSnapshots: frozenSnapshots)
        controller.delegate = self
        overlayController = controller
        controller.show()
    }

    func showDemo() {
        guard let capture = DemoCaptureFactory.makeCapture() else { return }
        let editor = EditorWindowController(capture: capture)
        editorController = editor
        editor.show()
    }

    func selectionOverlayControllerDidCancel(_ controller: SelectionOverlayController) {
        overlayController = nil
    }

    func selectionOverlayController(_ controller: SelectionOverlayController, didCommit selection: CaptureSelection, frozenCapture: CaptureResult?, annotations: [Annotation], action: CaptureCommitAction) {
        overlayController = nil
        switch action {
        case .recordVideo(let options):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.startRecording(selection: selection, options: options)
            }
        case .longScreenshot:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.startLongScreenshot(selection: selection)
            }
        case .copyToClipboard, .saveToFile, .pinToScreen:
            if let frozenCapture {
                handle(frozenCapture, annotations: annotations, action: action)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.capture(selection, annotations: annotations, action: action)
            }
        }
    }

    func selectionOverlayController(_ controller: SelectionOverlayController, didRequestOCRCapture selection: CaptureSelection, completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        captureService.capture(selection: selection, completion: completion)
    }

    private func capture(_ selection: CaptureSelection, annotations: [Annotation], action: CaptureCommitAction) {
        captureService.capture(selection: selection) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let capture):
                    self?.handle(capture, annotations: annotations, action: action)
                case .failure(let error):
                    self?.showError(error, title: "截图失败")
                }
            }
        }
    }

    private func handle(_ capture: CaptureResult, annotations: [Annotation], action: CaptureCommitAction) {
        let state = EditorState(capture: capture)
        state.annotations = annotations
        let exportService = ExportService()
        switch action {
        case .copyToClipboard:
            do {
                let data = try exportService.pngData(for: state)
                try exportService.exportPNGData(data, to: .clipboard)
                showImageResult(
                    data: data,
                    capture: capture,
                    kind: .screenshot,
                    externalURL: nil,
                    message: "已复制到剪切板"
                )
            } catch {
                showError(error)
            }
        case .saveToFile:
            do {
                let url = ExportService.defaultSaveURL(createdAt: capture.createdAt)
                let data = try exportService.pngData(for: state)
                try exportService.exportPNGData(data, to: .file(url))
                showImageResult(
                    data: data,
                    capture: capture,
                    kind: .screenshot,
                    externalURL: url,
                    message: "已保存到 Downloads"
                )
            } catch {
                showError(error)
            }
        case .pinToScreen:
            do {
                let data = try exportService.pngData(for: state)
                guard let image = NSImage(data: data) else {
                    throw ExportServiceError.pngEncodingFailed
                }
                image.size = capture.imagePointSize

                let controller = PinnedScreenshotWindowController(
                    image: image,
                    pngData: data,
                    pointSize: capture.imagePointSize,
                    sourceRect: capture.selectionRectInScreen,
                    screen: screen(containing: capture.selectionRectInScreen),
                    createdAt: capture.createdAt
                )
                controller.onClose = { [weak self, weak controller] in
                    guard let controller else { return }
                    self?.pinnedControllers.removeAll { $0 === controller }
                    self?.notifyPinnedCountChanged()
                }
                pinnedControllers.append(controller)
                notifyPinnedCountChanged()
                controller.show()
                recordImage(
                    data: data,
                    capture: capture,
                    kind: .pinnedScreenshot,
                    externalURL: nil
                )
            } catch {
                showError(error)
            }
        case .recordVideo, .longScreenshot:
            break
        }
    }

    private func startLongScreenshot(selection: CaptureSelection) {
        let controller = LongScreenshotSessionController(selection: selection)
        longScreenshotController = controller
        controller.onFinish = { [weak self, weak controller] result in
            guard let self else { return }
            if let controller, self.longScreenshotController === controller {
                self.longScreenshotController = nil
            }

            switch result {
            case .success(let (capture, action)):
                let state = EditorState(capture: capture)
                do {
                    let exportService = ExportService()
                    let data = try exportService.pngData(for: state)
                    switch action {
                    case .copyToClipboard:
                        try exportService.exportPNGData(data, to: .clipboard)
                        self.showImageResult(
                            data: data,
                            capture: capture,
                            kind: .longScreenshot,
                            externalURL: nil,
                            message: "长截图已复制"
                        )
                    case .saveToFile:
                        let url = ExportService.defaultLongScreenshotURL(createdAt: capture.createdAt)
                        try exportService.exportPNGData(data, to: .file(url))
                        self.showImageResult(
                            data: data,
                            capture: capture,
                            kind: .longScreenshot,
                            externalURL: url,
                            message: "长截图已保存到 Downloads"
                        )
                    }
                } catch {
                    self.showError(error, title: "长截图失败")
                }
            case .failure(let error):
                self.showError(error, title: "长截图失败")
            }
        }
        controller.onCancel = { [weak self, weak controller] in
            if let controller, self?.longScreenshotController === controller {
                self?.longScreenshotController = nil
            }
            ToastWindowController.show(message: "已取消长截图")
        }
        controller.start()
    }

    private func startRecording(selection: CaptureSelection, options: VideoRecordingOptions) {
        guard case .idle = recordingState else { return }

        guard !options.audioMode.requiresMicrophonePermission else {
            PermissionService.requestMicrophoneAccess { [weak self] isGranted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if isGranted {
                        self.startRecordingAfterPermissionCheck(selection: selection, options: options)
                    } else {
                        self.showMicrophonePermissionHelp()
                    }
                }
            }
            return
        }

        startRecordingAfterPermissionCheck(selection: selection, options: options)
    }

    private func startRecordingAfterPermissionCheck(
        selection: CaptureSelection,
        options: VideoRecordingOptions
    ) {
        guard case .idle = recordingState else { return }

        recordingState = .starting
        let createdAt = Date()
        let outputURL = ExportService.defaultRecordingURL(createdAt: createdAt)
        recordingResultScreen = selection.screen
        recordingCreatedAt = createdAt
        videoRecordingService.onUnexpectedFailure = { [weak self] error in
            self?.recordingOverlayController?.close()
            self?.recordingOverlayController = nil
            self?.recordingResultScreen = nil
            self?.recordingCreatedAt = nil
            self?.recordingState = .idle
            self?.showError(error, title: "录制失败")
        }
        videoRecordingService.start(selection: selection, options: options, outputURL: outputURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                let startedAt = Date()
                let overlay = RecordingRegionOverlayController(
                    selection: selection,
                    initialState: .recording(startedAt: startedAt, elapsedBeforeStart: 0),
                    onStop: { [weak self] in self?.stopRecording() },
                    onTogglePause: { [weak self] in self?.toggleRecordingPause() }
                )
                self.recordingOverlayController = overlay
                overlay.show()
                self.recordingState = .recording(startedAt: startedAt, elapsedBeforeStart: 0)
            case .failure(let error):
                self.recordingResultScreen = nil
                self.recordingCreatedAt = nil
                self.recordingOverlayController?.close()
                self.recordingOverlayController = nil
                self.recordingState = .idle
                self.showError(error, title: "录制失败")
            }
        }
    }

    func toggleRecordingPause() {
        switch recordingState {
        case .recording:
            pauseRecording()
        case .paused:
            resumeRecording()
        case .idle, .starting, .pausing, .resuming, .stopping:
            break
        }
    }

    private func pauseRecording() {
        guard case .recording = recordingState else { return }
        let elapsed = recordingState.elapsed()
        recordingState = .pausing(elapsed: elapsed)
        videoRecordingService.pause { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.recordingState = .paused(elapsed: elapsed)
            case .failure(let error):
                self.recordingState = .recording(
                    startedAt: Date(),
                    elapsedBeforeStart: elapsed
                )
                self.showError(error, title: "暂停录制失败")
            }
        }
    }

    private func resumeRecording() {
        guard case .paused(let elapsed) = recordingState else { return }
        recordingState = .resuming(elapsed: elapsed)
        videoRecordingService.resume { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.recordingState = .recording(
                    startedAt: Date(),
                    elapsedBeforeStart: elapsed
                )
            case .failure(let error):
                self.recordingState = .paused(elapsed: elapsed)
                self.showError(error, title: "继续录制失败")
            }
        }
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        switch recordingState {
        case .recording, .paused:
            break
        case .pausing, .resuming:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.stopRecording(completion: completion)
            }
            return
        case .idle, .starting, .stopping:
            completion?()
            return
        }

        recordingState = .stopping
        recordingOverlayController?.close()
        recordingOverlayController = nil
        videoRecordingService.stop { [weak self] result in
            guard let self else { return }
            self.recordingState = .idle
            switch result {
            case .success(let url):
                let createdAt = self.recordingCreatedAt ?? Date()
                let resultScreen = self.recordingResultScreen
                Task { @MainActor [weak self] in
                    guard let self else {
                        completion?()
                        return
                    }
                    let metadata = await CaptureVideoMetadata.load(from: url)
                    do {
                        let record = try self.historyStore.addVideo(
                            url: url,
                            createdAt: createdAt,
                            pixelWidth: metadata.pixelWidth,
                            pixelHeight: metadata.pixelHeight,
                            duration: metadata.duration
                        )
                        self.quickAccessController.show(
                            record: record,
                            store: self.historyStore,
                            message: "录屏已保存到 Downloads",
                            screen: resultScreen
                        )
                    } catch {
                        ToastWindowController.show(message: "录屏已保存到 Downloads")
                    }
                    self.recordingResultScreen = nil
                    self.recordingCreatedAt = nil
                    completion?()
                }
                return
            case .failure(let error):
                self.showError(error, title: "录制失败")
            }
            self.recordingResultScreen = nil
            self.recordingCreatedAt = nil
            completion?()
        }
    }

    private func showImageResult(
        data: Data,
        capture: CaptureResult,
        kind: CaptureHistoryKind,
        externalURL: URL?,
        message: String
    ) {
        guard let record = recordImage(
            data: data,
            capture: capture,
            kind: kind,
            externalURL: externalURL
        ) else {
            ToastWindowController.show(message: message)
            return
        }
        quickAccessController.show(
            record: record,
            store: historyStore,
            message: message,
            screen: screen(containing: capture.selectionRectInScreen)
        )
    }

    @discardableResult
    private func recordImage(
        data: Data,
        capture: CaptureResult,
        kind: CaptureHistoryKind,
        externalURL: URL?
    ) -> CaptureHistoryRecord? {
        try? historyStore.addImage(
            data: data,
            kind: kind,
            createdAt: capture.createdAt,
            pixelWidth: capture.image.width,
            pixelHeight: capture.image.height,
            externalURL: externalURL
        )
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens
            .map { ($0, $0.frame.intersection(rect).width * $0.frame.intersection(rect).height) }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func notifyPinnedCountChanged() {
        onPinnedCountChanged?(pinnedControllers.count)
    }

    private func showError(_ error: Error, title: String = "截图失败") {
        if PermissionService.isLikelyScreenRecordingPermissionError(error) {
            showPermissionHelp()
            return
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "ShotMark 需要屏幕录制权限"
        alert.informativeText = """
        如果你还没授权，请在系统设置里打开 ShotMark 的屏幕录制权限。

        如果你已经打开权限但这里仍提示未开启，通常是 macOS 还没有把权限刷新给当前运行中的 App。请从状态栏菜单退出 ShotMark，然后重新打开。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开屏幕录制设置")
        alert.addButton(withTitle: "退出 ShotMark")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            PermissionService.openPrivacySettings()
        } else if response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private func showMicrophonePermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "ShotMark 需要麦克风权限"
        alert.informativeText = """
        你选择了“麦克风”或“系统+麦克风”录制模式。请在系统设置里允许 ShotMark 访问麦克风。

        如果你刚刚打开了权限，建议从状态栏菜单退出 ShotMark 后重新打开，再开始录制。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开麦克风设置")
        alert.addButton(withTitle: "退出 ShotMark")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            PermissionService.openMicrophoneSettings()
        } else if response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }
}
