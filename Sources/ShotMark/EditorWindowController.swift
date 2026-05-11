import AppKit

final class EditorWindowController: NSWindowController {
    private let state: EditorState
    private let canvasView: AnnotationCanvasView
    private let frameView: EditorFrameView
    private let toolbarController: EditorToolbarController
    private let defaultSaveURL: (Date) -> URL
    private var ocrPanelController: OCRResultPanelController?
    private let editorBorderWidth: CGFloat = 4

    init(capture: CaptureResult, defaultSaveURL: @escaping (Date) -> URL = ExportService.defaultSaveURL) {
        state = EditorState(capture: capture)
        canvasView = AnnotationCanvasView(state: state)
        frameView = EditorFrameView(canvasView: canvasView)
        toolbarController = EditorToolbarController()
        self.defaultSaveURL = defaultSaveURL

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(capture.selectionRectInScreen) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? capture.selectionRectInScreen
        let maxContentSize = CGSize(
            width: max(240, visibleFrame.width - 32 - editorBorderWidth * 2),
            height: max(180, visibleFrame.height - 96 - editorBorderWidth * 2)
        )
        let contentSize = CGSize(
            width: min(capture.imagePointSize.width, maxContentSize.width),
            height: min(capture.imagePointSize.height, maxContentSize.height)
        )
        let rawFrame = CGRect(
            x: capture.selectionRectInScreen.minX - editorBorderWidth,
            y: capture.selectionRectInScreen.minY - editorBorderWidth,
            width: contentSize.width + editorBorderWidth * 2,
            height: contentSize.height + editorBorderWidth * 2
        )
        let windowFrame = CGRect(
            x: min(max(rawFrame.minX, visibleFrame.minX + 12), visibleFrame.maxX - rawFrame.width - 12),
            y: min(max(rawFrame.minY, visibleFrame.minY + 54), visibleFrame.maxY - rawFrame.height - 12),
            width: rawFrame.width,
            height: rawFrame.height
        )
        let window = FloatingEditorPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = frameView

        super.init(window: window)
        configureCallbacks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        canvasView.window?.makeFirstResponder(canvasView)
        frameView.needsDisplay = true
        positionToolbar()
        toolbarController.show()
    }

    private func configureCallbacks() {
        canvasView.onFinishEditing = { [weak self] in self?.closeEditor() }
        canvasView.onCopyRequested = { [weak self] in self?.copyImage() }
        canvasView.onSaveRequested = { [weak self] in self?.saveImage() }
        canvasView.onToolShortcut = { [weak self] tool in
            self?.selectTool(tool)
        }

        toolbarController.onToolSelected = { [weak self] tool in
            let nextTool: AnnotationTool? = self?.state.selectedTool == tool ? nil : tool
            self?.selectTool(nextTool)
        }
        toolbarController.onOCR = { [weak self] in self?.runOCR() }
        toolbarController.onCopy = { [weak self] in self?.copyImage() }
        toolbarController.onSave = { [weak self] in self?.saveImage() }
        toolbarController.onClose = { [weak self] in self?.closeEditor() }
    }

    private func positionToolbar() {
        guard let window else { return }
        let frame = window.frame
        toolbarController.position(near: frame, on: window.screen)
    }

    private func selectTool(_ tool: AnnotationTool?) {
        state.selectedTool = tool
        toolbarController.selectedTool = tool
        canvasView.window?.makeFirstResponder(canvasView)
    }

    private func runOCR() {
        showOCRPanel(text: "OCR 识别中...")
        toolbarController.setBusy(true)
        OCRService().recognizeText(in: state.capture.image) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.toolbarController.setBusy(false)
                switch result {
                case .success(let lines):
                    self.state.ocrLines = lines
                    self.canvasView.needsDisplay = true
                    self.updateOCRPanel(lines)
                case .failure(let error):
                    self.showOCRPanel(text: "OCR 失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func copyImage() {
        do {
            try ExportService().export(state: state, to: .clipboard)
            toolbarController.showToast("已复制到剪切板")
        } catch {
            showError(title: "复制失败", message: error.localizedDescription)
        }
    }

    private func saveImage() {
        do {
            let url = defaultSaveURL(state.capture.createdAt)
            try ExportService().export(state: state, to: .file(url))
            toolbarController.showToast("已保存到 Downloads")
        } catch {
            showError(title: "保存失败", message: error.localizedDescription)
        }
    }

    private func showOCRPanel(text: String) {
        ocrPanelController?.close()
        let panel = OCRResultPanelController(text: text)
        panel.onClose = { [weak self, weak panel] in
            if let panel, self?.ocrPanelController === panel {
                self?.ocrPanelController = nil
                self?.canvasView.window?.makeFirstResponder(self?.canvasView)
            }
        }
        panel.onCopyAll = { [weak self] in
            self?.ocrPanelController = nil
            self?.toolbarController.showToast("文字已复制")
            self?.canvasView.window?.makeFirstResponder(self?.canvasView)
        }
        ocrPanelController = panel
        if let frame = window?.frame {
            panel.position(near: frame)
        }
        panel.show()
    }

    private func updateOCRPanel(_ lines: [OCRLine]) {
        if ocrPanelController == nil {
            showOCRPanel(text: lines.map(\.text).joined(separator: "\n"))
        } else {
            ocrPanelController?.update(lines: lines)
        }
    }

    private func closeEditor() {
        ocrPanelController?.close()
        toolbarController.close()
        close()
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
