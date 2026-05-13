import Foundation
import AppKit
import AVFoundation
import SpeechVAD
import Qwen3ASR
import MLX
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "liveCaption")

/// Top-level coordinator for the live caption pipeline.
///
/// Lifecycle: constructed by `AppDelegate` AFTER `Qwen3TranscriptionEngine.load()`
/// completes successfully, with the loaded model passed by reference. Owns
/// the panel, the worker actor, the audio source, and the post-processing
/// queue. All start/stop flips of `AppConfig.shared.liveCaptionEnabled` MUST
/// go through here so the menu checkmark stays in sync via
/// `onStateChanged`.
@MainActor
final class LiveCaptionManager {

    // MARK: - Wiring

    private let asrModel: Qwen3ASRModel
    private let captureService: AudioCaptureService

    /// Called whenever the active state flips. AppDelegate forwards to
    /// `statusBarController.setLiveCaptionActive(_:)` so the menu reflects
    /// programmatic state changes (e.g. auto-stop on model unload).
    var onStateChanged: ((Bool) -> Void)?

    // MARK: - State

    private(set) var isActive: Bool = false
    private(set) var isPanelVisible: Bool = false

    private var vadModel: SileroVADModel?
    private var worker: LiveCaptionWorker?
    private var audioSource: (any AudioSource)?
    private var panel: LiveCaptionWindow?
    private var viewModel: LiveCaptionViewModel?

    private var segmentStreamTask: Task<Void, Never>?
    private var forceSplitTimer: DispatchSourceTimer?
    private var flashHideWork: DispatchWorkItem?

    /// Strictly-ordered post-processing of segments: OpenCC → FillerFilter →
    /// DictionaryReplacer. Static caches inside `DictionaryReplacer` have no
    /// lock today, so we serialize.
    private let postProcessingQueue = DispatchQueue(label: "hushtype.liveCaption.postProcessing")

    /// Rolling segments buffer cap — §9.b "last 50 segments".
    private static let segmentBufferCap: Int = 50

    /// Tuning knobs loaded from `~/Library/Application Support/HushType/live_caption.json`
    /// at every `start()` so the user can edit and toggle to apply.
    private var tuning: LiveCaptionTuning = .init()

    init(asrModel: Qwen3ASRModel, captureService: AudioCaptureService) {
        self.asrModel = asrModel
        self.captureService = captureService
    }

    // MARK: - Public API

