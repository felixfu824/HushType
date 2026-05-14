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
/// that restart requirement explicitly via an `NSAlert` that mirrors
/// `OnboardingManager`'s Accessibility pattern.
///
/// Implementation note vs. spec §6.b: the spec described two separate alerts
/// (Alert A "post-grant restart", Alert B "denied — open Settings"), but
/// `CGPreflightScreenCaptureAccess()` returns `false` in both cases until the
/// process is restarted, so we cannot reliably distinguish them. This flow
/// instead presents a single guidance alert with three buttons:
/// `Open System Settings` / `Restart HushType Now` / `Cancel`. The user knows
/// which state they're in; this lets them pick the right action.
enum SystemAudioPermissionFlow {

    /// If permission is already granted for this process, calls `onReady`
    /// synchronously. Otherwise triggers the OS prompt (if `.notDetermined`)
    /// and shows the guidance alert. `onReady` is NEVER called from inside
    /// the alert — restarting the app picks up the grant in the next
    /// process, where this function will be called again and short-circuit.
    @MainActor
    static func ensurePermission(then onReady: @escaping () -> Void) {
        if CGPreflightScreenCaptureAccess() {
            log.info("Screen capture permission already granted")
            onReady()
            return
        }

        // Triggers the OS prompt if status == .notDetermined.
        // Returns the cached state synchronously, NOT the prompt resolution.
        let granted = CGRequestScreenCaptureAccess()
        log.info("Requested screen capture access — preflight=\(granted, privacy: .public) (cached state)")

        showGuidanceAlert()
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
    private static func showGuidanceAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen & System Audio Recording Permission Needed"
        alert.informativeText = """
            To caption audio from apps like Zoom, Chrome, or Safari, HushType \
            needs Screen & System Audio Recording permission.

            1. Click "Open System Settings"
            2. Find HushType in the list
            3. Toggle the switch ON
            4. Click "Restart HushType Now" below

            macOS won't pick up the grant until HushType is restarted.

            If you've already granted permission, click "Restart HushType Now" \
            directly — no need to revisit System Settings.
            """
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Restart HushType Now")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openScreenCaptureSettings()
            // Do NOT terminate — user may return to grant + come back.
        case .alertSecondButtonReturn:
            log.info("User chose restart from system audio permission flow")
            OnboardingManager.relaunchAndQuit()
        default:
            log.info("User cancelled system audio permission flow")
        }
    }

    private static func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            log.error("Failed to construct Screen Capture settings URL")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
