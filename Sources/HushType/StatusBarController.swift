import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "statusbar")

final class StatusBarController: NSObject, NSMenuDelegate {
    enum State {
        case loading(Double) // progress 0.0–1.0
        case idle
        case recording
        case transcribing
        case error(String)
        case unloaded
    }

    private let statusItem: NSStatusItem
    private let statusMenuItem: NSMenuItem
    private let memoryMenuItem: NSMenuItem
    private let languageMenu: NSMenu
    private var languageItems: [NSMenuItem] = []
    private var iosServerMenuItem: NSMenuItem!
    private var floatingOverlayMenuItem: NSMenuItem!
    private var numberConversionMenuItem: NSMenuItem!
    private var aiCleanupMenuItem: NSMenuItem!
    private var liveCaptionMenuItem: NSMenuItem!
    private var liveCaptionSubtitleItem: NSMenuItem!
    private var liveCaptionMicItem: NSMenuItem!
    private var liveCaptionSystemItem: NSMenuItem!
    private var liveCaptionChangeSourceItem: NSMenuItem!
    private var textTranslationMenuItem: NSMenuItem!
    private var translationSubtitleItem: NSMenuItem!
    private var translateToItem: NSMenuItem!
    private var translationHintItem: NSMenuItem!
    private var unloadMenuItem: NSMenuItem!
    private var dictionaryMenuItem: NSMenuItem!
    private var dictionarySubtitleItem: NSMenuItem!
    let iosServerManager = IOSServerManager()

    var onLanguageChanged: ((String?) -> Void)?
    var onQuit: (() -> Void)?
    var onUnloadModel: (() -> Void)?
    var onReloadModel: (() -> Void)?
    /// Fires when the user clicks the Live Caption menu item. AppDelegate
    /// wires this to start/stop the manager (and beeps if the manager isn't
    /// constructed yet because the ASR model is still loading).
    /// Legacy back-compat: only fires for stop-while-active. New start paths
    /// use `onLiveCaptionStartMic` and `onLiveCaptionStartSystem` so the menu
    /// can offer two distinct entry points.
    var onLiveCaptionToggle: (() -> Void)?

    /// Fired when the user clicks `From Microphone` while Live Caption is OFF
    /// or active on a different source. AppDelegate routes to
    /// `LiveCaptionManager.start(source: .mic)` or `.switchSource(to: .mic)`.
    var onLiveCaptionStartMic: (() -> Void)?

    /// Fired when the user clicks `From System Audio…`. AppDelegate routes
    /// through `SystemAudioPermissionFlow` + picker → `start(source:)` or
    /// `switchSource(to:)`.
    var onLiveCaptionStartSystem: (() -> Void)?

    /// Fired when the user clicks `Change System Audio Source…` to force the
    /// picker even though a `systemAudioBundleID` is already saved.
    var onLiveCaptionChangeSystemSource: (() -> Void)?

    /// Fired when the user clicks the currently-active source (stops Live
    /// Caption). Decoupled from `onLiveCaptionToggle` so AppDelegate doesn't
    /// have to inspect manager state to know which path the user took.
    var onLiveCaptionStop: (() -> Void)?

    /// Tracked here so the click handlers for the two mutually-exclusive
    /// modes (iOS Server, Live Caption) can show an NSAlert explaining why
    /// the click was rejected instead of silently disabling the menu item.
    private var iosServerActive: Bool = false
    private var liveCaptionActive: Bool = false
    /// Tracks which source is active so radio-item checkmarks can be applied
    /// independently of the parent's active checkmark.
    private var liveCaptionActiveSource: AudioSourceKind?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenuItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        memoryMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        memoryMenuItem.isEnabled = false

        languageMenu = NSMenu(title: "Speech-to-Text Language")

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
        // Refresh memory display each time the menu opens
        memoryMenuItem.title = "Memory used: \(MemoryUtils.formattedMemory())"

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

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Status line
        menu.addItem(statusMenuItem)

        // Memory display
        memoryMenuItem.title = "Memory used: \(MemoryUtils.formattedMemory())"
        menu.addItem(memoryMenuItem)

        menu.addItem(.separator())

