import AppKit
import SwiftUI

/// Small Codex-style helper shown after opening System Settings.
///
/// The panel stays above System Settings and gives the user a concrete app
/// tile to drag if HushType is missing from the permission list.
@MainActor
final class PermissionSettingsGuidePanel {
    static let shared = PermissionSettingsGuidePanel()

    private var panel: NSPanel?

    private init() {}

    func showSystemAudioGuide() {
        showGuide(
            title: "Turn on HushType in Screen & System Audio Recording.",
            detail: "If HushType is missing, drag HushType into the list."
        )
    }

    func showAccessibilityGuide() {
        showGuide(
            title: "Turn on HushType in Accessibility.",
            detail: "If HushType is missing, drag HushType into the list."
        )
    }

    private func showGuide(title: String, detail: String) {
        dismiss()

        let appURL = Bundle.main.bundleURL
        let view = PermissionSettingsGuideView(
            title: title,
            detail: detail,
            appURL: appURL
        ) {
            Task { @MainActor in
                PermissionSettingsGuidePanel.shared.dismiss()
            }
        }
        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 126),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = false
        panel.contentView = hostingView

        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        self.panel = panel
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 110
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: false)
    }
}

private struct PermissionSettingsGuideView: View {
    let title: String
    let detail: String
    let appURL: URL
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.up")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.blue)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Hide helper")

                DraggableAppTileView(appURL: appURL)
                    .frame(width: 174, height: 50)
            }
            .frame(width: 174)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(width: 500, height: 126)
        .background(VisualEffectBlur(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }
}
