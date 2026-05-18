import AppKit
import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "systemAudioPermission")

/// Owns the lazy permission flow for Screen & System Audio Recording.
///
/// API: `SystemAudioPermissionFlow.ensurePermission(then:)`.
///
/// macOS caches Screen Recording permission at process start (same per-process
/// cache barrier as Accessibility). After the user grants permission for the
/// first time — via the system prompt OR via System Settings — the running
/// HushType process still cannot capture until it restarts. This flow surfaces
/// that restart requirement explicitly via a focused permission panel.
///
/// Implementation note vs. spec §6.b: the spec described two separate alerts
/// (Alert A "post-grant restart", Alert B "denied — open Settings"), but
/// `CGPreflightScreenCaptureAccess()` returns `false` in both cases until the
/// process is restarted, so we cannot reliably distinguish them. This flow
/// instead presents a single guided setup panel with `Open System Settings`,
/// `Restart HushType`, and a manual troubleshooting reset for stale TCC rows.
enum SystemAudioPermissionFlow {

    /// If permission is already granted for this process, calls `onReady`
    /// synchronously. Otherwise shows the guided setup panel. `onReady` is
    /// NEVER called from inside the panel — restarting the app picks up the
    /// grant in the next process, where this function will be called again
    /// and short-circuit.
    @MainActor
    static func ensurePermission(then onReady: @escaping () -> Void) {
        if CGPreflightScreenCaptureAccess() {
            log.info("Screen capture permission already granted")
            onReady()
            return
        }

        showGuidedSetupPanel()
    }

    private static func resetStaleScreenCaptureEntries() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", "com.felix.hushtype"]
        do {
            try task.run()
            task.waitUntilExit()
            log.info("tccutil reset ScreenCapture exit code: \(task.terminationStatus)")
        } catch {
            log.error("Failed to run tccutil reset ScreenCapture: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mid-session revocation alert (spec §6.c). Called from
    /// `LiveCaptionManager` when `SystemAudioSource.onError` reports the
    /// stream was stopped by the system.
    @MainActor
    static func showRevocationAlert() {
        let alert = NSAlert()
        alert.messageText = "System Audio Capture Stopped"
        alert.informativeText = """
            Screen & System Audio Recording permission was revoked.

            Re-enable it in System Settings to use system-audio Live Caption.
            """
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")

        if alert.runModal() == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    // MARK: - Private

    @MainActor
    private static func showGuidedSetupPanel() {
        SystemAudioPermissionWindowController.present(
            onOpenSettings: {
                // Triggers the OS prompt / app registration if status is
                // `.notDetermined`. Returns the cached state synchronously,
                // NOT the prompt resolution.
                let granted = CGRequestScreenCaptureAccess()
                log.info("Requested screen capture access from setup panel — preflight=\(granted, privacy: .public) (cached state)")
                openScreenCaptureSettings()
                PermissionSettingsGuidePanel.shared.showSystemAudioGuide()
            },
            onRestart: {
                log.info("User chose restart from system audio permission flow")
                SystemAudioPermissionWindowController.dismissActive()
                OnboardingManager.relaunchAndQuit()
            },
            onResetStaleEntries: {
                log.info("User requested stale ScreenCapture permission reset")
                resetStaleScreenCaptureEntries()
                let granted = CGRequestScreenCaptureAccess()
                log.info("Requested screen capture access after reset — preflight=\(granted, privacy: .public) (cached state)")
                openScreenCaptureSettings()
                PermissionSettingsGuidePanel.shared.showSystemAudioGuide()
            },
            onCancel: {
                log.info("User cancelled system audio permission flow")
            }
        )
    }

    private static func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            log.error("Failed to construct Screen Capture settings URL")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