        // Language submenu
        let languageItem = NSMenuItem(title: "Speech-to-Text Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu

        let languages: [(title: String, value: String?)] = [
            ("Auto", nil),
            ("English", "english"),
            ("中文", "chinese"),
            ("日本語", "japanese"),
        ]

        for (title, value) in languages {
            let item = NSMenuItem(title: title, action: #selector(languageSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            languageMenu.addItem(item)
            languageItems.append(item)
        }

        updateLanguageCheckmarks()
        menu.addItem(languageItem)

        menu.addItem(.separator())

        // iOS Server toggle
        iosServerMenuItem = NSMenuItem(title: "Start iOS Server", action: #selector(toggleIOSServer), keyEquivalent: "")
        iosServerMenuItem.target = self
        menu.addItem(iosServerMenuItem)

        iosServerManager.onStatusChanged = { [weak self] running in
            DispatchQueue.main.async {
                self?.iosServerMenuItem.title = running ? "Stop iOS Server (port 8000)" : "Start iOS Server"
                self?.setIOSServerActive(running)
            }
        }

        menu.addItem(.separator())

        // Edit Customized Dictionary
        dictionaryMenuItem = NSMenuItem(
            title: "Edit Customized Dictionary",
            action: #selector(editDictionary),
            keyEquivalent: ""
        )
        dictionaryMenuItem.target = self
        menu.addItem(dictionaryMenuItem)

        // Dictionary subtitle (entry count or "no file")
        dictionarySubtitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        dictionarySubtitleItem.isEnabled = false
        let dictSubAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        dictionarySubtitleItem.attributedTitle = NSAttributedString(
            string: "    \(dictionarySubtitleText())",
            attributes: dictSubAttrs
        )
        menu.addItem(dictionarySubtitleItem)

        menu.addItem(.separator())

        // Floating overlay toggle
        floatingOverlayMenuItem = NSMenuItem(
            title: "Show Floating Indicator",
            action: #selector(toggleFloatingOverlay),
            keyEquivalent: ""
        )
        floatingOverlayMenuItem.target = self
        updateToggleAppearance(floatingOverlayMenuItem, title: "Show Floating Indicator", checked: AppConfig.shared.floatingOverlayEnabled)
        menu.addItem(floatingOverlayMenuItem)

        // Number Conversion toggle (deterministic ITN)
        numberConversionMenuItem = NSMenuItem(
            title: "Number Conversion",
            action: #selector(toggleNumberConversion),
            keyEquivalent: ""
        )
        numberConversionMenuItem.target = self
        updateToggleAppearance(numberConversionMenuItem, title: "Number Conversion", checked: AppConfig.shared.numberConversionEnabled)
        menu.addItem(numberConversionMenuItem)

        // Number Conversion subtitle
        let numSubtitle = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        numSubtitle.isEnabled = false
        let numSubAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        numSubtitle.attributedTitle = NSAttributedString(
            string: "    Chinese numerals \u{2192} Arabic digits",
            attributes: numSubAttrs
        )
        menu.addItem(numSubtitle)

        // AI Cleanup toggle (requires macOS 26+ with Apple Intelligence)
        aiCleanupMenuItem = NSMenuItem(
            title: "AI Cleanup",
            action: #selector(toggleAICleanup),
            keyEquivalent: ""
        )
        aiCleanupMenuItem.target = self
        updateToggleAppearance(aiCleanupMenuItem, title: "AI Cleanup", checked: AppConfig.shared.aiCleanupEnabled)
        menu.addItem(aiCleanupMenuItem)

        // AI Cleanup subtitle
        let aiSubtitle = NSMenuItem(title: "    via Apple Foundation Models", action: nil, keyEquivalent: "")
        aiSubtitle.isEnabled = false
        let aiSubAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        aiSubtitle.attributedTitle = NSAttributedString(string: "    via Apple Foundation Models", attributes: aiSubAttrs)
        menu.addItem(aiSubtitle)

        // Live Caption parent (non-clickable header — shows ✓ when any source
        // is active). The clickable entries are the radio sub-items below.
        liveCaptionMenuItem = NSMenuItem(
            title: "Live Caption",
            action: nil,
            keyEquivalent: ""
        )
        updateToggleAppearance(liveCaptionMenuItem, title: "Live Caption", checked: false)
        menu.addItem(liveCaptionMenuItem)

        // Live Caption subtitle
        liveCaptionSubtitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        liveCaptionSubtitleItem.isEnabled = false
        let liveSubAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        liveCaptionSubtitleItem.attributedTitle = NSAttributedString(
            string: "    Always-on captions for meetings & calls",
            attributes: liveSubAttrs
        )
        menu.addItem(liveCaptionSubtitleItem)

        // Radio: From Microphone
        liveCaptionMicItem = NSMenuItem(
            title: "    From Microphone",
            action: #selector(liveCaptionFromMicClicked),
            keyEquivalent: ""
        )
        liveCaptionMicItem.target = self
        updateRadioAppearance(liveCaptionMicItem, title: "From Microphone", selected: false)
        menu.addItem(liveCaptionMicItem)

        // Radio: From System Audio
        liveCaptionSystemItem = NSMenuItem(
            title: "    From System Audio…",
            action: #selector(liveCaptionFromSystemClicked),
            keyEquivalent: ""
        )
        liveCaptionSystemItem.target = self
        updateRadioAppearance(liveCaptionSystemItem, title: "From System Audio…", selected: false)
        menu.addItem(liveCaptionSystemItem)

        // Change System Audio Source (forces picker)
        liveCaptionChangeSourceItem = NSMenuItem(
            title: "    Change System Audio Source…",
            action: #selector(liveCaptionChangeSourceClicked),
            keyEquivalent: ""
        )
        liveCaptionChangeSourceItem.target = self
        let changeSourceAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        liveCaptionChangeSourceItem.attributedTitle = NSAttributedString(
            string: "    Change System Audio Source…",
            attributes: changeSourceAttrs
        )
        menu.addItem(liveCaptionChangeSourceItem)

        // Edit Live Caption Settings (opens the JSON tunables file in the
        // user's default editor — mirrors the Edit Customized Dictionary
        // pattern. Edits take effect on the next Live Caption toggle on.)
        let liveCaptionSettingsItem = NSMenuItem(
            title: "    Edit Live Caption Settings",
            action: #selector(editLiveCaptionSettings),
            keyEquivalent: ""
        )
        liveCaptionSettingsItem.target = self
        let settingsAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        liveCaptionSettingsItem.attributedTitle = NSAttributedString(
            string: "    Edit Live Caption Settings",
            attributes: settingsAttrs
        )
        menu.addItem(liveCaptionSettingsItem)

        // Text Translation toggle
        textTranslationMenuItem = NSMenuItem(
            title: "Text Translation",
            action: #selector(toggleTextTranslation),
            keyEquivalent: ""
        )
        textTranslationMenuItem.target = self
        updateToggleAppearance(textTranslationMenuItem, title: "Text Translation", checked: AppConfig.shared.textTranslationEnabled)
        menu.addItem(textTranslationMenuItem)

        // Text Translation subtitle
        translationSubtitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        translationSubtitleItem.isEnabled = false
        let transSubAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        translationSubtitleItem.attributedTitle = NSAttributedString(
            string: "    via Apple Translation Framework",
            attributes: transSubAttrs
        )
        menu.addItem(translationSubtitleItem)

        // Translate-to submenu (indented)
        translateToItem = NSMenuItem(title: "    Translate to", action: nil, keyEquivalent: "")
        let translateToMenu = NSMenu(title: "Translate to")
        let translateTargets: [(title: String, value: String?)] = [
            ("Auto", nil),
            ("English", "en"),
            ("繁體中文", "zh-Hant-TW"),
            ("日本語", "ja"),
            ("한국어", "ko"),
            ("Français", "fr"),
            ("Deutsch", "de"),
            ("Español", "es"),
        ]
        for (title, value) in translateTargets {
            let item = NSMenuItem(title: title, action: #selector(translateTargetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            translateToMenu.addItem(item)
        }
        translateToItem.submenu = translateToMenu
        updateTranslateToCheckmarks()
        menu.addItem(translateToItem)

        // Translation hotkey hint
        translationHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        translationHintItem.isEnabled = false
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        translationHintItem.attributedTitle = NSAttributedString(
            string: "    Tap Right ⌥ to translate selection",
            attributes: hintAttrs
        )
        menu.addItem(translationHintItem)

        // Show/hide translation sub-items based on toggle state
        updateTranslationSubItems()

        menu.addItem(.separator())

        // Unload / Reload model
        unloadMenuItem = NSMenuItem(title: "Unload Speech-to-Text Model", action: #selector(unloadOrReloadModel), keyEquivalent: "")
        unloadMenuItem.target = self
        let unloadAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemOrange
        ]
        unloadMenuItem.attributedTitle = NSAttributedString(string: "Unload Speech-to-Text Model", attributes: unloadAttrs)
        menu.addItem(unloadMenuItem)

        menu.addItem(.separator())

        // About
        let aboutItem = NSMenuItem(title: "About HushType", action: #selector(aboutClicked), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit HushType", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
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
                title: "Stop Live Caption first",
                message: "Live Caption is running. Stop it before starting the iOS Server — they share GPU memory."
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
                title: "Stop iOS Server first",
                message: "The iOS Server is running. Stop it before starting Live Caption — they share GPU memory."
            )
            return
        }
        onLiveCaptionToggle?()
    }

    @objc private func liveCaptionFromMicClicked() {
        // If mic is already active → toggle off.
        if liveCaptionActive, case .mic = liveCaptionActiveSource {
            onLiveCaptionStop?()
            return
        }
        // Mutex: can't start (or switch) Live Caption while iOS server is up.
        if iosServerActive {
            showMutexAlert(
                title: "Stop iOS Server first",
                message: "The iOS Server is running. Stop it before starting Live Caption — they share GPU memory."
            )
            return
        }
        onLiveCaptionStartMic?()
    }

    @objc private func liveCaptionFromSystemClicked() {
        if liveCaptionActive, case .system = liveCaptionActiveSource {
            onLiveCaptionStop?()
            return
        }
        if iosServerActive {
            showMutexAlert(
                title: "Stop iOS Server first",
                message: "The iOS Server is running. Stop it before starting Live Caption — they share GPU memory."
            )
            return
        }
        onLiveCaptionStartSystem?()
    }

    @objc private func liveCaptionChangeSourceClicked() {
        // No mutex gating — picking a different app doesn't change which
        // permissions are in play.
        onLiveCaptionChangeSystemSource?()
    }

    /// Legacy: only updates the parent's ✓ from a single boolean. Prefer
    /// `setLiveCaptionActiveSource(_:)` so the radio items also reflect state.
    func setLiveCaptionActive(_ active: Bool) {
        setLiveCaptionActiveSource(active ? .mic : nil)
    }

    /// Called from `LiveCaptionManager.onStateChanged`. Updates the parent ✓
    /// AND the source radio items, AND tracks state for the iOS Server mutex.
    func setLiveCaptionActiveSource(_ source: AudioSourceKind?) {
        liveCaptionActiveSource = source
        liveCaptionActive = (source != nil)
        guard let parent = liveCaptionMenuItem else { return }
        updateToggleAppearance(parent, title: "Live Caption", checked: source != nil)

        let micSelected: Bool
        let systemSelected: Bool
        switch source {
        case .mic:
            micSelected = true
            systemSelected = false
        case .system:
            micSelected = false
            systemSelected = true
        case .none:
            micSelected = false
            systemSelected = false
        }
        if let micItem = liveCaptionMicItem {
            updateRadioAppearance(micItem, title: "From Microphone", selected: micSelected)
        }
        if let systemItem = liveCaptionSystemItem {
            updateRadioAppearance(systemItem, title: "From System Audio…", selected: systemSelected)
        }
    }

    /// Called from the existing `iosServerManager.onStatusChanged` closure.
    /// Tracks state for the Live Caption mutex check.
    func setIOSServerActive(_ active: Bool) {
        iosServerActive = active
    }

    @objc private func editLiveCaptionSettings() {
        // Mirror the Edit Customized Dictionary flow: create the template on
        // first use so the user sees the documented schema immediately, then
        // open the file in their default text editor.
        LiveCaptionTuning.createTemplateIfMissing()

        let url = LiveCaptionTuning.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert(
                title: "Could not open Live Caption settings",
                message: "Failed to create the settings file at:\n\(url.path)"
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
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Floating Overlay

    @objc private func toggleFloatingOverlay() {
        let newValue = !AppConfig.shared.floatingOverlayEnabled
        AppConfig.shared.floatingOverlayEnabled = newValue
        updateToggleAppearance(floatingOverlayMenuItem, title: "Show Floating Indicator", checked: newValue)
    }

    // MARK: - Number Conversion

    @objc private func toggleNumberConversion() {
        let newValue = !AppConfig.shared.numberConversionEnabled
        AppConfig.shared.numberConversionEnabled = newValue
        updateToggleAppearance(numberConversionMenuItem, title: "Number Conversion", checked: newValue)
    }

    // MARK: - AI Cleanup

    @objc private func toggleAICleanup() {
        // Turning OFF — simple flip.
        if AppConfig.shared.aiCleanupEnabled {
            AppConfig.shared.aiCleanupEnabled = false
            updateToggleAppearance(aiCleanupMenuItem, title: "AI Cleanup", checked: false)
            if #available(macOS 26.0, *) {
                Task { @MainActor in
                    FoundationModelsCleaner.releaseSession()
                }
            }
            return
        }

        // Turning ON — platform check first.
        guard #available(macOS 26.0, *) else {
            let version = ProcessInfo.processInfo.operatingSystemVersionString
            showAlert(
                title: "macOS 26 or later required",
                message: """
                    AI Cleanup uses Apple's on-device Foundation Models framework, \
                    which requires macOS 26 (Tahoe) or later.

                    Your current version: \(version)
                    """
            )
            return
        }

        // Validate asynchronously.
        aiCleanupMenuItem.isEnabled = false
        let originalTitle = aiCleanupMenuItem.title
        aiCleanupMenuItem.title = "AI Cleanup (validating…)"

        Task { @MainActor in
            let result = await FoundationModelsCleaner.validate()
            self.aiCleanupMenuItem.isEnabled = true
            self.aiCleanupMenuItem.title = originalTitle

            switch result {
            case .ok:
                AppConfig.shared.aiCleanupEnabled = true
                self.updateToggleAppearance(self.aiCleanupMenuItem, title: "AI Cleanup", checked: true)
                Task.detached {
                    await FoundationModelsCleaner.warmup()
                }
            case .unavailable(let reason):
                self.showAlert(
                    title: "AI Cleanup unavailable",
                    message: """
                        Could not start Apple Foundation Models:
                        \(reason)

                        Common causes:
                        • This device does not support Apple Intelligence
                        • Apple Intelligence is not enabled in System Settings
                        • The on-device model is still downloading
                        """
                )
            }
        }
    }

    // MARK: - Text Translation

    @objc private func toggleTextTranslation() {
        let newValue = !AppConfig.shared.textTranslationEnabled
        AppConfig.shared.textTranslationEnabled = newValue
        updateToggleAppearance(textTranslationMenuItem, title: "Text Translation", checked: newValue)
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
            return "No dictionary file"
        }
        let count = DictionaryReplacer.entryCount
        return count == 1 ? "1 entry loaded" : "\(count) entries loaded"
    }

    @objc private func editDictionary() {
        // Create the file with the friendly template if it doesn't exist yet,
        // so first-time users immediately see the format documented inline.
        DictionaryReplacer.createTemplateIfMissing()

        let url = AppConfig.dictionaryFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Template creation failed — show error
            showAlert(
                title: "Could not open dictionary",
                message: "Failed to create the dictionary file at:\n\(url.path)"
            )
            return
        }

        // Open in the user's default text editor
        NSWorkspace.shared.open(url)
        log.info("Opened dictionary file in default editor")
    }

