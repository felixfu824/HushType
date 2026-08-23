import Settings

extension AppSettings.PaneIdentifier {
    static let general = Self("general")
    static let dictation = Self("dictation")
    static let caption = Self("caption")
    static let text = Self("text")
    static let cloud = Self("cloud")
}

/// Owns the single five-pane Settings window for HushType.
@MainActor
final class HushTypeSettingsWindowController {
    static let shared = HushTypeSettingsWindowController()

    private let packageController: SettingsWindowController

    private init() {
        packageController = SettingsWindowController(
            panes: [
                GeneralPane.makeSettingsPane().asSettingsPane(),
                DictationPane.makeSettingsPane().asSettingsPane(),
                CaptionPane.makeSettingsPane().asSettingsPane(),
                TextPane.makeSettingsPane().asSettingsPane(),
                CloudPane.makeSettingsPane().asSettingsPane(),
            ],
            animated: true
        )
    }

    func presentAndFocus() {
        packageController.show()
    }
}
