import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "statusbar")

final class StatusBarController: NSObject, NSMenuDelegate {
    enum State {
        case loading(Double) // progress 0.0–1.0
        case idle
        case recording
        case transcribing
        case polishing
        case error(String)
        case unloaded
    }

    /// Semantic action for the model-memory menu item. Localized display
    /// text never determines behavior.
    enum ModelMenuAction: Equatable {
        case unload
        case reload
    }

    private let statusItem: NSStatusItem
    private let localEngine: Qwen3TranscriptionEngine
    /// Combined status + memory row, e.g. "Ready · Memory 2.1 GB".
    private let statusMenuItem: NSMenuItem
    private let languageMenu: NSMenu
    private var languageItems: [NSMenuItem] = []
    private let dictationEngineMenu: NSMenu
    private var dictationEngineItems: [NSMenuItem] = []
    private let punctuationMenu: NSMenu
    private var punctuationItems: [NSMenuItem] = []
    private var iosServerMenuItem: NSMenuItem!
    private var floatingOverlayMenuItem: NSMenuItem!
    private var numberConversionMenuItem: NSMenuItem!
    private var liveCaptionMenuItem: NSMenuItem!
    private var liveCaptionStartStopItem: NSMenuItem!
    private var liveCaptionMicItem: NSMenuItem!
    private var liveCaptionSystemItem: NSMenuItem!
    private var liveCaptionChangeSourceItem: NSMenuItem!
    private var liveTranslatedMenuItem: NSMenuItem!
    private var liveTranslatedStartStopItem: NSMenuItem!
    private var liveTranslatedMicItem: NSMenuItem!
    private var liveTranslatedSystemItem: NSMenuItem!
    private var liveTranslatedChangeSourceItem: NSMenuItem!
    private var textTranslationMenuItem: NSMenuItem!
    private var textPolishMenuItem: NSMenuItem!
    private var textTranslationEnableItem: NSMenuItem!
    private var translateToItem: NSMenuItem!
    private var translationHintItem: NSMenuItem!
    private var unloadMenuItem: NSMenuItem!
    private var modelMenuAction: ModelMenuAction = .unload
    private let launchInterfaceLanguage: InterfaceLanguage
    private let interfaceLanguageMenu = NSMenu()
    private var interfaceLanguageItems: [InterfaceLanguage: NSMenuItem] = [:]
    private var appliedNextLaunchItem: NSMenuItem!
    private var dictionaryMenuItem: NSMenuItem!
    private var dictionarySubtitleItem: NSMenuItem!
    /// Last state passed to `setState` — kept so the combined status+memory
    /// row can be re-rendered on every menu open without losing the state text.
    private var currentState: State = .loading(0)
    let iosServerManager = IOSServerManager()

    var onLanguageChanged: ((String?) -> Void)?
    var onQuit: (() -> Void)?
    var onUnloadModel: (() -> Void)?
    var onReloadModel: (() -> Void)?
    /// Both the menu radios and the settings window route through this one
    /// AppDelegate switch path so Cloud → Local always reloads when needed.
    var onDictationEngineChanged: ((AppConfig.DictationEngine) -> Void)?
    /// Fires when the user clicks the Live Caption menu item. AppDelegate
    /// wires this to start/stop the manager (and beeps if the manager isn't
    /// constructed yet because the ASR model is still loading).
    /// Legacy back-compat: only fires for stop-while-active. New start paths
    /// use `onLiveCaptionStartMic` and `onLiveCaptionStartSystem` so the menu
    /// can offer two distinct entry points.
    var onLiveCaptionToggle: (() -> Void)?

    /// Fired when the user clicks Live Caption → `From Microphone` while
    /// the *local* product is off or running off a different source.
    /// AppDelegate sets `liveCaptionEngine = .local` before starting.
    var onLiveCaptionStartMic: (() -> Void)?

    /// Fired when the user clicks Live Caption → `From System Audio…`.
    /// AppDelegate routes through `SystemAudioPermissionFlow` + picker, with
    /// `liveCaptionEngine = .local`.
    var onLiveCaptionStartSystem: (() -> Void)?

    /// Fired when the user clicks Live Caption → `Change System Audio Source…`
    /// to force the picker even though a `systemAudioBundleID` is already
    /// saved. (Source picker is shared between the two products; the new
    /// bundleID persists in `live_caption.json` either way.)
    var onLiveCaptionChangeSystemSource: (() -> Void)?

    /// Fired when the user clicks the currently-active *local* Live Caption
    /// source (stops it). Decoupled from start callbacks so AppDelegate
    /// doesn't have to inspect manager state to know which path the user took.
    var onLiveCaptionStop: (() -> Void)?

    /// Fired when the user clicks Live Translated Caption → `From Microphone`.
    /// AppDelegate sets `liveCaptionEngine = .cloudTranslate` and, on first
    /// use this app version, presents the cloud-onboarding disclosure modal.
    var onLiveTranslatedStartMic: (() -> Void)?

    /// Fired when the user clicks Live Translated Caption → `From System Audio…`.
    /// Same routing as the local variant but engine = `.cloudTranslate`.
    var onLiveTranslatedStartSystem: (() -> Void)?

    /// Fired when the user clicks Live Translated Caption → `Change System
    /// Audio Source…`. Same picker as the local variant.
    var onLiveTranslatedChangeSystemSource: (() -> Void)?

    /// Fired when the user clicks the currently-active *translated* Live
    /// Caption source (stops it).
    var onLiveTranslatedStop: (() -> Void)?

    /// Fired when the user clicks the "Live Caption" header itself. Toggles
    /// the local product with the last-used source (mirrors the Right ⌘ + /
    /// hotkey behavior). Without this the header is a non-actionable label
    /// and macOS greys it out — making it visually inconsistent with the
    /// bright-white "Text Translation", "Text Polish", etc. toggle items
    /// elsewhere in this menu.
    var onLiveCaptionHeaderClicked: (() -> Void)?

    /// Fired when the user clicks the "Live Translated Caption" header.
    /// Same last-used-source toggle semantics as the local variant.
    var onLiveTranslatedHeaderClicked: (() -> Void)?

    /// Tracked here so the click handlers for the two mutually-exclusive
    /// modes (iOS Server, Live Caption) can show an NSAlert explaining why
    /// the click was rejected instead of silently disabling the menu item.
    private var iosServerActive: Bool = false
    private var liveCaptionActive: Bool = false
    /// Tracks which product mode is currently active. Nil = neither product
    /// is running. Drives both header checkmarks and which set of source
    /// radios shows the selection.
    private var liveCaptionActiveMode: AppConfig.CaptionMode?
    /// Tracks which source is active so radio-item checkmarks can be applied
    /// independently of the parent's active checkmark.
    private var liveCaptionActiveSource: AudioSourceKind?

    init(localEngine: Qwen3TranscriptionEngine) {
        self.localEngine = localEngine
        launchInterfaceLanguage = L10n.launchPreference
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenuItem = NSMenuItem(
            title: L10n.string("status.loading", fallback: "Loading..."),
            action: nil,
            keyEquivalent: ""
        )
        statusMenuItem.isEnabled = false

        languageMenu = NSMenu(title: L10n.string(
            "menu.speech_to_text_language",
            fallback: "Speech-to-Text Language"
        ))
        dictationEngineMenu = NSMenu(title: L10n.string(
            "menu.dictation_engine",
            fallback: "Dictation Engine"
        ))
        punctuationMenu = NSMenu(title: L10n.string(
            "menu.punctuation_cleanup",
            fallback: "Punctuation Cleanup"
        ))

        super.init()

        setupMenu()
        updateIcon(for: .idle)
        log.info("Status bar initialized")
    }