    // MARK: - Unload / Reload Model

    @objc private func unloadOrReloadModel() {
        // Check current title to decide action
        if unloadMenuItem.title.contains("Unload") || (unloadMenuItem.attributedTitle?.string.contains("Unload") ?? false) {
            onUnloadModel?()
        } else {
            onReloadModel?()
        }
    }

    /// Called by AppDelegate after successful unload to update menu state.
    func setModelUnloaded() {
        statusMenuItem.title = "Model unloaded"

        let reloadAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemGreen
        ]
        unloadMenuItem.title = "Reload Speech-to-Text Model"
        unloadMenuItem.attributedTitle = NSAttributedString(string: "Reload Speech-to-Text Model", attributes: reloadAttrs)
    }

    /// Called by AppDelegate after successful reload to restore menu state.
    func setModelLoaded() {
        let unloadAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemOrange
        ]
        unloadMenuItem.title = "Unload Speech-to-Text Model"
        unloadMenuItem.attributedTitle = NSAttributedString(string: "Unload Speech-to-Text Model", attributes: unloadAttrs)
    }

    // MARK: - Helpers

    /// Update a toggle menu item to show a green ✓ instead of the system checkmark.
    private func updateToggleAppearance(_ item: NSMenuItem, title: String, checked: Bool) {
        item.state = .off  // never use system checkmark
        item.view = nil    // ensure no custom view blocks click handling

        if checked {
            let str = NSMutableAttributedString(
                string: title + "  ",
                attributes: [.font: NSFont.menuFont(ofSize: 14)]
            )
            str.append(NSAttributedString(
                string: "✓",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.systemGreen,
                ]
            ))
            item.attributedTitle = str
        } else {
            item.attributedTitle = nil
            item.title = title
        }
    }

    /// Update a radio-style sub-menu item with the same 4-space indent + 12pt
    /// secondary font used elsewhere in the menu. Selected radios get a green
    /// ✓ suffix matching the toggle style.
    private func updateRadioAppearance(_ item: NSMenuItem, title: String, selected: Bool) {
        item.state = .off
        item.view = nil

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]

        let prefix = "    "  // 4-space indent under parent
        let str = NSMutableAttributedString(string: prefix + title, attributes: baseAttrs)
        if selected {
            str.append(NSAttributedString(
                string: "  ✓",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.systemGreen,
                ]
            ))
        }
        item.attributedTitle = str
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func aboutClicked() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "HushType v\(version)"
        alert.informativeText = """
            Local voice-to-text for macOS and iOS.
            Multilingual (EN/ZH/JP) with Traditional Chinese output.

            Author: Felix Fu
            Co-authored with: Claude (Anthropic)
            License: MIT

            github.com/felixfu824/HushType
            """
        alert.icon = NSImage(named: "AppIcon") ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        // First button is the default (Return key). Order matters for keyboard handling.
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Check for Updates")

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
        consent.messageText = "Connect to GitHub?"
        consent.informativeText = """
            HushType will connect to GitHub to check for new releases.

            No personal data is sent — only a public API call to compare version numbers.
            """
        consent.alertStyle = .informational
        consent.icon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        // Cancel is the FIRST button so it becomes the default button (Return key).
        // This is the privacy-conservative default — user must explicitly choose to connect.
        consent.addButton(withTitle: "Cancel")
        consent.addButton(withTitle: "Check Now")

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
        alert.messageText = "Up to Date"
        alert.informativeText = "You're running the latest version (v\(version))."
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showUpdateAvailable(version: String, url: URL?) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = """
            A new version is available: v\(version)

            You can download it from the GitHub Releases page.
            """
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil)
        // First button = default (View on GitHub) — most users want to see the release
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Later")

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
        alert.messageText = "Could Not Check for Updates"
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        alert.informativeText = """
            Unable to connect to GitHub.

            \(error.localizedDescription)

            Check your internet connection and try again.
            """
        alert.addButton(withTitle: "OK")
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
        case .error:
            symbolName = "exclamationmark.triangle"
        case .unloaded:
            symbolName = "mic.slash"
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "HushType")
    }

    private func updateStatusText(for state: State) {
        switch state {
        case .loading(let progress):
            let pct = Int(progress * 100)
            statusMenuItem.title = "Loading model (\(pct)%)..."
        case .idle:
            statusMenuItem.title = "Ready"
        case .recording:
            statusMenuItem.title = "Recording..."
        case .transcribing:
            statusMenuItem.title = "Transcribing..."
        case .error(let msg):
            statusMenuItem.title = "Error: \(msg)"
        case .unloaded:
            statusMenuItem.title = "Model unloaded"
        }
    }

    private func updateUnloadMenuItem(for state: State) {
        switch state {
        case .idle:
            unloadMenuItem.isEnabled = true
        case .unloaded:
            unloadMenuItem.isEnabled = true
            setModelUnloaded()
        case .loading:
            unloadMenuItem.isEnabled = false
        default:
            unloadMenuItem.isEnabled = false
        }
    }
}
