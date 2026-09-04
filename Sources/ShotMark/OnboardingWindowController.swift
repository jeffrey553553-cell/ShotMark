import AppKit
import SwiftUI

struct OnboardingPermissionSnapshot: Equatable {
    var screenRecordingGranted: Bool
    var accessibilityGranted: Bool

    static var current: OnboardingPermissionSnapshot {
        OnboardingPermissionSnapshot(
            screenRecordingGranted: PermissionService.hasScreenRecordingAccess,
            accessibilityGranted: PermissionService.hasAccessibilityAccess
        )
    }
}

final class OnboardingWindowController: NSWindowController {
    init(
        shortcut: GlobalShortcut,
        initialPermissions: OnboardingPermissionSnapshot = .current,
        appIcon: NSImage = NSApplication.shared.applicationIconImage,
        onStartCapture: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onRelaunch: @escaping () -> Void = { ApplicationRelauncher.relaunch() }
    ) {
        let root = OnboardingView(
            shortcut: shortcut,
            initialPermissions: initialPermissions,
            appIcon: appIcon,
            onStartCapture: onStartCapture,
            onDismiss: onDismiss,
            onRelaunch: onRelaunch
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "设置 ShotMark"
        window.setContentSize(CGSize(width: 610, height: 470))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct OnboardingView: View {
    let shortcut: GlobalShortcut
    let appIcon: NSImage
    let onStartCapture: () -> Void
    let onDismiss: () -> Void
    let onRelaunch: () -> Void

    @State private var screenRecordingGranted: Bool
    @State private var accessibilityGranted: Bool
    @State private var hasRequestedScreenRecording = false
    @State private var isCheckingScreenRecording = false

    init(
        shortcut: GlobalShortcut,
        initialPermissions: OnboardingPermissionSnapshot,
        appIcon: NSImage,
        onStartCapture: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onRelaunch: @escaping () -> Void
    ) {
        self.shortcut = shortcut
        self.appIcon = appIcon
        self.onStartCapture = onStartCapture
        self.onDismiss = onDismiss
        self.onRelaunch = onRelaunch
        _screenRecordingGranted = State(initialValue: initialPermissions.screenRecordingGranted)
        _accessibilityGranted = State(initialValue: initialPermissions.accessibilityGranted)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 22)

            Divider()

            VStack(spacing: 0) {
                permissionRow(
                    icon: "rectangle.on.rectangle",
                    title: "屏幕录制",
                    detail: "用于读取你框选的屏幕区域。ShotMark 不会在后台持续录制。",
                    status: screenRecordingStatus,
                    isGranted: screenRecordingGranted,
                    isRequired: true
                ) {
                    screenRecordingActions
                }

                Divider().padding(.leading, 58)

                permissionRow(
                    icon: "macwindow.on.rectangle",
                    title: "辅助功能",
                    detail: "可选。用于校准窗口边界，让智能选区在多屏环境更准确。",
                    status: accessibilityGranted ? "已允许" : "可稍后开启",
                    isGranted: accessibilityGranted,
                    isRequired: false
                ) {
                    if accessibilityGranted {
                        Label("已允许", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("提升窗口识别") {
                            PermissionService.requestAccessibilityAccess()
                            refreshPermissions()
                        }
                    }
                }

                Divider().padding(.leading, 58)

                HStack(spacing: 16) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("截图快捷键")
                            .font(.system(size: 14, weight: .semibold))
                        Text("设置完成后，在任意 App 中按下快捷键即可开始框选。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Text(shortcut.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                }
                .padding(.vertical, 18)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 10)

            if hasRequestedScreenRecording && !screenRecordingGranted {
                Label("如果系统设置中已经开启权限，请重启 ShotMark 让 macOS 刷新授权。", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
        }
        .frame(width: 610, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(OnboardingButtonStyle())
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 5) {
                Text("设置 ShotMark")
                    .font(.system(size: 22, weight: .bold))
                Text("完成一项必要权限，随后可以直接试拍第一张截图。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func permissionRow<Actions: View>(
        icon: String,
        title: String,
        detail: String,
        status: String,
        isGranted: Bool,
        isRequired: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isGranted ? Color.green : Color.secondary)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(isRequired ? "必需" : "可选")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isRequired ? Color.orange : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(status, systemImage: isGranted ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isGranted ? Color.green : Color.secondary)
            }

            Spacer(minLength: 12)
            actions()
        }
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var screenRecordingActions: some View {
        if screenRecordingGranted {
            Label("已允许", systemImage: "checkmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        } else if hasRequestedScreenRecording {
            VStack(alignment: .trailing, spacing: 7) {
                Button(isCheckingScreenRecording ? "检查中..." : "重新检查") {
                    refreshPermissions()
                }
                .disabled(isCheckingScreenRecording)
                Button("打开系统设置") {
                    PermissionService.openScreenRecordingSettings()
                }
            }
        }
    }

    private var screenRecordingStatus: String {
        if isCheckingScreenRecording { return "正在检查" }
        return screenRecordingGranted ? "已允许" : "尚未允许"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("以后可从状态栏菜单重新打开设置指南")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            Button("稍后") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            if screenRecordingGranted {
                Button("开始截图") {
                    onStartCapture()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            } else if hasRequestedScreenRecording {
                Button("重启 ShotMark") {
                    onRelaunch()
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
            } else {
                Button("允许屏幕录制") {
                    hasRequestedScreenRecording = true
                    PermissionService.requestScreenRecordingAccess()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        refreshPermissions()
                    }
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
            }
        }
    }

    private func refreshPermissions() {
        accessibilityGranted = PermissionService.hasAccessibilityAccess
        isCheckingScreenRecording = true
        PermissionService.verifyScreenRecordingAccess { isGranted in
            DispatchQueue.main.async {
                screenRecordingGranted = isGranted
                isCheckingScreenRecording = false
            }
        }
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.88 : 0.42))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.13 : 0.07),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(isEnabled ? 0.12 : 0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(
                Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
    }
}