    func setState(_ state: State) {
        DispatchQueue.main.async {
            self.updateIcon(for: state)
            self.updateStatusText(for: state)
            self.updateUnloadMenuItem(for: state)
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Refresh the combined status · memory row each time the menu opens
        refreshStatusLine()
        updateDictationEngineCheckmarks()
        updateUnloadMenuItem(for: currentState)
        updateInterfaceLanguageMenu()

        // Refresh dictionary subtitle (entry count may change if user edited file externally)
        let dictSubAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        dictionarySubtitleItem.attributedTitle = NSAttributedString(
            string: "    \(dictionarySubtitleText())",
            attributes: dictSubAttrs
        )
    }

    // MARK: - Private

    /// Builds the top-level menu: 10 items + 4 separators (was ~35 flat rows).
    /// Frequent actions stay top-level; per-feature controls live in
    /// submenus per the HIG for menu bar extras. Active features show the
    /// green ✓ on the submenu PARENT so state is visible without opening it.
    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Combined status + memory row, e.g. "Ready · Memory 2.1 GB"
        refreshStatusLine()
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        // ─────────────────── Live Caption (local Qwen3) ───────────────────
        let liveCaptionTitle = L10n.string("menu.live_caption", fallback: "Live Caption")
        liveCaptionMenuItem = NSMenuItem(title: liveCaptionTitle, action: nil, keyEquivalent: "")
        updateToggleAppearance(liveCaptionMenuItem, title: liveCaptionTitle, checked: false)
        liveCaptionMenuItem.submenu = buildLiveCaptionSubmenu()
        menu.addItem(liveCaptionMenuItem)

        // ───────── Live Translated Caption (cloud OpenAI translate) ─────────
        let liveTranslatedTitle = L10n.string(
            "menu.live_translated_caption",
            fallback: "Live Translated Caption"
        )
        liveTranslatedMenuItem = NSMenuItem(title: liveTranslatedTitle, action: nil, keyEquivalent: "")
        updateToggleAppearance(liveTranslatedMenuItem, title: liveTranslatedTitle, checked: false)
        liveTranslatedMenuItem.submenu = buildLiveTranslatedSubmenu()
        menu.addItem(liveTranslatedMenuItem)

        // ─────────────────────── Text Translation ───────────────────────
        let textTranslationTitle = L10n.string("menu.text_translation", fallback: "Text Translation")
        textTranslationMenuItem = NSMenuItem(title: textTranslationTitle, action: nil, keyEquivalent: "")
        updateToggleAppearance(textTranslationMenuItem, title: textTranslationTitle, checked: AppConfig.shared.textTranslationEnabled)
        textTranslationMenuItem.submenu = buildTextTranslationSubmenu()
        menu.addItem(textTranslationMenuItem)

        textPolishMenuItem = NSMenuItem(
            title: L10n.string("menu.text_polish", fallback: "Text Polish (double-tap ⌥)"),
            action: #selector(toggleTextPolish),
            keyEquivalent: ""
        )
        textPolishMenuItem.target = self
        updateToggleAppearance(
            textPolishMenuItem,
            title: L10n.string("menu.text_polish", fallback: "Text Polish (double-tap ⌥)"),
            checked: AppConfig.shared.textPolishEnabled
        )
        textPolishMenuItem.isEnabled = TextPolisher.isAvailableCached
        menu.addItem(textPolishMenuItem)

        let polishInstructionsItem = NSMenuItem(
            title: L10n.string(
                "menu.edit_polish_instructions",
                fallback: "Edit Polish Instructions"
            ),
            action: #selector(editPolishInstructions),
            keyEquivalent: ""
        )
        polishInstructionsItem.target = self
        menu.addItem(polishInstructionsItem)

        menu.addItem(.separator())

        // ────────────────────── Dictation Settings ──────────────────────
        let dictationSettingsItem = NSMenuItem(
            title: L10n.string("menu.dictation_settings", fallback: "Dictation Settings"),
            action: nil,
            keyEquivalent: ""
        )
        dictationSettingsItem.submenu = buildDictationSettingsSubmenu()
        menu.addItem(dictationSettingsItem)

        let settingsItem = NSMenuItem(
            title: L10n.string("menu.settings", fallback: "Settings…"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // iOS Server toggle
        iosServerMenuItem = NSMenuItem(
            title: L10n.string("menu.ios_server.start", fallback: "Start iOS Server"),
            action: #selector(toggleIOSServer),
            keyEquivalent: ""
        )
        iosServerMenuItem.target = self
        menu.addItem(iosServerMenuItem)

        iosServerManager.onStatusChanged = { [weak self] running in
            DispatchQueue.main.async {
                self?.iosServerMenuItem.title = running
                    ? L10n.string("menu.ios_server.stop", fallback: "Stop iOS Server (port 8000)")
                    : L10n.string("menu.ios_server.start", fallback: "Start iOS Server")
                self?.setIOSServerActive(running)
            }
        }

        // Unload / Reload model
        let unloadTitle = L10n.string("menu.model.unload", fallback: "Unload Speech-to-Text Model")
        unloadMenuItem = NSMenuItem(title: unloadTitle, action: #selector(unloadOrReloadModel), keyEquivalent: "")
        unloadMenuItem.target = self
        let unloadAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemOrange
        ]
        unloadMenuItem.attributedTitle = NSAttributedString(string: unloadTitle, attributes: unloadAttrs)
        menu.addItem(unloadMenuItem)

        menu.addItem(.separator())

        // This preference applies on the next launch. Selection never
        // restarts, quits, or interrupts active work.
        let interfaceLanguageItem = NSMenuItem(
            title: L10n.string("menu.interface_language", fallback: "Interface Language"),
            action: nil,
            keyEquivalent: ""
        )
        interfaceLanguageItem.submenu = buildInterfaceLanguageMenu()
        menu.addItem(interfaceLanguageItem)

        // About
        let aboutItem = NSMenuItem(
            title: L10n.string("menu.about", fallback: "About HushType"),
            action: #selector(aboutClicked),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(
            title: L10n.string("menu.quit", fallback: "Quit HushType"),
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Submenu builders

    private func buildInterfaceLanguageMenu() -> NSMenu {
        interfaceLanguageMenu.removeAllItems()

        let choices: [(InterfaceLanguage, String, String)] = [
            (.system, "menu.interface_language.follow_system", "Follow System"),
            (.english, "menu.interface_language.english", "English"),
            (.traditionalChineseTaiwan, "menu.interface_language.traditional_chinese_taiwan", "繁體中文（台灣）"),
        ]
        for (language, key, fallback) in choices {
            let item = NSMenuItem(
                title: L10n.string(key, fallback: fallback),
                action: #selector(interfaceLanguageSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.rawValue
            item.onStateImage = Self.greenCheckImage
            interfaceLanguageItems[language] = item
            interfaceLanguageMenu.addItem(item)
        }

        interfaceLanguageMenu.addItem(.separator())
        appliedNextLaunchItem = NSMenuItem(
            title: L10n.string(
                "menu.interface_language.applied_next_launch",
                fallback: "Applied Next Launch"
            ),
            action: nil,
            keyEquivalent: ""
        )
        appliedNextLaunchItem.isEnabled = false
        appliedNextLaunchItem.setAccessibilityLabel(
            L10n.string(
                "menu.interface_language.applied_next_launch.accessibility",
                fallback: "Language applies the next time you open HushType"
            )
        )
        interfaceLanguageMenu.addItem(appliedNextLaunchItem)
        updateInterfaceLanguageMenu()
        return interfaceLanguageMenu
    }

    private func updateInterfaceLanguageMenu() {
        let persisted = AppConfig.shared.interfaceLanguage
        for (language, item) in interfaceLanguageItems {
            item.state = language == persisted ? .on : .off
        }
        appliedNextLaunchItem?.isHidden = !Self.shouldShowAppliedNextLaunch(
            persisted: persisted,
            launch: launchInterfaceLanguage
        )
    }

    static func shouldShowAppliedNextLaunch(
        persisted: InterfaceLanguage,
        launch: InterfaceLanguage
    ) -> Bool {
        persisted != launch
    }

    @objc private func interfaceLanguageSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selected = InterfaceLanguage(rawValue: rawValue),
              selected != AppConfig.shared.interfaceLanguage else {
            return
        }

        AppConfig.shared.interfaceLanguage = selected
        updateInterfaceLanguageMenu()
        Self.makeLanguageSavedAlert().runModal()
    }

    static func makeLanguageSavedAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.string("alert.language_saved.title", fallback: "Language Saved")
        alert.informativeText = L10n.string(
            "alert.language_saved.message",
            fallback: "It will be used the next time you open HushType. Finish any active work before quitting."
        )
        alert.alertStyle = .informational
        alert.icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        return alert
    }

    /// Small grey 10pt style shared by subtitle/secondary rows.
    private var subtitleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    }

    /// Adds a disabled small-grey description row to a (sub)menu.
    private func addSubtitle(_ text: String, to menu: NSMenu) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: subtitleAttributes)
        menu.addItem(item)
    }

