import AppKit
import Foundation

/// One-time pre-session disclosure shown the first time the user enables
/// Cloud Translate (Settings → engine = `cloudTranslate`). Persists
/// `AppConfig.cloudOnboardingShown = true` after dismissal so subsequent
/// session starts don't re-show.
enum CloudOnboardingAlert {

    /// Show the disclosure if it hasn't been shown yet. Returns true if the
    /// user accepted (or had already accepted in a prior run), false if they
    /// cancelled. Must be called from the main actor (NSAlert.runModal is
    /// blocking; the caller is expected to be on the menu/settings flow).
    @MainActor
    static func presentIfNeeded() -> Bool {
        if AppConfig.shared.cloudOnboardingShown { return true }
        return presentForced()
    }

    /// Always show. Used internally and from a hypothetical "show again"
    /// affordance.
    @MainActor
    static func presentForced() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.cloud_caption_disclosure.title",
            fallback: "Enable Live Translated Caption"
        )
        alert.informativeText = L10n.string(
            "alert.cloud_caption_disclosure.message",
            fallback: "Live Translated Caption sends your audio to OpenAI for live translation.\n\n• Cost: about $2/hour, billed to your OpenAI account\n• Your API key — Lamitype never sees it\n• No Lamitype server in the middle; audio goes Mac → OpenAI directly\n• You can stop the session any time, or switch back to local\n\nThis is opt-in. You'll only see this notice once."
        )
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
        alert.addButton(withTitle: L10n.string(
            "alert.cloud_caption_disclosure.accept",
            fallback: "I understand"
        ))
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            AppConfig.shared.cloudOnboardingShown = true
            return true
        }
        return false
    }
}
