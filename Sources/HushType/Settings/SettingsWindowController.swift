import AppKit
import Settings

extension AppSettings.PaneIdentifier {
    static let general = Self("general")
    static let dictation = Self("dictation")
    static let caption = Self("caption")
    static let text = Self("text")
    static let cloud = Self("cloud")
    static let ios = Self("ios")
    static let about = Self("about")
}

/// Owns the single seven-pane Settings window for HushType.
@MainActor
final class HushTypeSettingsWindowController {
    enum Pane {
        case general
        case dictation
        case caption
        case text
        case cloud
        case ios
        case about

        fileprivate var identifier: AppSettings.PaneIdentifier {
            switch self {
            case .general: .general
            case .dictation: .dictation
            case .caption: .caption
            case .text: .text
            case .cloud: .cloud
            case .ios: .ios
            case .about: .about
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

    private final class UpdateCheckRelay {
        var handler: (() -> Void)?

        func checkForUpdates() {
            handler?()
        }
    }

    private final class CaptionPanelResetRelay {
        var handler: (() -> Void)?

        func reset() {
            handler?()
        }
    }

    private final class IOSServerRelay {
        var toggleHandler: (() -> Void)?
        var runningProvider: (() -> Bool)?

        func toggle() {
            toggleHandler?()
        }

        func isRunning() -> Bool {
            runningProvider?() ?? false
        }
    }

    private let engineSwitchRelay = EngineSwitchRelay()
    private let updateCheckRelay = UpdateCheckRelay()
    private let captionPanelResetRelay = CaptionPanelResetRelay()
    private let iosServerRelay = IOSServerRelay()

    var onSwitchEngine: ((AppConfig.DictationEngine) -> Void)? {
        get { engineSwitchRelay.handler }
        set { engineSwitchRelay.handler = newValue }
    }

    var onCheckForUpdates: (() -> Void)? {
        get { updateCheckRelay.handler }
        set { updateCheckRelay.handler = newValue }
    }

    var onResetCaptionPanelFrame: (() -> Void)? {
        get { captionPanelResetRelay.handler }
        set { captionPanelResetRelay.handler = newValue }
    }

    var onToggleIOSServer: (() -> Void)? {
        get { iosServerRelay.toggleHandler }
        set { iosServerRelay.toggleHandler = newValue }
    }

    var isIOSServerRunning: (() -> Bool)? {
        get { iosServerRelay.runningProvider }
        set { iosServerRelay.runningProvider = newValue }
    }

    private lazy var packageController = SettingsWindowController(
            panes: [
                GeneralPane.makeSettingsPane().asSettingsPane(),
                DictationPane.makeSettingsPane(
                    onSwitchEngine: { [weak engineSwitchRelay] engine in
                        engineSwitchRelay?.switchEngine(to: engine)
                    }
                ).asSettingsPane(),
                CaptionPane.makeSettingsPane(
                    onResetPanelFrame: { [weak captionPanelResetRelay] in
                        captionPanelResetRelay?.reset()
                    }
                ).asSettingsPane(),
                TextPane.makeSettingsPane().asSettingsPane(),
                CloudPane.makeSettingsPane().asSettingsPane(),
                IOSServerPane.makeSettingsPane(
                    onToggle: { [weak iosServerRelay] in
                        iosServerRelay?.toggle()
                    },
                    isRunning: { [weak iosServerRelay] in
                        iosServerRelay?.isRunning() ?? false
                    }
                ).asSettingsPane(),
                AboutPane.makeSettingsPane(
                    onCheckForUpdates: { [weak updateCheckRelay] in
                        updateCheckRelay?.checkForUpdates()
                    }
                ).asSettingsPane(),
            ],
            animated: true
        )

    private init() {}

    func presentAndFocus(
        pane: Pane? = nil,
        onSwitchEngine: ((AppConfig.DictationEngine) -> Void)? = nil,
        onCheckForUpdates: (() -> Void)? = nil,
        onToggleIOSServer: (() -> Void)? = nil,
        isIOSServerRunning: (() -> Bool)? = nil
    ) {
        if let onSwitchEngine {
            self.onSwitchEngine = onSwitchEngine
        }
        if let onCheckForUpdates {
            self.onCheckForUpdates = onCheckForUpdates
        }
        if let onToggleIOSServer {
            self.onToggleIOSServer = onToggleIOSServer
        }
        if let isIOSServerRunning {
            self.isIOSServerRunning = isIOSServerRunning
        }
        packageController.show(pane: pane?.identifier)
        if let window = packageController.window {
            window.title = L10n.string("settings.window.title", fallback: "Settings")
            window.level = .normal
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()

            // Menu tracking can restore focus to the previously active app as
            // soon as its action returns. Reassert once on the next run-loop so
            // Settings reliably lands in front without becoming always-on-top.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}
