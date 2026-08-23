import AppKit
import Settings
import SwiftUI

struct TextPane: View {
    var body: some View {
        Color.clear
            .frame(width: 720)
            .accessibilityHidden(true)
    }

    static func makeSettingsPane() -> AppSettings.Pane<TextPane> {
        let title = L10n.string("settings.tab.text", fallback: "Text")
        return AppSettings.Pane(
            identifier: .text,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "textformat",
                accessibilityDescription: title
            )!
        ) {
            TextPane()
        }
    }
}