    private func buildLiveCaptionSubmenu() -> NSMenu {
        let sub = NSMenu(title: L10n.string("menu.live_caption", fallback: "Live Caption"))
        addSubtitle(L10n.string(
            "menu.live_caption.subtitle",
            fallback: "Local transcription — free, on-device"
        ), to: sub)
        let startTitle = L10n.string("menu.caption.start_last_source", fallback: "Start with Last Source")
        let microphoneTitle = L10n.string("menu.caption.from_microphone", fallback: "From Microphone")
        let systemTitle = L10n.string("menu.caption.from_system_audio", fallback: "From System Audio…")
        let changeSourceTitle = L10n.string(
            "menu.caption.change_system_audio_source",
            fallback: "Change System Audio Source…"
        )

        // Replaces the old clickable header: toggles the local product with
        // the user's last-used source (mirrors the Right ⌘ + / hotkey).
        // Title flips to "Stop Live Caption" in setLiveCaptionState.
        liveCaptionStartStopItem = NSMenuItem(
            title: startTitle,
            action: #selector(liveCaptionHeaderClicked),
            keyEquivalent: ""
        )
        liveCaptionStartStopItem.target = self
        sub.addItem(liveCaptionStartStopItem)

        sub.addItem(.separator())

        liveCaptionMicItem = NSMenuItem(
            title: microphoneTitle,
            action: #selector(liveCaptionFromMicClicked),
            keyEquivalent: ""
        )
        liveCaptionMicItem.target = self
        updateRadioAppearance(liveCaptionMicItem, title: microphoneTitle, selected: false)
        sub.addItem(liveCaptionMicItem)

        liveCaptionSystemItem = NSMenuItem(
            title: systemTitle,
            action: #selector(liveCaptionFromSystemClicked),
            keyEquivalent: ""
        )
        liveCaptionSystemItem.target = self
        updateRadioAppearance(liveCaptionSystemItem, title: systemTitle, selected: false)
        sub.addItem(liveCaptionSystemItem)

        liveCaptionChangeSourceItem = NSMenuItem(
            title: changeSourceTitle,
            action: #selector(liveCaptionChangeSourceClicked),
            keyEquivalent: ""
        )
        liveCaptionChangeSourceItem.target = self
        liveCaptionChangeSourceItem.attributedTitle = NSAttributedString(
            string: changeSourceTitle,
            attributes: subtitleAttributes
        )
        sub.addItem(liveCaptionChangeSourceItem)

        sub.addItem(.separator())

        // Shared tuning file — applies to BOTH caption products, lives here
        // because the local product is the primary one.
        let tuningItem = NSMenuItem(
            title: L10n.string(
                "menu.live_caption.edit_settings",
                fallback: "Edit Live Caption Settings"
            ),
            action: #selector(editLiveCaptionSettings),
            keyEquivalent: ""
        )
        tuningItem.target = self
        tuningItem.attributedTitle = NSAttributedString(
            string: L10n.string(
                "menu.live_caption.edit_settings",
                fallback: "Edit Live Caption Settings"
            ),
            attributes: subtitleAttributes
        )
        sub.addItem(tuningItem)

        return sub
    }

    private func buildLiveTranslatedSubmenu() -> NSMenu {
        let sub = NSMenu(title: L10n.string(
            "menu.live_translated_caption",
            fallback: "Live Translated Caption"
        ))
        addSubtitle(L10n.string(
            "menu.live_translated_caption.subtitle",
            fallback: "Real-time foreign-language → text via OpenAI · $"
        ), to: sub)
        let startTitle = L10n.string("menu.caption.start_last_source", fallback: "Start with Last Source")
        let microphoneTitle = L10n.string("menu.caption.from_microphone", fallback: "From Microphone")
        let systemTitle = L10n.string("menu.caption.from_system_audio", fallback: "From System Audio…")
        let changeSourceTitle = L10n.string(
            "menu.caption.change_system_audio_source",
            fallback: "Change System Audio Source…"
        )

        liveTranslatedStartStopItem = NSMenuItem(
            title: startTitle,
            action: #selector(liveTranslatedHeaderClicked),
            keyEquivalent: ""
        )
        liveTranslatedStartStopItem.target = self
        sub.addItem(liveTranslatedStartStopItem)

        sub.addItem(.separator())

        liveTranslatedMicItem = NSMenuItem(
            title: microphoneTitle,
            action: #selector(liveTranslatedFromMicClicked),
            keyEquivalent: ""
        )
        liveTranslatedMicItem.target = self
        updateRadioAppearance(liveTranslatedMicItem, title: microphoneTitle, selected: false)
        sub.addItem(liveTranslatedMicItem)

        liveTranslatedSystemItem = NSMenuItem(
            title: systemTitle,
            action: #selector(liveTranslatedFromSystemClicked),
            keyEquivalent: ""
        )
        liveTranslatedSystemItem.target = self
        updateRadioAppearance(liveTranslatedSystemItem, title: systemTitle, selected: false)
        sub.addItem(liveTranslatedSystemItem)

        liveTranslatedChangeSourceItem = NSMenuItem(
            title: changeSourceTitle,
            action: #selector(liveTranslatedChangeSourceClicked),
            keyEquivalent: ""
        )
        liveTranslatedChangeSourceItem.target = self
        liveTranslatedChangeSourceItem.attributedTitle = NSAttributedString(
            string: changeSourceTitle,
            attributes: subtitleAttributes
        )
        sub.addItem(liveTranslatedChangeSourceItem)

        sub.addItem(.separator())

        // Translated Caption Settings — cloud-only options: target language,
        // source-line toggle, cost guardrails, OpenAI key file.
        let translatedSettingsItem = NSMenuItem(
            title: L10n.string(
                "menu.live_translated_caption.settings",
                fallback: "Translated Caption Settings…"
            ),
            action: #selector(openLiveCaptionEngineSettings),
            keyEquivalent: ""
        )
        translatedSettingsItem.target = self
        translatedSettingsItem.attributedTitle = NSAttributedString(
            string: L10n.string(
                "menu.live_translated_caption.settings",
                fallback: "Translated Caption Settings…"
            ),
            attributes: subtitleAttributes
        )
        sub.addItem(translatedSettingsItem)

        return sub
    }

