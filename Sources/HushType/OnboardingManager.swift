import AppKit
import AVFoundation
import ApplicationServices
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "onboarding")

/// Coordinates first-launch and post-permission-loss UX.
///
/// Why this exists: macOS caches Accessibility permission per process at the
/// moment of first `CGEvent.tapCreate` call. If the user grants permission
/// after that point, the running process *cannot* see the new permission —
/// it must be restarted. The default flow leaves users granting permission
/// in System Settings and then wondering why HushType still doesn't work.
///
/// This manager:
///   1. Checks `AXIsProcessTrusted()` BEFORE we ever call CGEvent.tapCreate.
///   2. If accessibility is missing, presents a friendly modal explaining
///      what's needed and what will happen next.
///   3. Opens System Settings to the right page.
///   4. After the user grants permission, offers a "Restart HushType" button
///      that spawns a new instance and quits the current one.
///   5. Triggers the microphone permission prompt as a side-effect (it
///      doesn't require restart, but we want all permission prompts grouped).
///
/// First-launch detection (per user spec):
///   - The trigger is "accessibility currently denied", not "first install".
///     This handles both first installs AND post-rebuild permission revokes
///     (which happen if the binary's signature changes between builds).
///   - The "Welcome" message variant is shown only once (`onboardingCompleted`
///     flag). Subsequent launches with denied accessibility skip straight to
///     the shorter "Grant Permission" guidance.
@MainActor
enum OnboardingManager {

    /// Returns `true` if onboarding handled the launch and the caller should
    /// NOT continue with normal app startup (because the app is about to quit
    /// or wait on a modal). Returns `false` if no onboarding was needed and
    /// the caller should proceed normally.
    static func runIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            // Permission granted — fire mic prompt if not yet asked, then proceed.
            triggerMicPermissionIfNeeded()
            return false
        }

        log.info("Accessibility not granted — running onboarding flow")

        // Clear any stale TCC entries from previous builds before prompting.
        // macOS TCC tracks Accessibility grants as (identifier + cdhash). For
        // ad-hoc signed apps like HushType, every rebuild produces a new
        // cdhash, so upgrades leave the previous entry orphaned in the list
        // with the OLD cdhash, and the OS creates a fresh entry for the NEW
        // cdhash. Users then see two identical "HushType" rows in System
        // Settings → Accessibility and have to guess which one to delete.
        //
        // `tccutil reset Accessibility com.felix.hushtype` wipes ALL entries
        // for this bundle ID. It's a no-op on true first installs (nothing
        // to clear), and on upgrades it leaves exactly one fresh entry once
        // the current process re-registers itself on the next API call.
        // No sudo required — users can always reset their own TCC records.
        resetStaleAccessibilityEntries()

        // Foreground the app so the modal appears in front of other windows
        // (HushType is LSUIElement so it doesn't activate by default).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let isFirstTime = !AppConfig.shared.onboardingCompleted
        if isFirstTime {
            showWelcomeModal()
        } else {
            showPermissionGuidanceModal()
        }
        return true
    }

    // MARK: - Welcome (shown once on first launch)

    private static func showWelcomeModal() {
        let alert = NSAlert()
        alert.messageText = "Welcome to HushType"
        alert.informativeText = """
            HushType needs two permissions to work:

            • Accessibility — to listen for the Right Option hotkey
            • Microphone — to record your voice

            After you grant these, HushType will need to be restarted. We'll handle that for you.
            """
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Get Started")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            AppConfig.shared.onboardingCompleted = true
            triggerMicPermissionIfNeeded()
            showPermissionGuidanceModal()
        } else {
            log.info("User quit during welcome modal")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Permission guidance (shown every time accessibility is denied)

    private static func showPermissionGuidanceModal() {
        // Open System Settings → Privacy & Security → Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        let alert = NSAlert()
        alert.messageText = "Grant Accessibility Permission"
        alert.informativeText = """
            System Settings is now open.

            1. Find HushType in the Accessibility list
            2. Toggle the switch ON
            3. Click "Restart HushType" below

            HushType must be restarted after you grant permission for it to take effect.
            """
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart HushType")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            relaunchAndQuit()
        } else {
            log.info("User quit during permission guidance modal")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Microphone permission

    private static func triggerMicPermissionIfNeeded() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            log.info("Mic permission already \(String(describing: status), privacy: .public)")
            return
        }
        log.info("Requesting microphone permission")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            log.info("Microphone permission granted: \(granted, privacy: .public)")
        }
    }

    // MARK: - TCC reset

    private static func resetStaleAccessibilityEntries() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", "com.felix.hushtype"]
        do {
            try task.run()
            task.waitUntilExit()
            log.info("tccutil reset Accessibility exit code: \(task.terminationStatus)")
        } catch {
            log.error("Failed to run tccutil reset: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Relaunch helper

    /// Spawn a fresh instance of HushType.app via `open -n` and terminate the
    /// current process. The new process gets a fresh accessibility permission
    /// check from the kernel and should now see the user's grant.
    private static func relaunchAndQuit() {
        let bundleURL = Bundle.main.bundleURL
        log.info("Relaunching HushType from \(bundleURL.path, privacy: .public)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        do {
            try task.run()
        } catch {
            log.error("Failed to spawn new instance: \(error.localizedDescription)")
        }

        // Brief delay so the new process can finish its early startup
        // before we tear down — without this, `open -n` sometimes races and
        // spawns the new process under the dying one's PID family.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}
