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

    // Floating overlay (created lazily on first use)
    private let overlayState = OverlayStateModel()
    private lazy var overlayWindow = FloatingOverlayWindow(stateModel: overlayState)

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[HushType] Starting...")

        statusBar = StatusBarController()
        hotkeyManager = HotkeyManager()
        audioCapture = AudioCaptureService()
        transcriptionEngine = Qwen3TranscriptionEngine()

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

        // Skip if too short (< 0.3s)
        guard samples.count > 4800 else {
            print("[HushType] Too short, skipping")
            state = .idle
            statusBar.setState(.idle)
            hideOverlay()
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
}
