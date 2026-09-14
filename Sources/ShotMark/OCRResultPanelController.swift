import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import _Translation_SwiftUI

private enum OCRTab {
    case original
    case translated
}

enum OCRClipboardContent {
    static func compose(text: String, codes: [OCRDetectedCode]) -> String {
        var sections: [String] = []
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            sections.append(trimmedText)
        }
        if !codes.isEmpty {
            sections.append(codes.map(\.payload).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}

final class OCRResultPanelController: NSWindowController {
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let translateButton = NSButton(title: "翻译", target: nil, action: nil)
    private let copyAllButton = NSButton(title: "复制全部", target: nil, action: nil)
    private let tabSwitch = OCRTabSwitchView()
    private let codeRow = NSStackView()
    private let codePicker = NSPopUpButton()
    private let translationModel = OCRTranslationRequestModel()
    private var availabilityTask: Task<Void, Never>?
    private var scrollTopWithoutTabs: NSLayoutConstraint?
    private var scrollTopWithTabs: NSLayoutConstraint?
    private var scrollBottomWithoutCodes: NSLayoutConstraint?
    private var scrollBottomWithCodes: NSLayoutConstraint?
    private var escapeKeyMonitor: Any?
    private var didClose = false
    private var recognizedText: String
    private var detectedCodes: [OCRDetectedCode] = []
    private var translatedText: String?
    private var selectedTab: OCRTab = .original
    private var displayedText: String {
        switch selectedTab {
        case .original:
            return recognizedText
        case .translated:
            return translatedText ?? ""
        }
    }
    private var presentedText: String {
        let trimmed = displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, selectedTab == .original, !detectedCodes.isEmpty {
            return "未识别到可选文字，已识别下方二维码或条码。"
        }
        return displayedText
    }
    var onCopyAll: (() -> Void)?
    var onClose: (() -> Void)?

    init(text: String) {
        self.recognizedText = text

        let content = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 380, height: 286))
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10

        let window = FloatingEditorPanel(
            contentRect: content.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = content

        super.init(window: window)
        translationModel.onResult = { [weak self] result in
            self?.handleTranslationResult(result)
        }
        buildContent(in: content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func position(near rect: CGRect) {
        guard let window else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(center) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? rect
        var origin = CGPoint(x: rect.maxX + 12, y: rect.maxY - window.frame.height)
        if origin.x + window.frame.width > screenFrame.maxX {
            origin.x = rect.minX - window.frame.width - 12
        }
        if origin.y < screenFrame.minY {
            origin.y = screenFrame.minY + 12
        }
        window.setFrameOrigin(origin)
    }

    func show() {
        installEscapeKeyMonitor()
        window?.makeKeyAndOrderFront(nil)
        textView.window?.makeFirstResponder(textView)
    }

    override func close() {
        availabilityTask?.cancel()
        removeEscapeKeyMonitor()
        super.close()

        guard !didClose else { return }
        didClose = true
        onClose?()
    }

    func update(result: OCRRecognitionResult) {
        recognizedText = result.lines.map(\.text).joined(separator: "\n")
        detectedCodes = result.codes
        translatedText = nil
        selectTab(.original)
        statusLabel.stringValue = ""
        updateCodeRow()
        updateActionState()
    }

    private func buildContent(in content: NSView) {
        let title = NSTextField(labelWithString: "OCR")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        translateButton.target = self
        translateButton.action = #selector(translateText)
        translateButton.bezelStyle = .rounded
        translateButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(translateButton)

        tabSwitch.isHidden = true
        tabSwitch.translatesAutoresizingMaskIntoConstraints = false
        tabSwitch.onSelect = { [weak self] tab in
            self?.selectTab(tab)
        }
        content.addSubview(tabSwitch)

        copyAllButton.target = self
        copyAllButton.action = #selector(copyAll)
        copyAllButton.bezelStyle = .rounded
        copyAllButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(copyAllButton)

        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 312, height: 184))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        textView.frame = scrollView.bounds
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 13)
        textView.string = displayedText
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = CGSize(width: scrollView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        codeRow.orientation = .horizontal
        codeRow.alignment = .centerY
        codeRow.spacing = 8
        codeRow.isHidden = true
        codeRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(codeRow)

        let codeIcon = NSImageView(image: NSImage(
            systemSymbolName: "qrcode.viewfinder",
            accessibilityDescription: "二维码或条码"
        ) ?? NSImage())
        codeIcon.contentTintColor = .secondaryLabelColor
        codeIcon.setContentHuggingPriority(.required, for: .horizontal)
        let codeLabel = NSTextField(labelWithString: "码")
        codeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        codeLabel.textColor = .secondaryLabelColor
        codePicker.controlSize = .small
        codePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let copyCodeButton = NSButton(title: "复制码", target: self, action: #selector(copySelectedCode))
        copyCodeButton.controlSize = .small
        copyCodeButton.bezelStyle = .rounded
        copyCodeButton.toolTip = "复制当前二维码或条码内容"
        codeRow.addArrangedSubview(codeIcon)
        codeRow.addArrangedSubview(codeLabel)
        codeRow.addArrangedSubview(codePicker)
        codeRow.addArrangedSubview(copyCodeButton)

        let bridgeView = NSHostingView(rootView: OCRTranslationBridgeView(model: translationModel))
        bridgeView.translatesAutoresizingMaskIntoConstraints = false
        bridgeView.alphaValue = 0
        content.addSubview(bridgeView)

        let topWithoutTabs = scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10)
        let topWithTabs = scrollView.topAnchor.constraint(equalTo: tabSwitch.bottomAnchor, constant: 8)
        scrollTopWithoutTabs = topWithoutTabs
        scrollTopWithTabs = topWithTabs
        let bottomWithoutCodes = scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        let bottomWithCodes = scrollView.bottomAnchor.constraint(equalTo: codeRow.topAnchor, constant: -8)
        scrollBottomWithoutCodes = bottomWithoutCodes
        scrollBottomWithCodes = bottomWithCodes

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: translateButton.leadingAnchor, constant: -10),
            translateButton.trailingAnchor.constraint(equalTo: copyAllButton.leadingAnchor, constant: -8),
            translateButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            copyAllButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copyAllButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            tabSwitch.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabSwitch.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 9),
            tabSwitch.widthAnchor.constraint(equalToConstant: 164),
            tabSwitch.heightAnchor.constraint(equalToConstant: 28),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            topWithoutTabs,
            bottomWithoutCodes,
            codeRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            codeRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            codeRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            codeRow.heightAnchor.constraint(equalToConstant: 26),
            bridgeView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bridgeView.topAnchor.constraint(equalTo: content.topAnchor),
            bridgeView.widthAnchor.constraint(equalToConstant: 0),
            bridgeView.heightAnchor.constraint(equalToConstant: 0)
        ])
        updateTabState()
        updateActionState()
    }

    private func installEscapeKeyMonitor() {
        removeEscapeKeyMonitor()
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.window?.isVisible == true, event.keyCode == 53 else {
                return event
            }
            self.close()
            return nil
        }
    }

    private func removeEscapeKeyMonitor() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }

    @objc private func copyAll() {
        let content = OCRClipboardContent.compose(text: copyableDisplayedText, codes: detectedCodes)
        guard !content.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        close()
        onCopyAll?()
    }

    @objc private func copySelectedCode() {
        let index = codePicker.indexOfSelectedItem
        guard detectedCodes.indices.contains(index) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detectedCodes[index].payload, forType: .string)
        statusLabel.stringValue = "码内容已复制"
    }

    @objc private func translateText() {
        let source = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canTranslate(source) else { return }

        availabilityTask?.cancel()
        statusLabel.stringValue = "准备翻译..."
        translateButton.isEnabled = false

        let sourceLanguage = sourceLanguage(for: source)
        let target = targetLanguage(for: sourceLanguage, text: source)
        availabilityTask = Task { [weak self] in
            let status: LanguageAvailability.Status
            if let sourceLanguage {
                status = await LanguageAvailability().status(from: sourceLanguage, to: target)
            } else {
                do {
                    status = try await LanguageAvailability().status(for: source, to: target)
                } catch {
                    await MainActor.run {
                        self?.handleTranslationResult(.failure(error))
                    }
                    return
                }
            }

            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                switch status {
                case .installed, .supported:
                    self.statusLabel.stringValue = status == .installed ? "翻译中..." : "准备语言包..."
                    self.translationModel.requestTranslation(text: source, source: sourceLanguage, target: target)
                case .unsupported:
                    self.handleTranslationResult(.failure(OCRTranslationError.unsupportedPair))
                @unknown default:
                    self.handleTranslationResult(.failure(OCRTranslationError.unsupportedPair))
                }
            }
        }
    }

    private func handleTranslationResult(_ result: Result<String, Error>) {
        switch result {
        case .success(let translation):
            translatedText = translation
            selectTab(.translated)
            statusLabel.stringValue = "已翻译"
        case .failure(let error):
            statusLabel.stringValue = "翻译失败：\(error.localizedDescription)"
        }
        updateTabState()
        updateActionState()
    }

    private func updateActionState() {
        translateButton.isEnabled = canTranslate(recognizedText)
        copyAllButton.isEnabled = !OCRClipboardContent.compose(
            text: copyableDisplayedText,
            codes: detectedCodes
        ).isEmpty
    }

    private var copyableDisplayedText: String {
        canCopyText(displayedText) ? displayedText : ""
    }

    private func updateCodeRow() {
        codePicker.removeAllItems()
        for (index, code) in detectedCodes.enumerated() {
            let preview = code.payload.replacingOccurrences(of: "\n", with: " ")
            let shortened = preview.count > 34 ? String(preview.prefix(33)) + "…" : preview
            codePicker.addItem(withTitle: "\(code.displayName) \(index + 1) · \(shortened)")
            codePicker.lastItem?.toolTip = code.payload
        }
        let hasCodes = !detectedCodes.isEmpty
        codeRow.isHidden = !hasCodes
        scrollBottomWithoutCodes?.isActive = !hasCodes
        scrollBottomWithCodes?.isActive = hasCodes
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func canTranslate(_ value: String) -> Bool {
        canCopyText(value)
    }

    private func canCopyText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != "OCR 识别中..." && trimmed != "未识别到文字" && !trimmed.hasPrefix("OCR 失败")
    }

    private func sourceLanguage(for value: String) -> Locale.Language? {
        if containsChineseText(value) {
            return Locale.Language(identifier: "zh")
        }

        if value.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil {
            return Locale.Language(identifier: "en")
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(value)
        guard let language = recognizer.dominantLanguage else { return nil }
        switch language {
        case .english:
            return Locale.Language(identifier: "en")
        case .simplifiedChinese, .traditionalChinese:
            return Locale.Language(identifier: "zh")
        case .japanese:
            return Locale.Language(identifier: "ja")
        case .korean:
            return Locale.Language(identifier: "ko")
        case .french:
            return Locale.Language(identifier: "fr")
        case .german:
            return Locale.Language(identifier: "de")
        case .spanish:
            return Locale.Language(identifier: "es")
        case .italian:
            return Locale.Language(identifier: "it")
        case .portuguese:
            return Locale.Language(identifier: "pt")
        case .russian:
            return Locale.Language(identifier: "ru")
        case .arabic:
            return Locale.Language(identifier: "ar-AE")
        case .hindi:
            return Locale.Language(identifier: "hi")
        case .thai:
            return Locale.Language(identifier: "th")
        case .turkish:
            return Locale.Language(identifier: "tr")
        case .dutch:
            return Locale.Language(identifier: "nl")
        case .polish:
            return Locale.Language(identifier: "pl")
        case .ukrainian:
            return Locale.Language(identifier: "uk")
        case .vietnamese:
            return Locale.Language(identifier: "vi")
        case .indonesian:
            return Locale.Language(identifier: "id")
        default:
            return nil
        }
    }

    private func targetLanguage(for sourceLanguage: Locale.Language?, text: String) -> Locale.Language {
        if let sourceLanguage, sourceLanguage.minimalIdentifier.hasPrefix("zh") {
            return Locale.Language(identifier: "en")
        }
        return containsChineseText(text) ? Locale.Language(identifier: "en") : Locale.Language(identifier: "zh")
    }

    private func containsChineseText(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
                (0x3400...0x4DBF).contains(Int(scalar.value)) ||
                (0xF900...0xFAFF).contains(Int(scalar.value))
        }
    }

    private func selectTab(_ tab: OCRTab) {
        selectedTab = tab == .translated && translatedText == nil ? .original : tab
        tabSwitch.selectedTab = selectedTab
        textView.string = presentedText
        textView.scrollToBeginningOfDocument(nil)
        updateTabState()
    }

    private func updateTabState() {
        let showTabs = translatedText != nil
        tabSwitch.isHidden = !showTabs
        scrollTopWithoutTabs?.isActive = !showTabs
        scrollTopWithTabs?.isActive = showTabs
        tabSwitch.selectedTab = selectedTab
        window?.contentView?.layoutSubtreeIfNeeded()
    }
}

