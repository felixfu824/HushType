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
    enum Pane {
        case general
        case dictation
        case caption
        case text
        case cloud

        fileprivate var identifier: AppSettings.PaneIdentifier {
            switch self {
            case .general: .general
            case .dictation: .dictation
            case .caption: .caption
            case .text: .text
            case .cloud: .cloud
            }
        }
    }

    static let shared = HushTypeSettingsWindowController()

    private final class EngineSwitchRelay {
        var handler: ((AppConfig.DictationEngine) -> Void)?

        func switchEngine(to engine: AppConfig.DictationEngine) {
            handler?(engine)
        }
    }

    private let engineSwitchRelay = EngineSwitchRelay()

    var onSwitchEngine: ((AppConfig.DictationEngine) -> Void)? {
        get { engineSwitchRelay.handler }
        set { engineSwitchRelay.handler = newValue }
    }

    private lazy var packageController = SettingsWindowController(
            panes: [
                GeneralPane.makeSettingsPane().asSettingsPane(),
                DictationPane.makeSettingsPane(
                    onSwitchEngine: { [weak engineSwitchRelay] engine in
                        engineSwitchRelay?.switchEngine(to: engine)
                    }
                ).asSettingsPane(),
                CaptionPane.makeSettingsPane().asSettingsPane(),
                TextPane.makeSettingsPane().asSettingsPane(),
                CloudPane.makeSettingsPane().asSettingsPane(),
            ],
            animated: true
        )

    private init() {}

    func presentAndFocus(
        pane: Pane? = nil,
        onSwitchEngine: ((AppConfig.DictationEngine) -> Void)? = nil
    ) {
        if let onSwitchEngine {
            self.onSwitchEngine = onSwitchEngine
        }
        packageController.show(pane: pane?.identifier)
        packageController.window?.title = L10n.string(
            "settings.window.title",
            fallback: "Settings"
        )
    }
}
