import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    init(
        onShortcutChange: @escaping (GlobalShortcut) throws -> Void,
        onShortcutRecordingStateChange: @escaping (Bool) -> Void,
        onCheckForUpdates: @escaping () -> Void = {},
        currentVersion: String = AppMetadata.currentVersion
    ) {
        let root = SettingsView(
            onShortcutChange: onShortcutChange,
            onShortcutRecordingStateChange: onShortcutRecordingStateChange,
            onCheckForUpdates: onCheckForUpdates,
            currentVersion: currentVersion
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "ShotMark 设置"
        window.setContentSize(CGSize(width: 560, height: 580))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = CGSize(width: 520, height: 500)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(nil)
    }
}

struct SettingsView: View {
    let onShortcutChange: (GlobalShortcut) throws -> Void
    let onShortcutRecordingStateChange: (Bool) -> Void
    let onCheckForUpdates: () -> Void
    let currentVersion: String

    @State private var screenRecordingAccess = PermissionService.hasScreenRecordingAccess
    @State private var accessibilityAccess = PermissionService.hasAccessibilityAccess
    @State private var microphonePermission = PermissionService.microphonePermissionState
    @State private var isCheckingScreenRecording = false
    @State private var shortcut = AppSettings.shared.shortcut
    @State private var isRecordingShortcut = false
    @State private var shortcutMessage = "点击修改后按下新的截图快捷键。"
    @State private var shortcutMessageIsError = false
    @State private var shortcutRecorderMonitor: Any?
    @State private var longScreenshotReportCount = 0
    @State private var diagnosticsMessage = "仅在本机保留最近 50 次长截图的尺寸、耗时和拼接统计，不保存截图内容或应用信息。"
    @State private var automaticallyChecksForUpdates = AppSettings.shared.automaticallyChecksForUpdates

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ShotMark")
                    .font(.title2.bold())

                SettingsSection(title: "快捷键") {
                    VStack(alignment: .leading, spacing: 10) {
                        shortcutSection
                        Text("保存：Space")
                        Text("图片固定保存为 PNG，目录为 ~/Downloads")
                        Text("录制：顶部控制条或状态栏可暂停、继续和停止；\(shortcut.displayName) 停止")
                    }
                    .font(.system(size: 13))
                    .padding(.vertical, 4)
                }

                SettingsSection(title: "更新") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Toggle("自动检查更新", isOn: Binding(
                                get: { automaticallyChecksForUpdates },
                                set: { value in
                                    automaticallyChecksForUpdates = value
                                    AppSettings.shared.automaticallyChecksForUpdates = value
                                }
                            ))
                            .toggleStyle(.checkbox)
                            Spacer()
                            Button("检查更新") {
                                onCheckForUpdates()
                            }
                        }

                        Text("当前版本 \(currentVersion)。自动检查最多每天一次；发现新版后打开 ShotMark 官方 GitHub Release 页面。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }

                SettingsSection(title: "权限") {
                    VStack(alignment: .leading, spacing: 12) {
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
                            title: "辅助功能权限（窗口识别校准）",
                            isGranted: accessibilityAccess,
                            isChecking: false,
                            actionTitle: "请求权限"
                        ) {
                            PermissionService.requestAccessibilityAccess()
                            refresh()
                        }
                        Text("未开启时仍可截图；开启后智能选区会用系统窗口位置做二次校准。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        microphonePermissionRow

                        HStack(spacing: 10) {
                            Button("屏幕录制设置") {
                                PermissionService.openScreenRecordingSettings()
                            }

                            Button("辅助功能设置") {
                                PermissionService.openAccessibilitySettings()
                            }

                            Button("麦克风设置") {
                                PermissionService.openMicrophoneSettings()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                SettingsSection(title: "诊断与隐私") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(diagnosticsMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Text("长截图诊断：\(longScreenshotReportCount) 条")
                                .font(.system(size: 13))
                            Spacer()
                            Button("复制诊断摘要") {
                                copyLongScreenshotDiagnostics()
                            }
                            .disabled(longScreenshotReportCount == 0)

                            Button("清除") {
                                LongScreenshotQualityReportStore.shared.clear()
                                longScreenshotReportCount = 0
                                diagnosticsMessage = "长截图诊断数据已清除。"
                            }
                            .disabled(longScreenshotReportCount == 0)
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack(spacing: 10) {
                    Button("重新检查权限") {
                        refresh()
                    }

                    Button("退出 ShotMark") {
                        NSApp.terminate(nil)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .buttonStyle(SettingsSubtleButtonStyle())
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var microphonePermissionRow: some View {
        HStack {
            Text("麦克风权限")
            Spacer()
            Text(microphonePermission.statusText)
                .foregroundColor(microphonePermission.isAuthorized ? Color.green : Color.orange)
                .font(.system(size: 12, weight: .semibold))

            switch microphonePermission {
            case .authorized:
                Button("已允许") {}
                    .disabled(true)
            case .notDetermined:
                Button("请求权限") {
                    PermissionService.requestMicrophoneAccess { _ in
                        DispatchQueue.main.async {
                            refresh()
                        }
                    }
                }
            case .denied:
                Button("打开设置") {
                    PermissionService.openMicrophoneSettings()
                }
            case .restricted:
                Button("不可更改") {}
                    .disabled(true)
            case .unknown:
                Button("重新检查") {
                    refresh()
                }
            }
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
        microphonePermission = PermissionService.microphonePermissionState
        shortcut = AppSettings.shared.shortcut
        longScreenshotReportCount = LongScreenshotQualityReportStore.shared.reports().count
        automaticallyChecksForUpdates = AppSettings.shared.automaticallyChecksForUpdates
    }

    private func copyLongScreenshotDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(LongScreenshotQualityReportStore.shared.summaryText(), forType: .string)
        diagnosticsMessage = "诊断摘要已复制，其中不包含截图内容、识别文字、应用名或文件路径。"
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

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
        }
    }
}

private struct SettingsSubtleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(
                isEnabled
                    ? Color.primary.opacity(0.86)
                    : Color.secondary.opacity(0.48)
            )
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        Color.primary.opacity(
                            configuration.isPressed ? 0.13 : 0.07
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(isEnabled ? 0.12 : 0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}
