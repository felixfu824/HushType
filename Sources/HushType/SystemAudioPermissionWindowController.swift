import AppKit
import SwiftUI

@MainActor
final class SystemAudioPermissionWindowController: NSWindowController, NSWindowDelegate {
    private static var active: SystemAudioPermissionWindowController?

    private let onOpenSettings: () -> Void
    private let onRestart: () -> Void
    private let onResetStaleEntries: () -> Void
    private let onCancel: () -> Void

    static func present(
        onOpenSettings: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onResetStaleEntries: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        if let active {
            active.window?.orderFrontRegardless()
            active.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SystemAudioPermissionWindowController(
            onOpenSettings: onOpenSettings,
            onRestart: onRestart,
            onResetStaleEntries: onResetStaleEntries,
            onCancel: onCancel
        )
        active = controller
        controller.present()
    }

    private init(
        onOpenSettings: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onResetStaleEntries: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onOpenSettings = onOpenSettings
        self.onRestart = onRestart
        self.onResetStaleEntries = onResetStaleEntries
        self.onCancel = onCancel

        let model = SystemAudioPermissionViewModel()
        let view = SystemAudioPermissionView(
            model: model,
            appIcon: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath),
            onOpenSettings: {
                model.markSettingsOpened()
                onOpenSettings()
            },
            onRestart: onRestart,
            onResetStaleEntries: {
                model.markReset()
                onResetStaleEntries()
            },
            onCancel: onCancel
        )
        let hosting = NSHostingController(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Enable System Audio"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.canHide = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hosting

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        PermissionSettingsGuidePanel.shared.dismiss()
        onCancel()
        Self.active = nil
    }

    static func dismissActive() {
        PermissionSettingsGuidePanel.shared.dismiss()
        active?.window?.delegate = nil
        active?.close()
        active = nil
    }
}

@MainActor
final class SystemAudioPermissionViewModel: ObservableObject {
    @Published var settingsOpened = false
    @Published var didResetStaleEntries = false
    @Published var troubleshootingExpanded = false

    func markSettingsOpened() {
        settingsOpened = true
    }

    func markReset() {
        didResetStaleEntries = true
        settingsOpened = true
    }
}

private struct SystemAudioPermissionView: View {
    @ObservedObject var model: SystemAudioPermissionViewModel
    let appIcon: NSImage
    let onOpenSettings: () -> Void
    let onRestart: () -> Void
    let onResetStaleEntries: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            permissionRow
            guidance
            troubleshooting
            footer
        }
        .padding(24)
        .frame(width: 500)
        .background(VisualEffectBlur(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)

            VStack(spacing: 5) {
                Text("Enable System Audio for Live Caption")
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text("Allow HushType to caption audio from apps like Zoom, Chrome, and Safari.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var permissionRow: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.14))
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text("Screen & System Audio Recording")
                    .font(.system(size: 14, weight: .semibold))
                Text("Required by macOS for system-audio capture.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            statusPill
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var statusPill: some View {
        Text(model.settingsOpened ? "Restart needed" : "Needs permission")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(model.settingsOpened ? .orange : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(model.settingsOpened ? Color.orange.opacity(0.14) : Color.primary.opacity(0.08))
            )
    }

    @ViewBuilder
    private var guidance: some View {
        if model.settingsOpened {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text("After turning on HushType in System Settings, restart the app so macOS applies the permission.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)
        }
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.troubleshootingExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.troubleshootingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Having trouble?")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if model.troubleshootingExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use this if HushType is missing or appears twice in System Settings.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Reset stale permission entries") {
                        onResetStaleEntries()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if model.didResetStaleEntries {
                        Label("Reset complete. Turn on HushType in System Settings, then restart.", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                onCancel()
                SystemAudioPermissionWindowController.dismissActive()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if model.settingsOpened {
                Button("Open System Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.bordered)
            }

            Button(model.settingsOpened ? "Restart HushType" : "Open System Settings") {
                if model.settingsOpened {
                    onRestart()
                } else {
                    onOpenSettings()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}
