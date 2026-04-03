import AVFoundation
import UIKit
import os

private let log = Logger(subsystem: "com.felix.hushtype.ios", category: "background")

/// Manages the background audio session and IPC with keyboard extension.
/// Uses a "listening session" model: the audio engine runs continuously in background
/// (like Typeless), and the keyboard signals when to capture/send audio.
final class BackgroundAudioManager: ObservableObject {
    let recorder = AudioRecorder()
    let transcriber = RemoteTranscriber()

    @Published var state: HushTypeState = .idle
    @Published var lastResult: String = ""
    @Published var errorMessage: String?
    @Published var isListening = false
    @Published var sessionTimeRemaining: TimeInterval = 0

    private var pollTimer: DispatchSourceTimer?
    private var sessionTimer: DispatchSourceTimer?
    private var lastCommandTimestamp: Double = 0
    private var sessionStartTime: Date?

    /// Session duration in seconds (default 5 minutes)
    let sessionDuration: TimeInterval = 5 * 60

    enum HushTypeState: String {
        case idle, recording, transcribing, done, error
    }

    init() {
        setupIPC()
        // Diagnostic: check if App Group container is accessible
        if let url = AppGroup.containerURL {
            log.info("App Group container: \(url.path)")
        } else {
            log.error("App Group container NOT available — IPC will fail")
        }
    }

    /// Call this to start the "listening session" — keeps mic alive in background
    func startListeningSession() {
        do {
            try recorder.setupSession()
            recorder.startListening()
            isListening = true
            sessionStartTime = Date()
            startPolling()
            startSessionTimer()
            log.info("Listening session started — mic active, \(Int(self.sessionDuration))s timeout")
        } catch {
            log.error("Failed to start listening session: \(error.localizedDescription)")
            self.errorMessage = error.localizedDescription
        }
    }

    func stopListeningSession() {
        recorder.stopListening()
        isListening = false
        sessionTimeRemaining = 0
        sessionStartTime = nil
        pollTimer?.cancel()
        pollTimer = nil
        sessionTimer?.cancel()
        sessionTimer = nil
        log.info("Listening session stopped")
    }

    // MARK: - Session Timer (auto-stop after sessionDuration)

    private func startSessionTimer() {
        sessionTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let start = self.sessionStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            let remaining = max(0, self.sessionDuration - elapsed)

            DispatchQueue.main.async {
                self.sessionTimeRemaining = remaining
            }

            if remaining <= 0 {
                log.info("Session timeout — auto-stopping")
                DispatchQueue.main.async {
                    self.stopListeningSession()
                }
            }
        }
        timer.resume()
        sessionTimer = timer
    }

    // MARK: - Polling (DispatchSourceTimer — works in background)

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            self?.pollForCommands()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollForCommands() {
        // Write heartbeat via file
        AppGroup.writeHeartbeat()

        // Check for commands from keyboard (file-based)
        guard let result = AppGroup.readCommand() else { return }
        guard result.timestamp > lastCommandTimestamp else { return }
        lastCommandTimestamp = result.timestamp

        let cmd = result.command
        log.info("Polled command: \(cmd) (ts: \(result.timestamp))")

        // Clear command immediately
        AppGroup.clearCommand()

        DispatchQueue.main.async { [weak self] in
            if cmd == "start" {
                self?.handleStartRecording()
            } else if cmd == "stop" {
                self?.handleStopRecording()
            }
        }
    }

    // MARK: - IPC Listeners (Darwin notifications — may not work in background)

    private func setupIPC() {
        IPC.observe(IPC.startRecording) { [weak self] in
            log.info("IPC received: startRecording")
            self?.handleStartRecording()
        }
        IPC.observe(IPC.stopRecording) { [weak self] in
            log.info("IPC received: stopRecording")
            self?.handleStopRecording()
        }
        log.info("IPC observers registered")
    }

    // MARK: - Recording

    private func handleStartRecording() {
        guard state == .idle else {
            log.warning("Cannot start recording in state: \(self.state.rawValue)")
            return
        }

        state = .recording
        AppGroup.userDefaults.set(true, forKey: AppGroup.isRecording)
        recorder.startRecording()
        IPC.post(IPC.recordingStarted)
        log.info("Recording started via IPC")
    }

    private func handleStopRecording() {
        guard state == .recording else { return }

        let samples = recorder.stopRecording()
        state = .transcribing
        AppGroup.userDefaults.set(false, forKey: AppGroup.isRecording)

        // Skip if too short (< 0.5s)
        guard samples.count > 8000 else {
            log.info("Too short (\(samples.count) samples), skipping")
            state = .idle
            return
        }

        log.info("Sending \(samples.count) samples to server")

        let bgTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        let language = AppGroup.userDefaults.string(forKey: AppGroup.language)

        Task {
            do {
                let text = try await transcriber.transcribe(samples: samples, language: language)

                AppGroup.writeResult(text)

                await MainActor.run {
                    self.lastResult = text
                    self.state = .done
                }

                IPC.post(IPC.resultReady)
                log.info("Result ready: \(text)")

            } catch {
                log.error("Transcription failed: \(error.localizedDescription)")
                AppGroup.userDefaults.set(error.localizedDescription, forKey: AppGroup.errorMessage)

                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.state = .error
                }

                IPC.post(IPC.errorOccurred)
            }

            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { self.state = .idle }

            await MainActor.run {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }
    }
}
