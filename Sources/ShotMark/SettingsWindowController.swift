import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    init() {
        let root = SettingsView()
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "ShotMark 设置"
        window.setContentSize(CGSize(width: 480, height: 420))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct SettingsView: View {
    @State private var screenRecordingAccess = PermissionService.hasScreenRecordingAccess
    @State private var accessibilityAccess = PermissionService.hasAccessibilityAccess
    @State private var microphoneAccess = PermissionService.hasMicrophoneAccess
    @State private var isCheckingScreenRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ShotMark")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("快捷键：Option + A")
                Text("保存快捷键：Space")
                Text("录制停止：Option + A、状态栏菜单或顶部停止条")
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
    }
}
