import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum AppState {
        case loading
        case idle
        case recording
        case transcribing
        case inserting
        case translating
        case unloaded
    }

    private var state: AppState = .loading {
        didSet {
            log.info("State: \(String(describing: self.state))")
        }
    }

    private var statusBar: StatusBarController!
    private var hotkeyManager: HotkeyManager!
    private var audioCapture: AudioCaptureService!
    private var transcriptionEngine: Qwen3TranscriptionEngine!
    private var translationManager: TranslationManager!

    // Floating overlay (created lazily on first use)
    private let overlayState = OverlayStateModel()
    private lazy var overlayWindow = FloatingOverlayWindow(stateModel: overlayState)

    // Translation card (created lazily on first use)
    private lazy var translationCardWindow = TranslationCardWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[HushType] Starting...")

        statusBar = StatusBarController()
        hotkeyManager = HotkeyManager()
        audioCapture = AudioCaptureService()
        transcriptionEngine = Qwen3TranscriptionEngine()
        translationManager = TranslationManager()

        // Wire hotkey callbacks
        hotkeyManager.onPress = { [weak self] in
            self?.handleHotkeyPress()
        }
        hotkeyManager.onRelease = { [weak self] in
            self?.handleHotkeyRelease()
        }

        // RMS callback fires on the CoreAudio IO thread — must hop to main
        // before touching @Published state on the overlay model.
        audioCapture.onRMSLevel = { [weak self] level in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .recording = self.overlayState.state {
                    self.overlayState.state = .recording(level: level)
                }
            }
        }

        // Wire quit
        statusBar.onQuit = { [weak self] in
            self?.hotkeyManager.stop()
            self?.hideOverlay()
        }

        // Wire unload/reload
        statusBar.onUnloadModel = { [weak self] in
            self?.unloadModel()
        }
        statusBar.onReloadModel = { [weak self] in
            self?.reloadModel()
        }

        // Onboarding: if accessibility permission is missing, show our friendly
        // flow BEFORE we ever call CGEvent.tapCreate. If onboarding is needed,
        // it blocks via NSAlert and either quits or relaunches the app — in
        // either case the rest of startup never runs.
        if OnboardingManager.runIfNeeded() {
            return
        }

        // Start hotkey listener
        hotkeyManager.start()

        // Load model async
        statusBar.setState(.loading(0))
        Task.detached { [weak self] in
            do {
                try await self?.transcriptionEngine.load { progress, description in
                    DispatchQueue.main.async {
                        self?.statusBar.setState(.loading(progress))
                    }
                }
                await MainActor.run {
                    self?.state = .idle
                    self?.statusBar.setState(.idle)
                    log.info("HushType ready")
                }
            } catch {
                log.error("Failed to load model: \(error.localizedDescription)")
                await MainActor.run {
                    self?.state = .idle
                    self?.statusBar.setState(.error("Model load failed"))
                }
            }
        }

        // Intentionally NOT warming up FoundationModels at launch, even if
        // aiCleanupEnabled is persistently true. Early warmup contended with
        // the Qwen3-ASR model load on the main actor during the sensitive
        // post-onboarding relaunch window and caused the loading state to
        // stall. FoundationModels is now only touched in two places:
        //   1. When the user toggles AI Cleanup on via the menu (validate + warm)
        //   2. During an actual transcription call (AICleaner.clean)
        // Tradeoff: after a quit/relaunch with AI Cleanup persisted on, the
        // first transcription pays a ~3 second cold-start penalty. Acceptable.
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        hideOverlay()
        log.info("HushType terminated")
    }

    // MARK: - Overlay helpers

    private func showOverlayRecording() {
        guard AppConfig.shared.floatingOverlayEnabled else { return }
        overlayState.state = .recording(level: 0)
        overlayWindow.show()
    }

    private func switchOverlayToTranscribing() {
        guard AppConfig.shared.floatingOverlayEnabled else { return }
        // Window stays visible; only the inner state changes.
        overlayState.state = .transcribing
    }

    private func hideOverlay() {
        overlayWindow.hide()
        overlayState.state = .hidden
    }

    // MARK: - Hotkey Handlers

    private func handleHotkeyPress() {
        // If model is unloaded and user holds Right ⌥, auto-reload
        if state == .unloaded {
            print("[HushType] Model unloaded — auto-reloading...")
            reloadModel()
            return
        }

        guard state == .idle else {
            print("[HushType] Ignoring press — state is \(state)")
            return
        }

        guard transcriptionEngine.isLoaded else {
            print("[HushType] Model not loaded yet")
            return
        }

        state = .recording
        statusBar.setState(.recording)
        showOverlayRecording()
        audioCapture.startRecording()
        print("[HushType] Recording started...")
    }

    private func handleHotkeyRelease() {
        guard state == .recording else {
            print("[HushType] Ignoring release — state is \(state)")
            return
        }

        let samples = audioCapture.stopRecording()
        print("[HushType] Recording stopped: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s)")

        // Skip if too short (< 0.3s) — treat as a TAP for translation
        guard samples.count > 4800 else {
            hideOverlay()

            if AppConfig.shared.textTranslationEnabled {
                print("[HushType] Short tap detected — triggering translation")
                state = .idle
                statusBar.setState(.idle)
                handleTranslation()
            } else {
                print("[HushType] Too short, skipping (translation not enabled)")
                state = .idle
                statusBar.setState(.idle)
            }
            return
        }

        state = .transcribing
        statusBar.setState(.transcribing)
        switchOverlayToTranscribing()
        print("[HushType] Transcribing...")

        let language = AppConfig.shared.language

        Task.detached { [weak self] in
            let text = await self?.transcriptionEngine.transcribe(
                audio: samples,
                language: language
            ) ?? ""

            print("[HushType] Transcription result: '\(text)'")

            await MainActor.run {
                guard let self, !text.isEmpty else {
                    print("[HushType] Empty transcription, skipping insert")
                    self?.state = .idle
                    self?.statusBar.setState(.idle)
                    self?.hideOverlay()
                    return
                }

                print("[HushType] Inserting text...")
                self.state = .inserting
                TextInserter.insert(text)
                self.state = .idle
                self.statusBar.setState(.idle)
                self.hideOverlay()
                print("[HushType] Done")
            }
        }
    }

    // MARK: - Translation

    private func handleTranslation() {
        // 1. Simulate Cmd+C to copy selected text
        simulateCmdC()

        // 2. Wait for clipboard to update, then translate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }

            guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("[HushType] No text on clipboard for translation")
                return
            }

            print("[HushType] Translating: '\(text.prefix(50))...'")
            self.state = .translating

            self.translationManager.translate(text: text) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }

                    switch result {
                    case .success(let (translated, direction)):
                        // Copy translated text to clipboard
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translated, forType: .string)
                        print("[HushType] Translation result (\(direction)): '\(translated.prefix(80))...'")

                        // Show translation card
                        self.translationCardWindow.show(
                            sourceLanguage: direction,
                            sourceText: text,
                            translatedText: translated
                        )

                    case .failure(let error):
                        print("[HushType] Translation error: \(error)")
                        self.showTranslationError(error)
                    }

                    self.state = .idle
                    self.statusBar.setState(.idle)
                }
            }
        }
    }

    private func simulateCmdC() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: C (keycode 0x08) with Cmd
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    private func showTranslationError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)

        if let translationError = error as? TranslationError {
            switch translationError {
            case .unsupportedLanguage(let lang):
                alert.messageText = "Language Not Supported"
                alert.informativeText = "The detected language (\(lang)) is not supported by Apple Translation Framework.\n\nSupported languages include English, Chinese, Japanese, Korean, French, German, Spanish, and others."
                alert.addButton(withTitle: "OK")
                alert.runModal()

            case .languagePackMissing(let source, let target):
                alert.messageText = "Language Pack Not Installed"
                alert.informativeText = "Translation from \(source) to \(target) requires downloading the language pack.\n\nSystem Settings → General → Language & Region → Translation Languages → Download"
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Settings")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization") {
                        NSWorkspace.shared.open(url)
                    }
                }

            case .translationFailed(let detail):
                alert.messageText = "Translation Failed"
                alert.informativeText = "Unable to translate the selected text.\n\n\(detail)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } else {
            alert.messageText = "Translation Failed"
            alert.informativeText = "Unable to translate the selected text.\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Model Unload / Reload

    private func unloadModel() {
        guard state == .idle else {
            print("[HushType] Cannot unload — state is \(state)")
            return
        }

        transcriptionEngine.unload()

        // Also release AI Cleanup session if active
        if AppConfig.shared.aiCleanupEnabled {
            if #available(macOS 26.0, *) {
                Task { @MainActor in
                    FoundationModelsCleaner.releaseSession()
                }
            }
        }

        state = .unloaded
        statusBar.setState(.unloaded)
        print("[HushType] Model unloaded — memory freed")

        // Show confirmation alert with cold-start warning
        let alert = NSAlert()
        alert.messageText = "Model Unloaded"
        alert.informativeText = "The speech recognition model has been removed from memory.\n\nVoice input will require a cold start (~3 seconds) the next time you press Right ⌥."
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func reloadModel() {
        guard state == .unloaded || !transcriptionEngine.isLoaded else {
            print("[HushType] Model already loaded")
            return
        }

        state = .loading
        statusBar.setState(.loading(0))
        statusBar.setModelLoaded()

        Task.detached { [weak self] in
            do {
                try await self?.transcriptionEngine.load { progress, description in
                    DispatchQueue.main.async {
                        self?.statusBar.setState(.loading(progress))
                    }
                }
                await MainActor.run {
                    self?.state = .idle
                    self?.statusBar.setState(.idle)
                    log.info("Model reloaded")
                }
            } catch {
                log.error("Failed to reload model: \(error.localizedDescription)")
                await MainActor.run {
                    self?.state = .unloaded
                    self?.statusBar.setState(.error("Reload failed"))
                }
            }
        }
    }
}
