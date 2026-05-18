import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class OnboardingSetupWindowController: NSWindowController, NSWindowDelegate {
    static let panelWidth: CGFloat = 660
    static let panelHeight: CGFloat = 580

    enum Result {
        case restart
        case quit
    }

    private static var active: OnboardingSetupWindowController?

    private let model: OnboardingSetupViewModel
    private let onRestartAction: () -> Void
    private let onQuitAction: () -> Void
    private var isFinishing = false

    static func present(
        onOpenAccessibilitySettings: @escaping () -> Void,
        onResetOldAccessibilityEntry: @escaping () -> Bool,
        onRequestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void,
        onOpenMicrophoneSettings: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        if let active {
            active.present()
            return
        }

        let controller = OnboardingSetupWindowController(
            onOpenAccessibilitySettings: onOpenAccessibilitySettings,
            onResetOldAccessibilityEntry: onResetOldAccessibilityEntry,
            onRequestMicrophone: onRequestMicrophone,
            onOpenMicrophoneSettings: onOpenMicrophoneSettings,
            onRestart: onRestart,
            onQuit: onQuit
        )
        active = controller
        controller.present()
    }

    private init(
        onOpenAccessibilitySettings: @escaping () -> Void,
        onResetOldAccessibilityEntry: @escaping () -> Bool,
        onRequestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void,
        onOpenMicrophoneSettings: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.model = OnboardingSetupViewModel(
            microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio)
        )
        self.onRestartAction = onRestart
        self.onQuitAction = onQuit

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Set Up HushType"
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

        super.init(window: panel)
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let model = self.model
        let view = OnboardingSetupView(
            model: model,
            appIcon: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath),
            onOpenAccessibilitySettings: {
                model.markAccessibilitySettingsOpened()
                onOpenAccessibilitySettings()
            },
            onResetOldAccessibilityEntry: {
                guard onResetOldAccessibilityEntry() else { return }
                model.markAccessibilityReset()
            },
            onRequestMicrophone: {
                model.markMicrophoneRequestInFlight()
                onRequestMicrophone { granted in
                    Task { @MainActor in
                        model.markMicrophoneRequestCompleted(granted: granted)
                    }
                }
            },
            onOpenMicrophoneSettings: {
                model.markMicrophoneSettingsOpened()
                onOpenMicrophoneSettings()
            },
            onRestart: { [weak self] in
                self?.finish(.restart)
            },
            onQuit: { [weak self] in
                self?.finish(.quit)
            }
        )
        panel.contentViewController = NSHostingController(rootView: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func present() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private func finish(_ result: Result) {
        guard !isFinishing else { return }
        isFinishing = true
        PermissionSettingsGuidePanel.shared.dismiss()
        window?.delegate = nil
        window?.orderOut(nil)
        Self.active = nil

        switch result {
        case .restart:
            onRestartAction()
        case .quit:
            onQuitAction()
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish(.quit)
    }
}

@MainActor
final class OnboardingSetupViewModel: ObservableObject {
    @Published var accessibilitySettingsOpened = false
    @Published var didResetAccessibility = false
    @Published var microphoneStatus: AVAuthorizationStatus
    @Published var microphoneRequestInFlight = false
    @Published var microphoneSettingsOpened = false

    init(microphoneStatus: AVAuthorizationStatus) {
        self.microphoneStatus = microphoneStatus
    }

    func markAccessibilitySettingsOpened() {
        accessibilitySettingsOpened = true
    }

    func markAccessibilityReset() {
        didResetAccessibility = true
        accessibilitySettingsOpened = true
    }

    func markMicrophoneRequestInFlight() {
        microphoneRequestInFlight = true
    }

    func markMicrophoneRequestCompleted(granted: Bool) {
        microphoneRequestInFlight = false
        microphoneStatus = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func markMicrophoneSettingsOpened() {
        microphoneSettingsOpened = true
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
}

private struct OnboardingSetupView: View {
    @ObservedObject var model: OnboardingSetupViewModel
    let appIcon: NSImage
    let onOpenAccessibilitySettings: () -> Void
    let onResetOldAccessibilityEntry: () -> Void
    let onRequestMicrophone: () -> Void
    let onOpenMicrophoneSettings: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            accessibilitySection
            microphoneSection
            restartGuidance
            footer
        }
        .padding(24)
        .frame(width: OnboardingSetupWindowController.panelWidth)
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
                Text("Set Up HushType")
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text("Allow HushType to listen for Right Option and record your voice locally.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var accessibilitySection: some View {
        permissionCard(
            symbol: "figure.stand",
            tint: .blue,
            title: "Accessibility",
            subtitle: "Required for the Right Option hotkey.",
            status: model.accessibilitySettingsOpened ? "Restart needed" : "Needs permission",
            statusTint: model.accessibilitySettingsOpened ? .orange : .secondary
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Open System Settings") {
                        onOpenAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Reset Old HushType Entry") {
                        onResetOldAccessibilityEntry()
                    }
                    .buttonStyle(.bordered)
                }

                Text("Use reset if you installed an older HushType, see duplicate HushType entries, cannot find HushType, or the switch does not work.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.didResetAccessibility {
                    Label("Old Accessibility entries cleared. Add or enable HushType again.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var microphoneSection: some View {
        permissionCard(
            symbol: "mic.fill",
            tint: .green,
            title: "Microphone",
            subtitle: "Required to transcribe your voice.",
            status: microphoneStatusTitle,
            statusTint: microphoneStatusTint
        ) {
            HStack(spacing: 8) {
                switch model.microphoneStatus {
                case .authorized:
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                case .notDetermined:
                    Button(model.microphoneRequestInFlight ? "Waiting..." : "Allow Microphone") {
                        onRequestMicrophone()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.microphoneRequestInFlight)
                case .denied, .restricted:
                    Button("Open Microphone Settings") {
                        onOpenMicrophoneSettings()
                    }
                    .buttonStyle(.bordered)
                @unknown default:
                    Button("Open Microphone Settings") {
                        onOpenMicrophoneSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var restartGuidance: some View {
        if model.accessibilitySettingsOpened {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text(restartGuidanceText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Quit") {
                onQuit()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if model.accessibilitySettingsOpened {
                Button("Restart HushType") {
                    onRestart()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canRestart)
                .help(canRestart ? "Restart HushType" : "Allow or review Microphone access before restarting.")
            }
        }
    }

    private var canRestart: Bool {
        guard model.accessibilitySettingsOpened, !model.microphoneRequestInFlight else {
            return false
        }
        return model.microphoneStatus != .notDetermined
    }

    private var restartGuidanceText: String {
        if model.microphoneStatus == .notDetermined {
            return "After enabling HushType in Accessibility, allow Microphone access before restarting."
        }
        return "After enabling HushType in Accessibility, restart the app so macOS applies the permission."
    }

    private func permissionCard<Actions: View>(
        symbol: String,
        tint: Color,
        title: String,
        subtitle: String,
        status: String,
        statusTint: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.14))
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 12)

                statusPill(title: status, tint: statusTint)
            }

            actions()
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func statusPill(title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(tint.opacity(0.14))
            )
    }

    private var microphoneStatusTitle: String {
        switch model.microphoneStatus {
        case .authorized:
            return "Allowed"
        case .notDetermined:
            return model.microphoneRequestInFlight ? "Waiting" : "Needs permission"
        case .denied, .restricted:
            return "Blocked"
        @unknown default:
            return "Needs review"
        }
    }

    private var microphoneStatusTint: Color {
        switch model.microphoneStatus {
        case .authorized:
            return .green
        case .notDetermined:
            return .secondary
        case .denied, .restricted:
            return .red
        @unknown default:
            return .secondary
        }
    }
}