    private func buildTextTranslationSubmenu() -> NSMenu {
        let sub = NSMenu(title: L10n.string("menu.text_translation", fallback: "Text Translation"))
        addSubtitle(L10n.string(
            "menu.text_translation.subtitle",
            fallback: "via Apple Translation Framework"
        ), to: sub)

        textTranslationEnableItem = NSMenuItem(
            title: L10n.string(
                "menu.text_translation.enable",
                fallback: "Enable Text Translation"
            ),
            action: #selector(toggleTextTranslation),
            keyEquivalent: ""
        )
        textTranslationEnableItem.target = self
        updateToggleAppearance(
            textTranslationEnableItem,
            title: L10n.string("menu.text_translation.enable", fallback: "Enable Text Translation"),
            checked: AppConfig.shared.textTranslationEnabled
        )
        sub.addItem(textTranslationEnableItem)

        // Translate-to submenu
        let translateToTitle = L10n.string("menu.translate_to", fallback: "Translate to")
        translateToItem = NSMenuItem(title: translateToTitle, action: nil, keyEquivalent: "")
        let translateToMenu = NSMenu(title: translateToTitle)
        let translateTargets: [(title: String, value: String?)] = [
            (L10n.string("menu.choice.auto", fallback: "Auto"), nil),
            (L10n.string("picker.autonym.en", fallback: "English"), "en"),
            ("繁體中文", "zh-Hant-TW"),
            (L10n.string("picker.autonym.ja", fallback: "日本語"), "ja"),
            (L10n.string("picker.autonym.ko", fallback: "한국어"), "ko"),
            (L10n.string("picker.autonym.fr", fallback: "Français"), "fr"),
            (L10n.string("picker.autonym.de", fallback: "Deutsch"), "de"),
            (L10n.string("picker.autonym.es", fallback: "Español"), "es"),
        ]
        for (title, value) in translateTargets {
            let item = NSMenuItem(title: title, action: #selector(translateTargetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            translateToMenu.addItem(item)
        }
        translateToItem.submenu = translateToMenu
        updateTranslateToCheckmarks()
        sub.addItem(translateToItem)

        // Translation hotkey hint
        translationHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        translationHintItem.isEnabled = false
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        translationHintItem.attributedTitle = NSAttributedString(
            string: L10n.string(
                "menu.translation_hint",
                fallback: "Tap Right ⌥ to translate selection"
            ),
            attributes: hintAttrs
        )
        sub.addItem(translationHintItem)

        // Show/hide translation sub-items based on toggle state
        updateTranslationSubItems()

        return sub
    }

    private func buildDictationSettingsSubmenu() -> NSMenu {
        let sub = NSMenu(title: L10n.string("menu.dictation_settings", fallback: "Dictation Settings"))

        let engineItem = NSMenuItem(
            title: L10n.string("menu.dictation_engine", fallback: "Dictation Engine"),
            action: nil,
            keyEquivalent: ""
        )
        engineItem.submenu = dictationEngineMenu
        let engines: [(String, AppConfig.DictationEngine)] = [
            (L10n.string("menu.engine.local_qwen", fallback: "Local (Qwen3-ASR)"), .local),
            (L10n.string("menu.engine.openai_cloud", fallback: "OpenAI Cloud"), .openai),
            (L10n.string("menu.engine.gemini_cloud", fallback: "Gemini Cloud"), .gemini),
        ]
        for (title, engine) in engines {
            let item = NSMenuItem(
                title: title,
                action: #selector(dictationEngineSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = engine.rawValue
            dictationEngineMenu.addItem(item)
            dictationEngineItems.append(item)
        }
        dictationEngineMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: L10n.string("menu.engine_settings", fallback: "Engine Settings…"),
            action: #selector(openDictationEngineSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        dictationEngineMenu.addItem(settingsItem)
        updateDictationEngineCheckmarks()
        sub.addItem(engineItem)

        sub.addItem(.separator())

        // Language submenu
        let languageItem = NSMenuItem(
            title: L10n.string("menu.speech_to_text_language", fallback: "Speech-to-Text Language"),
            action: nil,
            keyEquivalent: ""
        )
        languageItem.submenu = languageMenu

        let languages: [(title: String, value: String?)] = [
            (L10n.string("menu.choice.auto", fallback: "Auto"), nil),
            (L10n.string("picker.autonym.en", fallback: "English"), "english"),
            (L10n.string("picker.autonym.zh", fallback: "中文"), "chinese"),
            (L10n.string("picker.autonym.ja", fallback: "日本語"), "japanese"),
        ]

        for (title, value) in languages {
            let item = NSMenuItem(title: title, action: #selector(languageSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            languageMenu.addItem(item)
            languageItems.append(item)
        }

        updateLanguageCheckmarks()
        sub.addItem(languageItem)

        sub.addItem(.separator())

        // Number Conversion toggle (deterministic ITN)
        numberConversionMenuItem = NSMenuItem(
            title: L10n.string("menu.number_conversion", fallback: "Number Conversion"),
            action: #selector(toggleNumberConversion),
            keyEquivalent: ""
        )
        numberConversionMenuItem.target = self
        updateToggleAppearance(
            numberConversionMenuItem,
            title: L10n.string("menu.number_conversion", fallback: "Number Conversion"),
            checked: AppConfig.shared.numberConversionEnabled
        )
        sub.addItem(numberConversionMenuItem)
        addSubtitle("    " + L10n.string(
            "menu.number_conversion.subtitle",
            fallback: "Chinese numerals → Arabic digits"
        ), to: sub)

        // Punctuation Cleanup mode (Chinese only; soft/hard/off radio)
        let punctuationItem = NSMenuItem(
            title: L10n.string("menu.punctuation_cleanup", fallback: "Punctuation Cleanup"),
            action: nil,
            keyEquivalent: ""
        )
        punctuationItem.submenu = punctuationMenu

        let punctModes: [(title: String, value: String)] = [
            (L10n.string("menu.punctuation.soft", fallback: "Soft — trim inline commas"), "soft"),
            (L10n.string("menu.punctuation.hard", fallback: "Hard — trim all marks"), "hard"),
            (L10n.string("menu.punctuation.off", fallback: "Off — keep model output"), "off"),
        ]
        for (title, value) in punctModes {
            let item = NSMenuItem(title: title, action: #selector(punctuationModeSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            punctuationMenu.addItem(item)
            punctuationItems.append(item)
        }
        updatePunctuationCheckmarks()
        sub.addItem(punctuationItem)
        addSubtitle("    " + L10n.string(
            "menu.punctuation.subtitle",
            fallback: "Trim Chinese over-punctuation"
        ), to: sub)

        // Floating overlay toggle
        floatingOverlayMenuItem = NSMenuItem(
            title: L10n.string("menu.floating_indicator", fallback: "Show Floating Indicator"),
            action: #selector(toggleFloatingOverlay),
            keyEquivalent: ""
        )
        floatingOverlayMenuItem.target = self
        updateToggleAppearance(
            floatingOverlayMenuItem,
            title: L10n.string("menu.floating_indicator", fallback: "Show Floating Indicator"),
            checked: AppConfig.shared.floatingOverlayEnabled
        )
        sub.addItem(floatingOverlayMenuItem)

        sub.addItem(.separator())

        // Edit Customized Dictionary
        dictionaryMenuItem = NSMenuItem(
            title: L10n.string("menu.edit_dictionary", fallback: "Edit Customized Dictionary"),
            action: #selector(editDictionary),
            keyEquivalent: ""
        )
        dictionaryMenuItem.target = self
        sub.addItem(dictionaryMenuItem)

        // Dictionary subtitle (entry count or "no file")
        dictionarySubtitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        dictionarySubtitleItem.isEnabled = false
        dictionarySubtitleItem.attributedTitle = NSAttributedString(
            string: "    \(dictionarySubtitleText())",
            attributes: subtitleAttributes
        )
        sub.addItem(dictionarySubtitleItem)

        return sub
    }

    // MARK: - Dictation Engine

    @objc private func openSettings() {
        Task { @MainActor in
            HushTypeSettingsWindowController.shared.presentAndFocus()
        }
    }

    @objc private func dictationEngineSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = AppConfig.DictationEngine(rawValue: raw) else { return }
        onDictationEngineChanged?(engine)
        updateDictationEngineCheckmarks()
        refreshStatusLine()
        updateUnloadMenuItem(for: currentState)
    }

    @objc private func openDictationEngineSettings() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            DictationEngineSettingsWindowController.shared.presentAndFocus(
                onSwitchEngine: { [weak self] engine in
                    guard let self else { return }
                    self.onDictationEngineChanged?(engine)
                    self.updateDictationEngineCheckmarks()
                    self.refreshStatusLine()
                    self.updateUnloadMenuItem(for: self.currentState)
                }
            )
        }
    }

    private func updateDictationEngineCheckmarks() {
        let selected = AppConfig.shared.dictationEngine.rawValue
        for item in dictationEngineItems {
            let raw = item.representedObject as? String
            updateRadioAppearance(item, title: item.title, selected: raw == selected)
        }
    }

    // MARK: - Language

    @objc private func languageSelected(_ sender: NSMenuItem) {
        let value = sender.representedObject as? String
        AppConfig.shared.language = value
        updateLanguageCheckmarks()
        onLanguageChanged?(value)
        log.info("Language changed to: \(value ?? "auto")")
    }

    // MARK: - iOS Server

    @objc private func toggleIOSServer() {
        if iosServerManager.isRunning {
            iosServerManager.stop()
            return
        }
        // Mutex: can't start iOS server while live caption is active.
        if liveCaptionActive {
            showMutexAlert(
                title: L10n.string(
                    "alert.caption_conflict.stop_live_caption.title",
                    fallback: "Stop Live Caption first"
                ),
                message: L10n.string(
                    "alert.caption_conflict.stop_live_caption.message",
                    fallback: "Live Caption is running. Stop it before starting the iOS Server — they share GPU memory."
                )
            )
            return
        }
        iosServerManager.start(port: 8000)
    }

    // MARK: - Live Caption

    @objc private func toggleLiveCaption() {
        // Legacy path — kept for any callers not yet migrated. New menu uses
        // the radio sub-items, not this entry point.
        if liveCaptionActive {
            onLiveCaptionStop?()
            return
        }
        if iosServerActive {
            showMutexAlert(
                title: L10n.string(
                    "alert.caption_conflict.stop_ios_server.title",
                    fallback: "Stop iOS Server first"
                ),
                message: L10n.string(
                    "alert.caption_conflict.stop_ios_server.local_message",
                    fallback: "The iOS Server is running. Stop it before starting Live Caption — they share GPU memory."
                )
            )
            return
        }
        onLiveCaptionToggle?()
    }

    @objc private func liveCaptionFromMicClicked() {
        // If the LOCAL product is already running on mic → toggle off. Toggle
        // semantics are now product-scoped: clicking translated-mic while
        // local-mic is active is "start translated" not "stop local"; the
        // start handler in AppDelegate auto-stops the other product first.
        if liveCaptionActiveMode == .local, case .mic = liveCaptionActiveSource {
            onLiveCaptionStop?()
            return
        }
        if iosServerActive {
            showMutexAlert(
                title: L10n.string("alert.caption_conflict.stop_ios_server.title", fallback: "Stop iOS Server first"),
                message: L10n.string("alert.caption_conflict.stop_ios_server.local_message", fallback: "The iOS Server is running. Stop it before starting Live Caption — they share GPU memory.")
            )
            return
        }
        onLiveCaptionStartMic?()
    }

    @objc private func liveCaptionFromSystemClicked() {
        if liveCaptionActiveMode == .local, case .system = liveCaptionActiveSource {
            onLiveCaptionStop?()
            return
        }
        if iosServerActive {
            showMutexAlert(
                title: L10n.string("alert.caption_conflict.stop_ios_server.title", fallback: "Stop iOS Server first"),
                message: L10n.string("alert.caption_conflict.stop_ios_server.local_message", fallback: "The iOS Server is running. Stop it before starting Live Caption — they share GPU memory.")
            )
            return
        }
        onLiveCaptionStartSystem?()
    }

    @objc private func liveCaptionChangeSourceClicked() {
        onLiveCaptionChangeSystemSource?()
    }

    @objc private func liveTranslatedFromMicClicked() {
        if liveCaptionActiveMode == .translated, case .mic = liveCaptionActiveSource {
            onLiveTranslatedStop?()
            return
        }
        if iosServerActive {
            showMutexAlert(
                title: L10n.string("alert.caption_conflict.stop_ios_server.title", fallback: "Stop iOS Server first"),
                message: L10n.string("alert.caption_conflict.stop_ios_server.translated_message", fallback: "The iOS Server is running. Stop it before starting Live Translated Caption — they share GPU memory.")
            )
            return
        }
        onLiveTranslatedStartMic?()
    }

    @objc private func liveTranslatedFromSystemClicked() {
        if liveCaptionActiveMode == .translated, case .system = liveCaptionActiveSource {
            onLiveTranslatedStop?()
            return
        }
        if iosServerActive {
            showMutexAlert(
                title: L10n.string("alert.caption_conflict.stop_ios_server.title", fallback: "Stop iOS Server first"),
                message: L10n.string("alert.caption_conflict.stop_ios_server.translated_message", fallback: "The iOS Server is running. Stop it before starting Live Translated Caption — they share GPU memory.")
            )
            return
        }
        onLiveTranslatedStartSystem?()
    }

    @objc private func liveTranslatedChangeSourceClicked() {
        onLiveTranslatedChangeSystemSource?()
    }

    @objc private func liveCaptionHeaderClicked() {
        // If local is currently running, treat this as the explicit Stop.
        if liveCaptionActiveMode == .local {
            onLiveCaptionStop?()
            return
        }
        if iosServerActive {
            showMutexAlert(
                title: L10n.string("alert.caption_conflict.stop_ios_server.title", fallback: "Stop iOS Server first"),
                message: L10n.string("alert.caption_conflict.stop_ios_server.local_message", fallback: "The iOS Server is running. Stop it before starting Live Caption — they share GPU memory.")
            )
            return
        }
        onLiveCaptionHeaderClicked?()
    }

    @objc private func liveTranslatedHeaderClicked() {
        if liveCaptionActiveMode == .translated {
            onLiveTranslatedStop?()
            return
        }
        if iosServerActive {
            showMutexAlert(
                title: L10n.string("alert.caption_conflict.stop_ios_server.title", fallback: "Stop iOS Server first"),
                message: L10n.string("alert.caption_conflict.stop_ios_server.translated_message", fallback: "The iOS Server is running. Stop it before starting Live Translated Caption — they share GPU memory.")
            )
            return
        }
        onLiveTranslatedHeaderClicked?()
    }

    /// Legacy single-boolean form. Assumes the local product. Preferred:
    /// `setLiveCaptionState(mode:source:)`.
    func setLiveCaptionActive(_ active: Bool) {
        setLiveCaptionState(mode: active ? .local : nil, source: active ? .mic : nil)
    }

    /// Called from `LiveCaptionManager.onStateChanged`. Lights up the right
    /// header checkmark + the right product's source radio. Nil mode = nothing
    /// running. Also tracks state for the iOS Server mutex gate.
    func setLiveCaptionState(mode: AppConfig.CaptionMode?, source: AudioSourceKind?) {
        liveCaptionActiveMode = mode
        liveCaptionActiveSource = source
        liveCaptionActive = (mode != nil)

        let localActive = (mode == .local)
        let translatedActive = (mode == .translated)

        if let parent = liveCaptionMenuItem {
            updateToggleAppearance(
                parent,
                title: L10n.string("menu.live_caption", fallback: "Live Caption"),
                checked: localActive
            )
        }
        if let parent = liveTranslatedMenuItem {
            updateToggleAppearance(
                parent,
                title: L10n.string("menu.live_translated_caption", fallback: "Live Translated Caption"),
                checked: translatedActive
            )
        }
        if let item = liveCaptionStartStopItem {
            item.title = localActive
                ? L10n.string("menu.live_caption.stop", fallback: "Stop Live Caption")
                : L10n.string("menu.caption.start_last_source", fallback: "Start with Last Source")
        }
        if let item = liveTranslatedStartStopItem {
            item.title = translatedActive
                ? L10n.string("menu.live_translated_caption.stop", fallback: "Stop Live Translated Caption")
                : L10n.string("menu.caption.start_last_source", fallback: "Start with Last Source")
        }

        let sourceIsMic: Bool
        let sourceIsSystem: Bool
        switch source {
        case .mic:           sourceIsMic = true;  sourceIsSystem = false
        case .system:        sourceIsMic = false; sourceIsSystem = true
        case .none:          sourceIsMic = false; sourceIsSystem = false
        }
        let localMicSelected = localActive && sourceIsMic
        let localSystemSelected = localActive && sourceIsSystem
        let translatedMicSelected = translatedActive && sourceIsMic
        let translatedSystemSelected = translatedActive && sourceIsSystem

        if let item = liveCaptionMicItem {
            updateRadioAppearance(item, title: L10n.string("menu.caption.from_microphone", fallback: "From Microphone"), selected: localMicSelected)
        }
        if let item = liveCaptionSystemItem {
            updateRadioAppearance(item, title: L10n.string("menu.caption.from_system_audio", fallback: "From System Audio…"), selected: localSystemSelected)
        }
        if let item = liveTranslatedMicItem {
            updateRadioAppearance(item, title: L10n.string("menu.caption.from_microphone", fallback: "From Microphone"), selected: translatedMicSelected)
        }
        if let item = liveTranslatedSystemItem {
            updateRadioAppearance(item, title: L10n.string("menu.caption.from_system_audio", fallback: "From System Audio…"), selected: translatedSystemSelected)
        }
    }

    /// Back-compat shim so existing call sites that just pass an AudioSourceKind
    /// (e.g. earlier tests) still work. Assumes the local product when source
    /// is non-nil — new call sites should use `setLiveCaptionState(mode:source:)`.
    func setLiveCaptionActiveSource(_ source: AudioSourceKind?) {
        setLiveCaptionState(mode: source.map { _ in .local }, source: source)
    }

    /// Called from the existing `iosServerManager.onStatusChanged` closure.
    /// Tracks state for the Live Caption mutex check.
    func setIOSServerActive(_ active: Bool) {
        iosServerActive = active
    }

    @objc private func openLiveCaptionEngineSettings() {
        // Lazy-instantiate via the singleton accessor. Window retains itself
        // (`isReleasedWhenClosed = false`) so reopening from this menu just
        // re-foregrounds the same window with its persisted frame.
        Task { @MainActor in
            LiveCaptionEngineSettingsWindowController.shared.presentAndFocus()
        }
    }

    @objc private func editLiveCaptionSettings() {
        // Mirror the Edit Customized Dictionary flow: create the template on
        // first use so the user sees the documented schema immediately, then
        // open the file in their default text editor.
        LiveCaptionTuning.createTemplateIfMissing()

        let url = LiveCaptionTuning.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert(
                title: L10n.string("alert.file_create.live_caption.title", fallback: "Could not open Live Caption settings"),
                message: L10n.format(
                    "alert.file_create.live_caption.message",
                    "Failed to create the settings file at:\n%1$@",
                    arguments: [url.path]
                )
            )
            return
        }
        NSWorkspace.shared.open(url)
        log.info("Opened live_caption.json in default editor")
    }

