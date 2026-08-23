import AppKit
import Settings
import SwiftUI

struct CloudPane: View {
    var body: some View {
        Color.clear
            .frame(width: 720)
            .accessibilityHidden(true)
    }

    static func makeSettingsPane() -> AppSettings.Pane<CloudPane> {
        let title = L10n.string("settings.tab.cloud", fallback: "Cloud")
        return AppSettings.Pane(
            identifier: .cloud,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "dollarsign.circle",
                accessibilityDescription: title
            )!
        ) {
            CloudPane()
        }
    }
}
