import AppKit
import Settings
import SwiftUI

struct DictationPane: View {
    var body: some View {
        Color.clear
            .frame(width: 720)
            .accessibilityHidden(true)
    }

    static func makeSettingsPane() -> AppSettings.Pane<DictationPane> {
        let title = L10n.string("settings.tab.dictation", fallback: "Dictation")
        return AppSettings.Pane(
            identifier: .dictation,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "mic",
                accessibilityDescription: title
            )!
        ) {
            DictationPane()
        }
    }
}
