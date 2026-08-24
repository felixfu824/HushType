import AppKit
import os

private let updateCheckLog = Logger(
    subsystem: "com.felix.hushtype",
    category: "updates"
)

/// Owns the user-facing version-check flow shared by Settings and the menu.
/// Consent is intentionally requested on every check, with Cancel as the
/// default action, because HushType is local-first by default.
@MainActor
final class UpdateCheckCoordinator {
    static let shared = UpdateCheckCoordinator()

    private var isChecking = false

    private init() {}

    func checkForUpdates() {
        guard !isChecking else { return }

        let consent = Self.makeConsentAlert()
        guard consent.runModal() == .alertSecondButtonReturn else {
            updateCheckLog.info("User declined version check consent")
            return
        }

        isChecking = true
        updateCheckLog.info("User approved version check; fetching")

        Task { @MainActor in
            defer { isChecking = false }
            do {
                let result = try await VersionChecker.check()
                if result.isUpToDate {
                    showUpToDate(version: result.currentVersion)
                } else {
                    showUpdateAvailable(version: result.latestVersion, url: result.releaseURL)
                }
            } catch {
                showCheckError(error)
            }
        }
    }

    static func makeConsentAlert() -> NSAlert {
        let consent = NSAlert()
        consent.messageText = L10n.string(
            "alert.update_consent.title",
            fallback: "Connect to GitHub?"
        )
        consent.informativeText = L10n.string(
            "alert.update_consent.message",
            fallback: "HushType will connect to GitHub to check for new releases.\n\nNo personal data is sent; only a public API call is made to compare version numbers."
        )
        consent.alertStyle = .informational
        consent.icon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        consent.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        consent.addButton(withTitle: L10n.string(
            "alert.update_consent.check_now",
            fallback: "Check Now"
        ))
        return consent
    }

    private func showUpToDate(version: String) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.update.up_to_date.title",
            fallback: "Up to Date"
        )
        alert.informativeText = L10n.format(
            "alert.update.up_to_date.message",
            "You're running the latest version (v%1$@).",
            arguments: [version]
        )
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }

    private func showUpdateAvailable(version: String, url: URL?) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.update.available.title",
            fallback: "Update Available"
        )
        alert.informativeText = L10n.format(
            "alert.update.available.message",
            "A new version is available: v%1$@\n\nYou can download it from the GitHub Releases page.",
            arguments: [version]
        )
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: L10n.string(
            "alert.update.view_github",
            fallback: "View on GitHub"
        ))
        alert.addButton(withTitle: L10n.string("common.button.later", fallback: "Later"))

        if alert.runModal() == .alertFirstButtonReturn {
            let destination = url ?? URL(string: "https://github.com/felixfu824/HushType/releases")
            if let destination {
                NSWorkspace.shared.open(destination)
            }
        }
    }

    private func showCheckError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.update.error.title",
            fallback: "Could Not Check for Updates"
        )
        alert.alertStyle = .warning
        alert.icon = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        alert.informativeText = L10n.format(
            "alert.update.error.message",
            "Unable to connect to GitHub.\n\n%1$@\n\nCheck your internet connection and try again.",
            arguments: [error.localizedDescription]
        )
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }
}
