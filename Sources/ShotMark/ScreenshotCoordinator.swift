import AppKit
import Foundation

final class ScreenshotCoordinator: SelectionOverlayControllerDelegate {
    var onRecordingStateChanged: ((RecordingUIState) -> Void)?

    private var overlayController: SelectionOverlayController?
    private var editorController: EditorWindowController?
    private var pinnedControllers: [PinnedScreenshotWindowController] = []
    private var recordingOverlayController: RecordingRegionOverlayController?
    private var longScreenshotController: LongScreenshotSessionController?
    private let captureService = CaptureService()
    private let videoRecordingService = VideoRecordingService()
    private var recordingState: RecordingUIState = .idle {
        didSet {
            onRecordingStateChanged?(recordingState)
        }
    }

    var hasActiveRecordingSession: Bool {
        switch recordingState {
        case .idle:
            return false
        case .starting, .recording, .stopping:
            return true
        }
    }

    func handlePrimaryShortcut() {
        switch recordingState {
        case .idle:
            beginCapture()
        case .recording:
            stopRecording()
        case .starting, .stopping:
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
        case .recordVideo(let quality, let audioMode):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.startRecording(selection: selection, quality: quality, audioMode: audioMode)
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
        switch action {
        case .copyToClipboard:
            do {
                try ExportService().export(state: state, to: .clipboard)
                ToastWindowController.show(message: "已复制到剪切板")
            } catch {
                showError(error)
            }
        case .saveToFile:
            do {
                let url = ExportService.defaultSaveURL(createdAt: capture.createdAt)
                try ExportService().export(state: state, to: .file(url))
                ToastWindowController.show(message: "已保存到 Downloads")
            } catch {
                showError(error)
            }
        case .pinToScreen:
            do {
                let data = try ExportService().pngData(for: state)
                guard let image = NSImage(data: data) else {
                    throw ExportServiceError.pngEncodingFailed
                }
                image.size = capture.imagePointSize

                let controller = PinnedScreenshotWindowController(
                    image: image,
                    pointSize: capture.imagePointSize,
                    sourceRect: capture.selectionRectInScreen,
                    screen: screen(containing: capture.selectionRectInScreen)
                )
                controller.onClose = { [weak self, weak controller] in
                    guard let controller else { return }
                    self?.pinnedControllers.removeAll { $0 === controller }
                }
                pinnedControllers.append(controller)
                controller.show()
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
                    switch action {
                    case .copyToClipboard:
                        try ExportService().export(state: state, to: .clipboard)
                        ToastWindowController.show(message: "长截图已复制")
                    case .saveToFile:
                        let url = ExportService.defaultLongScreenshotURL(createdAt: capture.createdAt)
                        try ExportService().export(state: state, to: .file(url))
                        ToastWindowController.show(message: "长截图已保存到 Downloads")
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

    private func startRecording(selection: CaptureSelection, quality: VideoQualityPreset, audioMode: VideoAudioMode) {
        guard case .idle = recordingState else { return }

        guard !audioMode.requiresMicrophonePermission else {
            PermissionService.requestMicrophoneAccess { [weak self] isGranted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if isGranted {
                        self.startRecordingAfterPermissionCheck(selection: selection, quality: quality, audioMode: audioMode)
                    } else {
                        self.showMicrophonePermissionHelp()
                    }
                }
            }
            return
        }

        startRecordingAfterPermissionCheck(selection: selection, quality: quality, audioMode: audioMode)
    }

    private func startRecordingAfterPermissionCheck(selection: CaptureSelection, quality: VideoQualityPreset, audioMode: VideoAudioMode) {
        guard case .idle = recordingState else { return }

        recordingState = .starting
        let outputURL = ExportService.defaultRecordingURL(createdAt: Date())
        videoRecordingService.onUnexpectedFailure = { [weak self] error in
            self?.recordingOverlayController?.close()
            self?.recordingOverlayController = nil
            self?.recordingState = .idle
            self?.showError(error, title: "录制失败")
        }
        videoRecordingService.start(selection: selection, quality: quality, audioMode: audioMode, outputURL: outputURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                let startedAt = Date()
                let overlay = RecordingRegionOverlayController(selection: selection, startedAt: startedAt) { [weak self] in
                    self?.stopRecording()
                }
                self.recordingOverlayController = overlay
                overlay.show()
                self.recordingState = .recording(startedAt: startedAt)
            case .failure(let error):
                self.recordingOverlayController?.close()
                self.recordingOverlayController = nil
                self.recordingState = .idle
                self.showError(error, title: "录制失败")
            }
        }
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        guard case .recording = recordingState else {
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
            case .success:
                ToastWindowController.show(message: "已保存到 Downloads")
            case .failure(let error):
                self.showError(error, title: "录制失败")
            }
            completion?()
        }
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens
            .map { ($0, $0.frame.intersection(rect).width * $0.frame.intersection(rect).height) }
            .max { $0.1 < $1.1 }?
            .0
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