    /// Turn live caption on. Idempotent. Throws if mic permission is denied
    /// or AVAudioEngine fails to start.
    func start() async throws {
        guard !isActive else { return }
        log.info("LiveCaption start requested")

        // Reload tuning at every start so editing the JSON file and toggling
        // off → on is the simple feedback loop for tweaks.
        tuning = LiveCaptionTuning.load()
        log.info("Tuning: maxTokens=\(self.tuning.maxTokens, privacy: .public) cacheLimitMB=\(self.tuning.mlxCacheLimitMB, privacy: .public) vadOnset=\(self.tuning.vadOnset, privacy: .public) backpressure=\(self.tuning.backpressureMaxPending, privacy: .public)")

        // Honor a one-shot "reset panel" request from the tuning file: clear
        // the persisted frame, drop the cached panel so it gets rebuilt with
        // the fresh default size, and flip the flag back to false so this
        // only fires once per opt-in.
        if tuning.resetPanelOnNextStart {
            UserDefaults.standard.removeObject(forKey: "hushtype.liveCaption.panelFrame")
            panel?.close()
            panel = nil
            LiveCaptionTuning.clearResetFlag()
            log.info("Panel frame reset on user request")
        }

        // Bound MLX's buffer pool so a continuous-speech meeting can't push
        // unified memory off a cliff. Live caption uses the loaded tuning;
        // 1024 MB is the default. The cache limit is global, so setting it
        // on every start() is idempotent.
        MLX.Memory.cacheLimit = tuning.mlxCacheLimitMB * 1024 * 1024

        // Pre-flight: mic permission (mirror OnboardingManager.alert pattern).
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // Trigger the system prompt; await synchronously via continuation.
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
            if !granted {
                showMicDeniedAlert()
                throw NSError(domain: "LiveCaption", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
            }
        case .denied, .restricted:
            showMicDeniedAlert()
            throw NSError(domain: "LiveCaption", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        @unknown default:
            break
        }

        // Set up panel + view model first so the user sees feedback while
        // the VAD model is loading.
        let vm = viewModel ?? LiveCaptionViewModel()
        viewModel = vm
        vm.segments.removeAll()

        if panel == nil {
            panel = LiveCaptionWindow(
                viewModel: vm,
                tuning: tuning,
                onStop: { [weak self] in
                    Task { @MainActor in self?.stop() }
                }
            )
        }
        panel?.show()
        isPanelVisible = true

        // Show loading state if we have to fetch SileroVAD on first run.
        if vadModel == nil {
            vm.headerState = .loadingVAD
            do {
                vadModel = try await SileroVADModel.fromPretrained(engine: .mlx)
            } catch {
                log.error("SileroVAD load failed: \(error.localizedDescription, privacy: .public)")
                showVADLoadFailedAlert(error)
                hidePanel()
                throw error
            }
        }
        guard let vadModel else {
            throw NSError(domain: "LiveCaption", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "VAD model unavailable after load"])
        }
        vm.headerState = .live

        // Wire the segment stream from the worker.
        let (stream, cont) = AsyncStream.makeStream(of: LiveCaptionSegment.self)

        let language = AppConfig.shared.language
        let worker = LiveCaptionWorker(
            asrModel: asrModel,
            vadModel: vadModel,
            segmentContinuation: cont,
            language: language,
            tuning: tuning
        )
        self.worker = worker

        // Consumer task — runs segments through OpenCC → FillerFilter →
        // Dictionary on a serial queue, then hops back to main for panel update.
        segmentStreamTask = Task { [weak self] in
            for await segment in stream {
                guard let self else { return }
                await self.handleSegment(segment)
            }
        }

        // Audio source — mic for v1. Backpressure: if the worker actor is
        // more than ~2s of audio behind (e.g. during a slow first-cold
        // transcribe), drop incoming frames instead of unboundedly queueing
        // Tasks that each retain a sample buffer. Plain NSLock-guarded
        // counters — IO thread mutates rarely and contention is negligible.
        let pendingFrames = BackpressureCounter()
        let maxPendingFrames = tuning.backpressureMaxPending
        let source = MicAudioSource(service: captureService)
        source.onSamples = { [weak worker] samples in
            // Fires on CoreAudio IO thread.
            guard let worker else { return }
            if !pendingFrames.tryReserve(maxPending: maxPendingFrames) {
                let dropped = pendingFrames.incrementDropped()
                if dropped & 31 == 1 {
                    log.warning("Live caption falling behind — dropped \(dropped, privacy: .public) audio buffers")
                }
                return
            }
            Task {
                await worker.feed(samples)
                pendingFrames.release()
            }
        }
        source.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                log.error("AudioSource error: \(error.localizedDescription, privacy: .public)")
                self.stop()
                let alert = NSAlert()
                alert.messageText = "Microphone unavailable"
                alert.informativeText = "Live Caption was stopped: \(error.localizedDescription)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        do {
            try source.start()
            audioSource = source
        } catch {
            log.error("AudioSource start failed: \(error.localizedDescription, privacy: .public)")
            segmentStreamTask?.cancel()
            segmentStreamTask = nil
            self.worker = nil
            cont.finish()
            hidePanel()
            throw error
        }

        startForceSplitTimer()

