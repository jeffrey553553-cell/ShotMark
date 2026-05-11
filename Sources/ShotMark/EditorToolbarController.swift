import AppKit

final class EditorToolbarController: NSWindowController {
    var onToolSelected: ((AnnotationTool) -> Void)?
    var onOCR: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    var selectedTool: AnnotationTool? {
        didSet { updateButtons() }
    }

    private let stackView = NSStackView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var buttons: [AnnotationTool: NSButton] = [:]

    init() {
        let content = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 430, height: 44))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10

        let window = NSPanel(
            contentRect: content.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = content

        super.init(window: window)
        buildToolbar(in: content)
        updateButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.orderFrontRegardless()
    }

    func position(near rect: CGRect, on screen: NSScreen?) {
        guard let window else { return }
        let screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? rect
        var origin = CGPoint(x: rect.midX - window.frame.width / 2, y: rect.minY - window.frame.height - 10)
        if origin.y < screenFrame.minY + 8 {
            origin.y = rect.maxY + 10
        }
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - window.frame.width - 8)
        window.setFrameOrigin(origin)
    }

    func setBusy(_ busy: Bool) {
        toastLabel.stringValue = busy ? "OCR 识别中..." : ""
    }

    func showToast(_ text: String) {
        toastLabel.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toastLabel.stringValue == text {
                self?.toastLabel.stringValue = ""
            }
        }
    }

    private func buildToolbar(in content: NSView) {
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stackView)

        addToolButton(title: "□", tool: .rectangle, help: "框选，快捷键 1")
        addToolButton(title: "↗", tool: .arrow, help: "箭头，快捷键 2")
        addToolButton(title: "③", tool: .numberMarker, help: "标记序号，快捷键 3")
        addToolButton(title: "T", tool: .text, help: "文字评论，快捷键 T")
        addToolButton(title: "▦", tool: .mosaic, help: "马赛克，快捷键 5")
        addDivider()
        addActionButton(title: "OCR", help: "OCR 识别", action: #selector(ocrPressed))
        addActionButton(title: "复制", help: "复制图片", action: #selector(copyPressed))
        addActionButton(title: "保存", help: "保存到 Downloads，快捷键 Space", action: #selector(savePressed))
        addActionButton(title: "×", help: "关闭", action: #selector(closePressed))

        toastLabel.font = .systemFont(ofSize: 12, weight: .medium)
        toastLabel.textColor = .white
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toastLabel)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stackView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            toastLabel.leadingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: 8),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            toastLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
    }

    private func addToolButton(title: String, tool: AnnotationTool, help: String) {
        let button = toolbarButton(title: title)
        button.toolTip = help
        button.target = self
        button.action = #selector(toolPressed(_:))
        button.tag = AnnotationTool.allCases.firstIndex(of: tool) ?? 0
        buttons[tool] = button
        stackView.addArrangedSubview(button)
    }

    private func addActionButton(title: String, help: String, action: Selector) {
        let button = toolbarButton(title: title)
        button.toolTip = help
        button.target = self
        button.action = action
        stackView.addArrangedSubview(button)
    }

    private func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        stackView.addArrangedSubview(divider)
    }

    private func toolbarButton(title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.setButtonType(.momentaryPushIn)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func updateButtons() {
        for (tool, button) in buttons {
            button.contentTintColor = tool == selectedTool ? .controlAccentColor : .labelColor
            button.layer?.backgroundColor = (tool == selectedTool
                ? NSColor.controlAccentColor.withAlphaComponent(0.20)
                : NSColor.white.withAlphaComponent(0.08)
            ).cgColor
        }
    }

    @objc private func toolPressed(_ sender: NSButton) {
        let tool = AnnotationTool.allCases[sender.tag]
        selectedTool = selectedTool == tool ? nil : tool
        onToolSelected?(tool)
    }

    @objc private func ocrPressed() { onOCR?() }
    @objc private func copyPressed() { onCopy?() }
    @objc private func savePressed() { onSave?() }
    @objc private func closePressed() { onClose?() }
}
