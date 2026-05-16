import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var primaryMenuItem: NSMenuItem?
    private var screenRecordingStatusMenuItem: NSMenuItem?
    private var accessibilityStatusMenuItem: NSMenuItem?
    private var microphoneStatusMenuItem: NSMenuItem?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var hotKeyService: HotKeyService?
    private var coordinator: ScreenshotCoordinator?
    private var settingsWindowController: SettingsWindowController?
    private var shortcutObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = ScreenshotCoordinator()
        coordinator.onRecordingStateChanged = { [weak self] state in
            self?.updateRecordingState(state)
        }
        self.coordinator = coordinator
        configureStatusItem()

        configureHotKey()
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .shotMarkShortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateShortcutTitles()
        }

        if CommandLine.arguments.contains("--demo") {
            coordinator.showDemo()
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "ShotMark"

        let menu = NSMenu()
        menu.delegate = self
        let primaryItem = NSMenuItem(title: primaryMenuTitle(), action: #selector(primaryActionMenuItem), keyEquivalent: "")
        menu.addItem(primaryItem)
        menu.addItem(.separator())
        let screenRecordingStatusItem = NSMenuItem(title: "屏幕录制权限：检查中", action: nil, keyEquivalent: "")
        screenRecordingStatusItem.isEnabled = false
        menu.addItem(screenRecordingStatusItem)
        let accessibilityStatusItem = NSMenuItem(title: "辅助功能权限：检查中", action: nil, keyEquivalent: "")
        accessibilityStatusItem.isEnabled = false
        menu.addItem(accessibilityStatusItem)
        let microphoneStatusItem = NSMenuItem(title: "麦克风权限：检查中", action: nil, keyEquivalent: "")
        microphoneStatusItem.isEnabled = false
        menu.addItem(microphoneStatusItem)
        menu.addItem(NSMenuItem(title: "打开屏幕录制设置...", action: #selector(openScreenRecordingSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开辅助功能设置...", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开麦克风设置...", action: #selector(openMicrophoneSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "权限与设置...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Demo 预览", action: #selector(openDemo), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 ShotMark（权限变更后重启）", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        primaryMenuItem = primaryItem
        screenRecordingStatusMenuItem = screenRecordingStatusItem
        accessibilityStatusMenuItem = accessibilityStatusItem
        microphoneStatusMenuItem = microphoneStatusItem
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionMenuItems()
    }

    @objc private func primaryActionMenuItem() {
        performPrimaryAction()
    }

    private func performPrimaryAction() {
        coordinator?.handlePrimaryShortcut()
    }

    @objc private func openDemo() {
        coordinator?.showDemo()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                onShortcutChange: { [weak self] shortcut in
                    guard let self else { return }
                    try self.setPrimaryShortcut(shortcut)
                },
                onShortcutRecordingStateChange: { [weak self] isRecording in
                    self?.setShortcutRecorderActive(isRecording)
                }
            )
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openScreenRecordingSettings() {
        PermissionService.openScreenRecordingSettings()
    }

    @objc private func openAccessibilitySettings() {
        PermissionService.openAccessibilitySettings()
    }

    @objc private func openMicrophoneSettings() {
        PermissionService.openMicrophoneSettings()
    }

    @objc private func quit() {
        if coordinator?.hasActiveRecordingSession == true {
            coordinator?.stopRecording {
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.terminate(nil)
    }

    private func updateRecordingState(_ state: RecordingUIState) {
        recordingTimer?.invalidate()
        recordingTimer = nil

        switch state {
        case .idle:
            recordingStartedAt = nil
            statusItem?.button?.title = "ShotMark"
            primaryMenuItem?.title = primaryMenuTitle()
            primaryMenuItem?.isEnabled = true
        case .starting:
            recordingStartedAt = nil
            statusItem?.button?.title = "■"
            primaryMenuItem?.title = "正在开始录制..."
            primaryMenuItem?.isEnabled = false
        case .recording(let startedAt):
            recordingStartedAt = startedAt
            primaryMenuItem?.title = recordingMenuTitle()
            primaryMenuItem?.isEnabled = true
            updateRecordingTimerTitle()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateRecordingTimerTitle()
            }
            recordingTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        case .stopping:
            recordingStartedAt = nil
            statusItem?.button?.title = "■"
            primaryMenuItem?.title = "正在保存录制..."
            primaryMenuItem?.isEnabled = false
        }
    }

    private func updateRecordingTimerTitle() {
        guard let recordingStartedAt else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        statusItem?.button?.title = String(format: "■%02d:%02d", minutes, seconds)
    }

    private func configureHotKey() {
        let hotKeyService = HotKeyService()
        hotKeyService.onPressed = { [weak self] in
            self?.performPrimaryAction()
        }
        self.hotKeyService = hotKeyService

        do {
            try hotKeyService.register(shortcut: AppSettings.shared.shortcut)
        } catch {
            let fallback = GlobalShortcut.defaultShortcut
            AppSettings.shared.setShortcut(fallback)
            do {
                try hotKeyService.register(shortcut: fallback)
            } catch {
                showError(title: "快捷键注册失败", message: error.localizedDescription)
            }
        }
    }

    private func setPrimaryShortcut(_ shortcut: GlobalShortcut) throws {
        let previous = AppSettings.shared.shortcut

        do {
            try hotKeyService?.register(shortcut: shortcut)
            if shortcut != previous {
                AppSettings.shared.setShortcut(shortcut)
            }
            updateShortcutTitles()
        } catch {
            try? hotKeyService?.register(shortcut: previous)
            throw error
        }
    }

    private func setShortcutRecorderActive(_ isRecording: Bool) {
        if isRecording {
            hotKeyService?.unregisterHotKey()
            return
        }

        do {
            try hotKeyService?.register(shortcut: AppSettings.shared.shortcut)
        } catch {
            showError(title: "快捷键注册失败", message: error.localizedDescription)
        }
    }

    private func updateShortcutTitles() {
        guard let primaryMenuItem else { return }
        switch coordinator?.currentRecordingState ?? .idle {
        case .idle:
            primaryMenuItem.title = primaryMenuTitle()
        case .recording:
            primaryMenuItem.title = recordingMenuTitle()
        case .starting, .stopping:
            break
        }
    }

    private func primaryMenuTitle() -> String {
        "截图  \(AppSettings.shared.shortcutDescription)"
    }

    private func recordingMenuTitle() -> String {
        "■ 停止录制  \(AppSettings.shared.shortcutDescription)"
    }

    private func updatePermissionMenuItems() {
        screenRecordingStatusMenuItem?.title = "屏幕录制权限：检查中..."
        PermissionService.verifyScreenRecordingAccess { [weak self] isGranted in
            DispatchQueue.main.async {
                self?.screenRecordingStatusMenuItem?.title = isGranted
                    ? "屏幕录制权限：已允许"
                    : "屏幕录制权限：未允许或需重启"
            }
        }
        accessibilityStatusMenuItem?.title = PermissionService.hasAccessibilityAccess
            ? "辅助功能权限：已允许"
            : "辅助功能权限：未允许"
        microphoneStatusMenuItem?.title = PermissionService.hasMicrophoneAccess
            ? "麦克风权限：已允许"
            : "麦克风权限：未允许"
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    deinit {
        if let shortcutObserver {
            NotificationCenter.default.removeObserver(shortcutObserver)
        }
    }
}
