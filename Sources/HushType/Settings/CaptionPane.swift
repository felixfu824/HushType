import AppKit
import Settings
import SwiftUI

struct CaptionPane: View {
    var body: some View {
        Color.clear
            .frame(width: 720)
            .accessibilityHidden(true)
    }

    static func makeSettingsPane() -> AppSettings.Pane<CaptionPane> {
        let title = L10n.string("settings.tab.caption", fallback: "Caption")
        return AppSettings.Pane(
            identifier: .caption,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "captions.bubble",
                accessibilityDescription: title
            )!
        ) {
            CaptionPane()
        }
    }
}
