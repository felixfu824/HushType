import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "statusbar")

final class StatusBarController: NSObject {
    enum State {
        case loading(Double) // progress 0.0–1.0
        case idle
        case recording
        case transcribing
        case error(String)
    }

    private let statusItem: NSStatusItem
    private let statusMenuItem: NSMenuItem
    private let languageMenu: NSMenu
    private var languageItems: [NSMenuItem] = []
    private var iosServerMenuItem: NSMenuItem!
    private var floatingOverlayMenuItem: NSMenuItem!
    private var aiCleanupMenuItem: NSMenuItem!
    let iosServerManager = IOSServerManager()

    var onLanguageChanged: ((String?) -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenuItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        languageMenu = NSMenu(title: "Language")

        super.init()

        setupMenu()
        updateIcon(for: .idle)
        log.info("Status bar initialized")
    }

    func setState(_ state: State) {
        DispatchQueue.main.async {
            self.updateIcon(for: state)
            self.updateStatusText(for: state)
        }
    }

    // MARK: - Private

    private func setupMenu() {
        let menu = NSMenu()

        // Status line
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        // Language submenu
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
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
        floatingOverlayMenuItem.state = AppConfig.shared.floatingOverlayEnabled ? .on : .off
        menu.addItem(floatingOverlayMenuItem)

        // AI Cleanup toggle (requires macOS 26+ with Apple Intelligence)
        aiCleanupMenuItem = NSMenuItem(
            title: "AI Cleanup",
            action: #selector(toggleAICleanup),
            keyEquivalent: ""
        )
        aiCleanupMenuItem.target = self
        aiCleanupMenuItem.state = AppConfig.shared.aiCleanupEnabled ? .on : .off
        menu.addItem(aiCleanupMenuItem)

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

    @objc private func languageSelected(_ sender: NSMenuItem) {
        let value = sender.representedObject as? String
        AppConfig.shared.language = value
        updateLanguageCheckmarks()
        onLanguageChanged?(value)
        log.info("Language changed to: \(value ?? "auto")")
    }

    @objc private func toggleIOSServer() {
        if iosServerManager.isRunning {
            iosServerManager.stop()
        } else {
            iosServerManager.start(port: 8000)
        }
    }

    @objc private func toggleFloatingOverlay() {
        let newValue = !AppConfig.shared.floatingOverlayEnabled
        AppConfig.shared.floatingOverlayEnabled = newValue
        floatingOverlayMenuItem.state = newValue ? .on : .off
    }

    @objc private func toggleAICleanup() {
        // Turning OFF — simple flip.
        if AppConfig.shared.aiCleanupEnabled {
            AppConfig.shared.aiCleanupEnabled = false
            aiCleanupMenuItem.state = .off
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
            showAICleanupAlert(
                title: "macOS 26 or later required",
                message: """
                    AI Cleanup uses Apple's on-device Foundation Models framework, \
                    which requires macOS 26 (Tahoe) or later.

                    Your current version: \(version)
                    """
            )
            return
        }

        // Validate asynchronously. Disable the menu item during the round-trip
        // test so a double-click can't start two validations at once.
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
                self.aiCleanupMenuItem.state = .on
                // Warm up the cleanup session in the background so the first
                // real transcription doesn't hit cold-start latency. We're
                // already inside the outer `guard #available(macOS 26.0, *)`,
                // so no nested availability check needed here.
                Task.detached {
                    await FoundationModelsCleaner.warmup()
                }
            case .unavailable(let reason):
                self.showAICleanupAlert(
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

    private func showAICleanupAlert(title: String, message: String) {
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
        }
    }
}
