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
///   2. If accessibility is missing, presents a guided setup panel explaining
///      the Accessibility and Microphone permissions.
///   3. Opens System Settings from explicit user actions and shows a draggable
///      app helper when Accessibility needs a manual list entry.
///   4. Offers an explicit reset action for old Accessibility entries left by
///      previous builds, instead of clearing TCC automatically.
///   5. After the user grants Accessibility, offers a "Restart HushType" button
///      that spawns a new instance and quits the current one.
///   6. Requests microphone permission in the same setup surface; microphone
///      grants do not require restart.
///
/// First-launch detection (per user spec):
///   - The trigger is "accessibility currently denied", not "first install".
///     This handles both first installs AND post-rebuild permission revokes
///     (which happen if the binary's signature changes between builds).
///   - The same setup panel is reused for first-time onboarding and permission
///     repair so the flow stays consistent.
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

        // Foreground the app so the setup panel appears in front of other windows
        // (HushType is LSUIElement so it doesn't activate by default).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        OnboardingSetupWindowController.present(
            onOpenAccessibilitySettings: {
                AppConfig.shared.onboardingCompleted = true
                openAccessibilitySettings()
                PermissionSettingsGuidePanel.shared.showAccessibilityGuide()
            },
            onResetOldAccessibilityEntry: {
                guard confirmAccessibilityReset() else { return false }
                AppConfig.shared.onboardingCompleted = true
                let didReset = resetStaleAccessibilityEntries()
                openAccessibilitySettings()
                PermissionSettingsGuidePanel.shared.showAccessibilityGuide()
                return didReset
            },
            onRequestMicrophone: { completion in
                AppConfig.shared.onboardingCompleted = true
                requestMicrophoneAccess(completion: completion)
            },
            onOpenMicrophoneSettings: {
                AppConfig.shared.onboardingCompleted = true
                openMicrophoneSettings()
            },
            onRestart: {
                relaunchAndQuit()
            },
            onQuit: {
                log.info("User quit during onboarding")
                NSApp.terminate(nil)
            }
        )

        return true
    }

    // MARK: - Settings links

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility reset

    private static func confirmAccessibilityReset() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Reset Old HushType Entry?"
        alert.informativeText = """
            This clears HushType from the Accessibility permission list.

            Use this if you installed an older HushType, see duplicate HushType entries, cannot find HushType, or the switch does not work. You'll need to add or enable HushType again.
            """
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reset and Reopen Settings")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Microphone permission

    private static func triggerMicPermissionIfNeeded() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            log.info("Mic permission already \(String(describing: status), privacy: .public)")
            return
        }
        requestMicrophoneAccess { _ in }
    }

    private static func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            log.info("Mic permission already \(String(describing: status), privacy: .public)")
            completion(status == .authorized)
            return
        }

        log.info("Requesting microphone permission")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            log.info("Microphone permission granted: \(granted, privacy: .public)")
            completion(granted)
        }
    }

    // MARK: - TCC reset

    @discardableResult
    private static func resetStaleAccessibilityEntries() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", "com.felix.hushtype"]
        do {
            try task.run()
            task.waitUntilExit()
            log.info("tccutil reset Accessibility exit code: \(task.terminationStatus)")
            return task.terminationStatus == 0
        } catch {
            log.error("Failed to run tccutil reset: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Relaunch helper

    /// Spawn a fresh instance of HushType.app via `open -n` and terminate the
    /// current process. The new process gets a fresh accessibility / screen-
    /// recording permission check from the kernel and should now see the user's
    /// grant.
    ///
    /// `internal` (not `private`) so `SystemAudioPermissionFlow` can reuse this
    /// helper for Screen Recording grants — that permission has the same per-
    /// process cache barrier as Accessibility.
    static func relaunchAndQuit() {
        let bundleURL = Bundle.main.bundleURL
        log.info("Relaunching HushType from \(bundleURL.path, privacy: .public)")

        // Spawn `/bin/sh -c "sleep 1 && open -n <path>"` and let it reparent
        // to launchd when we terminate. Doing `open -n` ourselves and dying
        // 0.3s later races: LaunchServices still sees our PID-family as the
        // active instance and silently refuses the new launch (this was the
        // SystemAudioPermissionFlow "Restart" button quitting without
        // reopening). The detached shell waits a full second for our
        // termination to settle and the LS record to clear, then issues
        // the launch against a fully-quit bundle.
        let escaped = bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "sleep 1 && open -n '\(escaped)' >/dev/null 2>&1"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", cmd]
        do {
            try task.run()
        } catch {
            log.error("Failed to spawn relauncher shell: \(error.localizedDescription)")
        }

        // We can terminate fast now — the shell is independent of our
        // lifecycle. Give NSApp 150ms to flush its termination message
        // chain so windows close cleanly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }
}
