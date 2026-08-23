import AppKit
import Settings
import SwiftUI

struct GeneralPane: View {
    var body: some View {
        Color.clear
            .frame(width: 720)
            .accessibilityHidden(true)
    }

    static func makeSettingsPane() -> AppSettings.Pane<GeneralPane> {
        let title = L10n.string("settings.tab.general", fallback: "General")
        return AppSettings.Pane(
            identifier: .general,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "gearshape",
                accessibilityDescription: title
            )!
        ) {
            GeneralPane()
        }
    }
}