enum OCRTranslationError: LocalizedError {
    case unsupportedPair

    var errorDescription: String? {
        switch self {
        case .unsupportedPair:
            return "当前语言方向暂不支持，或系统翻译语言包不可用。"
        }
    }
}

private final class OCRTabSwitchView: NSView {
    var selectedTab: OCRTab = .original {
        didSet { needsDisplay = true }
    }
    var onSelect: ((OCRTab) -> Void)?

    private var originalFrame: CGRect {
        CGRect(x: 3, y: 3, width: (bounds.width - 6) / 2, height: bounds.height - 6)
    }

    private var translatedFrame: CGRect {
        CGRect(x: originalFrame.maxX, y: 3, width: (bounds.width - 6) / 2, height: bounds.height - 6)
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
        onSelect?(translatedFrame.contains(point) ? .translated : .original)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.20).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        background.lineWidth = 1
        background.stroke()

        let selectedFrame = selectedTab == .original ? originalFrame : translatedFrame
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: selectedFrame, xRadius: 6, yRadius: 6).fill()

        drawTitle("原文", in: originalFrame, selected: selectedTab == .original)
        drawTitle("翻译后文本", in: translatedFrame, selected: selectedTab == .translated)
    }

    private func drawTitle(_ title: String, in rect: CGRect, selected: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(selected ? 0.95 : 0.56)
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

final class OCRTranslationRequestModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var sourceText = ""
    var onResult: ((Result<String, Error>) -> Void)?

    func requestTranslation(text: String, source: Locale.Language?, target: Locale.Language) {
        sourceText = text
        var nextConfiguration = TranslationSession.Configuration(source: nil, target: target)
        nextConfiguration.source = source
        nextConfiguration.invalidate()
        configuration = nextConfiguration
    }

    @MainActor
    func finish(_ result: Result<String, Error>) {
        onResult?(result)
    }
}

struct OCRTranslationBridgeView: View {
    @ObservedObject var model: OCRTranslationRequestModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.configuration) { session in
                let sourceText = model.sourceText
                do {
                    try await session.prepareTranslation()
                    let response = try await session.translate(sourceText)
                    model.finish(.success(response.targetText))
                } catch {
                    model.finish(.failure(error))
                }
            }
    }
}