        isActive = true
        AppConfig.shared.liveCaptionEnabled = true
        onStateChanged?(true)
        log.info("LiveCaption started")
    }

    /// Turn live caption off. Idempotent. Safe to call from any thread via
    /// `Task { @MainActor in manager.stop() }`.
    func stop() {
        guard isActive else { return }
        log.info("LiveCaption stop requested")

        forceSplitTimer?.cancel()
        forceSplitTimer = nil

        flashHideWork?.cancel()
        flashHideWork = nil

        audioSource?.stop()
        audioSource = nil

        segmentStreamTask?.cancel()
        segmentStreamTask = nil

        if let worker {
            Task { await worker.reset() }
        }
        worker = nil

        // Drop the SileroVAD model — it's ~30MB of MLX-backed weights, and
        // keeping it cached "for fast restart" makes the user think Live
        // Caption is leaking memory after they toggle it off. Reload on the
        // next start() is ~1s (file is already cached on disk; the cost is
        // re-initializing MLX weights, not re-downloading).
        vadModel = nil

        // Flush any MLX intermediate buffers retained from the session's
        // transcribes. Without this the unified-memory footprint sticks at
        // the session peak even though the model and worker are gone.
        MLX.Memory.clearCache()

        hidePanel()

        isActive = false
        AppConfig.shared.liveCaptionEnabled = false
        onStateChanged?(false)
        log.info("LiveCaption stopped, source released")
    }

    /// Show the §9.d gated-flash on the panel header. No-op if the panel is
    /// not yet visible (race during the 0.16s fade-in immediately after
    /// toggling live caption on).
    func flashGatedMessage() {
        guard isPanelVisible, let viewModel else { return }

        viewModel.headerState = .gatedFlash

        flashHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.viewModel?.headerState = .live
        }
        flashHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - Segment handling

    private func handleSegment(_ segment: LiveCaptionSegment) async {
        // 1) OpenCC (if enabled) → 2) FillerFilter → 3) DictionaryReplacer.
        // All three run on the post-processing serial queue.
        let raw = segment.text
        let processed: String? = await withCheckedContinuation { cont in
            postProcessingQueue.async {
                let afterOpenCC: String
                if AppConfig.shared.chineseConversionEnabled {
                    afterOpenCC = ChineseConverter.convert(raw)
                } else {
                    afterOpenCC = raw
                }

                guard FillerFilter.keep(afterOpenCC) else {
                    cont.resume(returning: nil)
                    return
                }

                let afterDict = DictionaryReplacer.apply(afterOpenCC)
                cont.resume(returning: afterDict)
            }
        }

        guard let text = processed, !text.isEmpty else { return }

        appendSegmentText(text)
    }

    private func appendSegmentText(_ text: String) {
        guard let viewModel else { return }
        let entry = LiveCaptionViewModel.SegmentEntry(text: text)
        viewModel.segments.append(entry)
        if viewModel.segments.count > Self.segmentBufferCap {
            viewModel.segments.removeFirst(viewModel.segments.count - Self.segmentBufferCap)
        }
    }

    // MARK: - Force-split timer

    private func startForceSplitTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.checkForceSplit() }
        }
        timer.resume()
        forceSplitTimer = timer
    }

    private func checkForceSplit() async {
        guard let worker else { return }
        guard let startedAt = await worker.activeSpeechStartedAt() else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= tuning.forceSplitSeconds {
            log.info("Force-split firing after \(elapsed, privacy: .public)s of in-flight speech")
            await worker.forceSplit()
        }
    }

    // MARK: - Panel helpers

    private func hidePanel() {
        guard isPanelVisible else { return }
        panel?.hide()
        isPanelVisible = false
    }

    // MARK: - Alerts

    private func showMicDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "Live Caption needs microphone access. Open System Settings → Privacy & Security → Microphone and enable HushType."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showVADLoadFailedAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Failed to load voice-activity model"
        alert.informativeText = "Live Caption could not start: \(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Lock-guarded counter shared between the audio IO thread (which reserves
/// slots on `onSamples`) and the worker-task completion (which releases). The
/// lock contention is negligible because each operation is a few instructions.
final class BackpressureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: Int = 0
    private var dropped: Int = 0

    /// Atomically increments `inFlight` if it is under `maxPending`. Returns
    /// `true` if a slot was reserved (caller should `release()` later),
    /// `false` if backpressure should kick in (caller should drop the frame).
    func tryReserve(maxPending: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlight >= maxPending { return false }
        inFlight += 1
        return true
    }

    func release() {
        lock.lock()
        if inFlight > 0 { inFlight -= 1 }
        lock.unlock()
    }

    @discardableResult
    func incrementDropped() -> Int {
        lock.lock()
        defer { lock.unlock() }
        dropped += 1
        return dropped
    }
}