    private func showMutexAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }

    // MARK: - Floating Overlay

    @objc private func toggleFloatingOverlay() {
        let newValue = !AppConfig.shared.floatingOverlayEnabled
        AppConfig.shared.floatingOverlayEnabled = newValue
        updateToggleAppearance(
            floatingOverlayMenuItem,
            title: L10n.string("menu.floating_indicator", fallback: "Show Floating Indicator"),
            checked: newValue
        )
    }

    // MARK: - Number Conversion

    @objc private func toggleNumberConversion() {
        let newValue = !AppConfig.shared.numberConversionEnabled
        AppConfig.shared.numberConversionEnabled = newValue
        updateToggleAppearance(
            numberConversionMenuItem,
            title: L10n.string("menu.number_conversion", fallback: "Number Conversion"),
            checked: newValue
        )
    }

    // MARK: - Punctuation Cleanup

    @objc private func punctuationModeSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PunctuationMode(rawValue: raw) else { return }
        AppConfig.shared.punctuationMode = mode
        updatePunctuationCheckmarks()
        log.info("Punctuation mode changed to: \(mode.rawValue, privacy: .public)")
    }

    private func updatePunctuationCheckmarks() {
        let current = AppConfig.shared.punctuationMode.rawValue
        for item in punctuationItems {
            let value = item.representedObject as? String
            updateRadioAppearance(item, title: item.title, selected: value == current)
        }
    }

    // MARK: - Text Translation

    @objc private func toggleTextPolish() {
        if AppConfig.shared.textPolishEnabled {
            AppConfig.shared.textPolishEnabled = false
            updateToggleAppearance(
                textPolishMenuItem,
                title: L10n.string("menu.text_polish", fallback: "Text Polish (double-tap ⌥)"),
                checked: false
            )
            if #available(macOS 26.0, *) {
                Task { @MainActor in FoundationModelsPolisher.releaseSession() }
            }
            return
        }

        textPolishMenuItem.isEnabled = false
        let originalTitle = textPolishMenuItem.title
        textPolishMenuItem.title = L10n.string(
            "menu.text_polish.validating",
            fallback: "Text Polish (validating…)"
        )

        Task { @MainActor in
            let result = await TextPolisher.validate()
            self.textPolishMenuItem.title = originalTitle

            switch result {
            case .ok:
                AppConfig.shared.textPolishEnabled = true
                self.updateToggleAppearance(
                    self.textPolishMenuItem,
                    title: L10n.string("menu.text_polish", fallback: "Text Polish (double-tap ⌥)"),
                    checked: true
                )
                self.textPolishMenuItem.isEnabled = true
                if #available(macOS 26.0, *) {
                    FoundationModelsPolisher.warmup()
                }
            case .unavailable(let reason):
                self.textPolishMenuItem.isEnabled = false
                self.showAlert(
                    title: L10n.string(
                        "alert.text_polish.unavailable.title",
                        fallback: "Text Polish unavailable"
                    ),
                    message: L10n.format(
                        "alert.text_polish.unavailable.message",
                        "Text Polish requires macOS 26 + Apple Intelligence.\n\n%1$@",
                        arguments: [reason]
                    )
                )
            }
        }
    }

    func setTextPolishAvailability(_ available: Bool) {
        textPolishMenuItem.isEnabled = available
        updateToggleAppearance(
            textPolishMenuItem,
            title: L10n.string("menu.text_polish", fallback: "Text Polish (double-tap ⌥)"),
            checked: AppConfig.shared.textPolishEnabled
        )
    }

    @objc private func toggleTextTranslation() {
        let newValue = !AppConfig.shared.textTranslationEnabled
        AppConfig.shared.textTranslationEnabled = newValue
        // ✓ on both the submenu parent (visible at top level) and the
        // Enable item inside the submenu.
        updateToggleAppearance(
            textTranslationMenuItem,
            title: L10n.string("menu.text_translation", fallback: "Text Translation"),
            checked: newValue
        )
        updateToggleAppearance(
            textTranslationEnableItem,
            title: L10n.string("menu.text_translation.enable", fallback: "Enable Text Translation"),
            checked: newValue
        )
        updateTranslationSubItems()
    }

    @objc private func translateTargetSelected(_ sender: NSMenuItem) {
        let value = sender.representedObject as? String
        AppConfig.shared.translateTargetLanguage = value
        updateTranslateToCheckmarks()
    }

    private func updateTranslationSubItems() {
        let enabled = AppConfig.shared.textTranslationEnabled
        translateToItem.isHidden = !enabled
        translationHintItem.isHidden = !enabled
    }

    private func updateTranslateToCheckmarks() {
        guard let menu = translateToItem.submenu else { return }
        let current = AppConfig.shared.translateTargetLanguage
        for item in menu.items {
            let itemValue = item.representedObject as? String
            item.state = (itemValue == current) ? .on : .off
        }
    }

    // MARK: - Customized Dictionary

    /// Returns the subtitle text shown beneath "Edit Customized Dictionary".
    /// Reads from `DictionaryReplacer` so it always reflects the current file
    /// state — including external edits between menu opens.
    private func dictionarySubtitleText() -> String {
        if !DictionaryReplacer.fileExists {
            return L10n.string("menu.dictionary.no_file", fallback: "No dictionary file")
        }
        let count = DictionaryReplacer.entryCount
        return L10n.plural(
            "menu.dictionary.entries_loaded",
            count,
            fallback: count == 1 ? "%1$ld entry loaded" : "%1$ld entries loaded"
        )
    }

    @objc private func editDictionary() {
        // Create the file with the friendly template if it doesn't exist yet,
        // so first-time users immediately see the format documented inline.
        DictionaryReplacer.createTemplateIfMissing()

        let url = AppConfig.dictionaryFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Template creation failed — show error
            showAlert(
                title: L10n.string("alert.file_create.dictionary.title", fallback: "Could not open dictionary"),
                message: L10n.format(
                    "alert.file_create.dictionary.message",
                    "Failed to create the dictionary file at:\n%1$@",
                    arguments: [url.path]
                )
            )
            return
        }

        // Open in the user's default text editor
        NSWorkspace.shared.open(url)
        log.info("Opened dictionary file in default editor")
    }

    // MARK: - Polish Instructions

    @objc private func editPolishInstructions() {
        // Mirror the Edit Customized Dictionary flow: create the documented
        // template on first use, then open in the default text editor.
        PolishPrompt.createRulesTemplateIfMissing()

        let url = PolishPrompt.rulesFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert(
                title: L10n.string("alert.file_create.polish.title", fallback: "Could not open Polish instructions"),
                message: L10n.format(
                    "alert.file_create.polish.message",
                    "Failed to create the instructions file at:\n%1$@",
                    arguments: [url.path]
                )
            )
            return
        }

        NSWorkspace.shared.open(url)
        log.info("Opened polish rules file in default editor")
    }

    // MARK: - Unload / Reload Model

    @objc private func unloadOrReloadModel() {
        switch modelMenuAction {
        case .unload:
            onUnloadModel?()
        case .reload:
            onReloadModel?()
        }
    }

    /// Called by AppDelegate after successful unload to update menu state.
    func setModelUnloaded() {
        modelMenuAction = .reload
        let reloadAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemGreen
        ]
        let title = L10n.string("menu.model.reload", fallback: "Reload Speech-to-Text Model")
        unloadMenuItem.title = title
        unloadMenuItem.attributedTitle = NSAttributedString(string: title, attributes: reloadAttrs)
    }

    /// Called by AppDelegate after successful reload to restore menu state.
    func setModelLoaded() {
        modelMenuAction = .unload
        let unloadAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemOrange
        ]
        let title = L10n.string("menu.model.unload", fallback: "Unload Speech-to-Text Model")
        unloadMenuItem.title = title
        unloadMenuItem.attributedTitle = NSAttributedString(string: title, attributes: unloadAttrs)
    }

    // MARK: - Helpers

    /// Green checkmark for the menu's leading state column. Rendered from the
    /// SF Symbol as a non-template image so the menu doesn't recolor it.
    private static let greenCheckImage: NSImage = {
        let symbol = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: L10n.string(
                "accessibility.checkmark.enabled",
                fallback: "enabled"
            )
        )!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))!
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.systemGreen.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }()

    /// Update a toggle menu item to show a green ✓ in the native state column.
    /// Titles stay in the default menu font: a trailing ✓ suffix sat at a
    /// different x-position per title, and the old 14pt attributed title made
    /// checked items render larger than their neighbors.
    private func updateToggleAppearance(_ item: NSMenuItem, title: String, checked: Bool) {
        item.view = nil    // ensure no custom view blocks click handling
        item.attributedTitle = nil
        item.title = title
        item.onStateImage = Self.greenCheckImage
        item.state = checked ? .on : .off
    }

    /// Update a radio-style sub-menu item (12pt secondary font; the items
    /// live inside submenus now, so no manual indent). Selection shows the
    /// same green ✓ in the state column as the toggles.
    private func updateRadioAppearance(_ item: NSMenuItem, title: String, selected: Bool) {
        item.view = nil

        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])
        item.onStateImage = Self.greenCheckImage
        item.state = selected ? .on : .off
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }

    @objc private func aboutClicked() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = L10n.format(
            "about.title",
            "HushType v%1$@",
            arguments: [version]
        )
        alert.informativeText = L10n.string(
            "about.body",
            fallback: "Local voice-to-text for macOS and iOS.\nMultilingual (EN/ZH/JP) with Traditional Chinese output.\n\nAuthor: Felix Fu\nCo-authored with: Claude (Anthropic)\nLicense: MIT\n\ngithub.com/felixfu824/HushType"
        )
        alert.icon = NSImage(named: "AppIcon") ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        // First button is the default (Return key). Order matters for keyboard handling.
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.addButton(withTitle: L10n.string(
            "about.check_updates",
            fallback: "Check for Updates"
        ))

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            checkForUpdates()
        }
    }

    // MARK: - Version Check

    /// Two-stage flow: explicit consent dialog → if approved, fetch + show
    /// result. The consent dialog is asked EVERY time and defaults to Cancel
    /// (privacy-conservative). No persistent "remember my choice" — see
    /// SPEC_version-check.md for rationale.
    private func checkForUpdates() {
        let consent = NSAlert()
        consent.messageText = L10n.string(
            "alert.update_consent.title",
            fallback: "Connect to GitHub?"
        )
        consent.informativeText = L10n.string(
            "alert.update_consent.message",
            fallback: "HushType will connect to GitHub to check for new releases.\n\nNo personal data is sent — only a public API call to compare version numbers."
        )
        consent.alertStyle = .informational
        consent.icon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        // Cancel is the FIRST button so it becomes the default button (Return key).
        // This is the privacy-conservative default — user must explicitly choose to connect.
        consent.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        consent.addButton(withTitle: L10n.string(
            "alert.update_consent.check_now",
            fallback: "Check Now"
        ))

        guard consent.runModal() == .alertSecondButtonReturn else {
            log.info("User declined version check consent")
            return
        }

        log.info("User approved version check — fetching")

        Task { @MainActor in
            do {
                let result = try await VersionChecker.check()
                if result.isUpToDate {
                    self.showUpToDate(version: result.currentVersion)
                } else {
                    self.showUpdateAvailable(version: result.latestVersion, url: result.releaseURL)
                }
            } catch {
                self.showCheckError(error)
            }
        }
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
        // First button = default (View on GitHub) — most users want to see the release
        alert.addButton(withTitle: L10n.string(
            "alert.update.view_github",
            fallback: "View on GitHub"
        ))
        alert.addButton(withTitle: L10n.string("common.button.later", fallback: "Later"))

        if alert.runModal() == .alertFirstButtonReturn {
            if let url {
                NSWorkspace.shared.open(url)
            } else {
                // Fallback to releases page if specific URL is missing
                if let fallback = URL(string: "https://github.com/felixfu824/HushType/releases") {
                    NSWorkspace.shared.open(fallback)
                }
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
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        alert.informativeText = L10n.format(
            "alert.update.error.message",
            "Unable to connect to GitHub.\n\n%1$@\n\nCheck your internet connection and try again.",
            arguments: [error.localizedDescription]
        )
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }

    @objc private func quitClicked() {
        iosServerManager.stop()
        onQuit?()
        NSApp.terminate(nil)
    }

    private func updateLanguageCheckmarks() {
        let current = AppConfig.shared.language
        for item in languageItems {
            let itemValue = item.representedObject as? String
            item.state = (itemValue == current) ? .on : .off
        }
    }

    private func updateIcon(for state: State) {
        guard let button = statusItem.button else { return }

        let symbolName: String
        switch state {
        case .loading:
            symbolName = "arrow.down.circle"
        case .idle:
            symbolName = "mic.fill"
        case .recording:
            symbolName = "record.circle"
        case .transcribing:
            symbolName = "ellipsis.circle"
        case .polishing:
            symbolName = "wand.and.sparkles"
        case .error:
            symbolName = "exclamationmark.triangle"
        case .unloaded:
            symbolName = "mic.slash"
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "HushType")
    }

    private func updateStatusText(for state: State) {
        currentState = state
        refreshStatusLine()
    }

    private func statusText(for state: State) -> String {
        switch state {
        case .loading(let progress):
            return L10n.format(
                "status.loading_model_percent",
                "Loading model (%1$d%%)...",
                arguments: [Int32(Int(progress * 100))]
            )
        case .idle:
            return L10n.string("status.ready", fallback: "Ready")
        case .recording:
            return L10n.string("status.recording", fallback: "Recording...")
        case .transcribing:
            return L10n.string("status.transcribing", fallback: "Transcribing...")
        case .polishing:
            return L10n.string("status.polishing", fallback: "Polishing…")
        case .error(let msg):
            return L10n.format("status.error", "Error: %1$@", arguments: [msg])
        case .unloaded:
            return L10n.string("status.model_unloaded", fallback: "Model unloaded")
        }
    }

    /// Re-renders the combined "<status> · Memory <footprint>" row.
    private func refreshStatusLine() {
        switch AppConfig.shared.dictationEngine {
        case .local:
            statusMenuItem.title = L10n.format(
                "status.memory",
                "%1$@ · Memory %2$@",
                arguments: [statusText(for: currentState), MemoryUtils.formattedMemory()]
            )
        case .openai:
            let modelStatus = localEngine.isLoaded
                ? L10n.format(
                    "status.model_loaded_memory",
                    "Model loaded (%1$@)",
                    arguments: [MemoryUtils.formattedMemory()]
                )
                : L10n.string("status.no_model_loaded", fallback: "No model loaded")
            statusMenuItem.title = L10n.format(
                "status.cloud_engine",
                "%1$@ · Cloud (%2$@) · %3$@",
                arguments: [statusText(for: currentState), "OpenAI", modelStatus]
            )
        case .gemini:
            let modelStatus = localEngine.isLoaded
                ? L10n.format(
                    "status.model_loaded_memory",
                    "Model loaded (%1$@)",
                    arguments: [MemoryUtils.formattedMemory()]
                )
                : L10n.string("status.no_model_loaded", fallback: "No model loaded")
            statusMenuItem.title = L10n.format(
                "status.cloud_engine",
                "%1$@ · Cloud (%2$@) · %3$@",
                arguments: [statusText(for: currentState), "Gemini", modelStatus]
            )
        }
    }

    private func updateUnloadMenuItem(for state: State) {
        let localModelLoaded = localEngine.isLoaded
        if !localModelLoaded {
            let localSelected = AppConfig.shared.dictationEngine == .local
            unloadMenuItem.isHidden = !localSelected
            if localSelected {
                if case .loading = state {
                    setModelLoaded()
                    unloadMenuItem.isEnabled = false
                } else {
                    setModelUnloaded()
                    unloadMenuItem.isEnabled = true
                }
            } else {
                unloadMenuItem.isEnabled = false
            }
            return
        }

        unloadMenuItem.isHidden = false
        setModelLoaded()
        switch state {
        case .idle, .unloaded:
            unloadMenuItem.isEnabled = true
        case .loading:
            unloadMenuItem.isEnabled = false
        default:
            unloadMenuItem.isEnabled = false
        }
    }
}
