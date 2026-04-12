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
    private var aiCleanupMenuItem: NSMenuItem!
    private var textTranslationMenuItem: NSMenuItem!
    private var translationSubtitleItem: NSMenuItem!
    private var translateToItem: NSMenuItem!
    private var translationHintItem: NSMenuItem!
    private var unloadMenuItem: NSMenuItem!
    let iosServerManager = IOSServerManager()

    var onLanguageChanged: ((String?) -> Void)?
    var onQuit: (() -> Void)?
    var onUnloadModel: (() -> Void)?
    var onReloadModel: (() -> Void)?

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
            }
        }

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
        } else {
            iosServerManager.start(port: 8000)
        }
    }

    // MARK: - Floating Overlay

    @objc private func toggleFloatingOverlay() {
        let newValue = !AppConfig.shared.floatingOverlayEnabled
        AppConfig.shared.floatingOverlayEnabled = newValue
        updateToggleAppearance(floatingOverlayMenuItem, title: "Show Floating Indicator", checked: newValue)
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
