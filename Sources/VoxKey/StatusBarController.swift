import AppKit
import os

private let log = Logger(subsystem: "com.felix.voxkey", category: "statusbar")

final class StatusBarController {
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

    var onLanguageChanged: ((String?) -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenuItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        languageMenu = NSMenu(title: "Language")

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

        // Quit
        let quitItem = NSMenuItem(title: "Quit VoxKey", action: #selector(quitClicked), keyEquivalent: "q")
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

    @objc private func quitClicked() {
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

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VoxKey")
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
