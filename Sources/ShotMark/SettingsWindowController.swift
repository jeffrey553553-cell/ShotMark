import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    init(
        onShortcutChange: @escaping (GlobalShortcut) throws -> Void,
        onShortcutRecordingStateChange: @escaping (Bool) -> Void
    ) {
        let root = SettingsView(
            onShortcutChange: onShortcutChange,
            onShortcutRecordingStateChange: onShortcutRecordingStateChange
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "ShotMark 设置"
        window.setContentSize(CGSize(width: 520, height: 500))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct SettingsView: View {
    let onShortcutChange: (GlobalShortcut) throws -> Void
    let onShortcutRecordingStateChange: (Bool) -> Void

    @State private var screenRecordingAccess = PermissionService.hasScreenRecordingAccess
    @State private var accessibilityAccess = PermissionService.hasAccessibilityAccess
    @State private var microphoneAccess = PermissionService.hasMicrophoneAccess
    @State private var isCheckingScreenRecording = false
    @State private var shortcut = AppSettings.shared.shortcut
    @State private var isRecordingShortcut = false
    @State private var shortcutMessage = "点击修改后按下新的截图快捷键。"
    @State private var shortcutMessageIsError = false
    @State private var shortcutRecorderMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ShotMark")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                shortcutSection
                Text("保存快捷键：Space")
                Text("录制停止：\(shortcut.displayName)、状态栏菜单或顶部停止条")
                Text("默认保存目录：Downloads")
            }
            .font(.system(size: 13))

            Divider()

            Text("权限修改后，请退出并重新打开 ShotMark。macOS 会把屏幕录制权限缓存到当前运行中的 App。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(
                title: "屏幕录制权限",
                isGranted: screenRecordingAccess,
                isChecking: isCheckingScreenRecording,
                actionTitle: "请求权限"
            ) {
                PermissionService.requestScreenRecordingAccess()
                refresh()
            }

            permissionRow(
                title: "辅助功能权限",
                isGranted: accessibilityAccess,
                isChecking: false,
                actionTitle: "请求权限"
            ) {
                PermissionService.requestAccessibilityAccess()
                refresh()
            }

            permissionRow(
                title: "麦克风权限",
                isGranted: microphoneAccess,
                isChecking: false,
                actionTitle: "请求权限"
            ) {
                PermissionService.requestMicrophoneAccess { _ in
                    DispatchQueue.main.async {
                        refresh()
                    }
                }
            }

            HStack(spacing: 10) {
                Button("打开屏幕录制设置") {
                    PermissionService.openScreenRecordingSettings()
                }

                Button("打开辅助功能设置") {
                    PermissionService.openAccessibilitySettings()
                }

                Button("打开麦克风设置") {
                    PermissionService.openMicrophoneSettings()
                }
            }

            HStack(spacing: 10) {
                Button("重新检查") {
                    refresh()
                }

                Button("退出 ShotMark") {
                    NSApp.terminate(nil)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: refresh)
        .onDisappear {
            stopShortcutRecording(reactivateHotKey: true)
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("截图快捷键")
                Spacer()
                Text(isRecordingShortcut ? "请按下新的快捷键" : shortcut.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(minWidth: 118)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isRecordingShortcut ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isRecordingShortcut ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.20), lineWidth: 1)
                    )

                Button(isRecordingShortcut ? "取消" : "修改") {
                    isRecordingShortcut ? stopShortcutRecording(reactivateHotKey: true) : startShortcutRecording()
                }

                Button("恢复默认") {
                    applyShortcut(.defaultShortcut, successMessage: "已恢复默认快捷键 \(GlobalShortcut.defaultShortcut.displayName)")
                }
                .disabled(shortcut == .defaultShortcut && !isRecordingShortcut)
            }

            Text(shortcutMessage)
                .font(.system(size: 12))
                .foregroundStyle(shortcutMessageIsError ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(
        title: String,
        isGranted: Bool,
        isChecking: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(isChecking ? "检查中..." : (isGranted ? "已允许" : "未允许或需重启"))
                .foregroundColor(isChecking ? Color.secondary : (isGranted ? Color.green : Color.orange))
                .font(.system(size: 12, weight: .semibold))
            Button(actionTitle, action: action)
        }
    }

    private func refresh() {
        isCheckingScreenRecording = true
        screenRecordingAccess = false
        PermissionService.verifyScreenRecordingAccess { isGranted in
            DispatchQueue.main.async {
                screenRecordingAccess = isGranted
                isCheckingScreenRecording = false
            }
        }
        accessibilityAccess = PermissionService.hasAccessibilityAccess
        microphoneAccess = PermissionService.hasMicrophoneAccess
        shortcut = AppSettings.shared.shortcut
    }

    private func startShortcutRecording() {
        stopShortcutRecording(reactivateHotKey: false)
        isRecordingShortcut = true
        shortcutMessage = "按下新的组合键；Esc 取消，Delete 恢复默认。"
        shortcutMessageIsError = false
        onShortcutRecordingStateChange(true)

        shortcutRecorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleShortcutRecordingEvent(event)
            return nil
        }
    }

    private func stopShortcutRecording(reactivateHotKey: Bool) {
        if let shortcutRecorderMonitor {
            NSEvent.removeMonitor(shortcutRecorderMonitor)
            self.shortcutRecorderMonitor = nil
        }
        if isRecordingShortcut {
            isRecordingShortcut = false
            if reactivateHotKey {
                onShortcutRecordingStateChange(false)
            }
        }
    }

    private func handleShortcutRecordingEvent(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopShortcutRecording(reactivateHotKey: true)
            shortcutMessage = "已取消修改，当前快捷键仍是 \(shortcut.displayName)。"
            shortcutMessageIsError = false
            return
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            applyShortcut(.defaultShortcut, successMessage: "已恢复默认快捷键 \(GlobalShortcut.defaultShortcut.displayName)")
            return
        }

        guard let nextShortcut = GlobalShortcut(event: event) else {
            shortcutMessage = "无法识别这个按键，请换一个组合键。"
            shortcutMessageIsError = true
            return
        }

        if let reason = nextShortcut.invalidReason {
            shortcutMessage = reason
            shortcutMessageIsError = true
            return
        }

        applyShortcut(nextShortcut, successMessage: "已保存截图快捷键 \(nextShortcut.displayName)")
    }

    private func applyShortcut(_ nextShortcut: GlobalShortcut, successMessage: String) {
        do {
            try onShortcutChange(nextShortcut)
            shortcut = AppSettings.shared.shortcut
            stopShortcutRecording(reactivateHotKey: false)
            shortcutMessage = successMessage
            shortcutMessageIsError = false
        } catch {
            shortcutMessage = error.localizedDescription
            shortcutMessageIsError = true
            onShortcutRecordingStateChange(true)
        }
    }
}
