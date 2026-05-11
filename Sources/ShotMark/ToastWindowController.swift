import AppKit

final class ToastWindowController: NSWindowController {
    static func show(message: String) {
        let toast = ToastWindowController(message: message)
        toast.showWindow(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            toast.close()
        }
    }

    init(message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 220, height: 46))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.addSubview(label)

        let window = NSPanel(
            contentRect: content.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = content

        if let screen = NSScreen.main {
            window.setFrameOrigin(CGPoint(
                x: screen.visibleFrame.midX - window.frame.width / 2,
                y: screen.visibleFrame.minY + 80
            ))
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
