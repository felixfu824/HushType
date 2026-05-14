import Foundation
import AppKit
import AVFoundation
import SpeechVAD
import Qwen3ASR
import MLX
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "liveCaption")

/// Which audio source feeds Live Caption.
///
/// `.mic` is the v1 default (`MicAudioSource` → `AVAudioEngine.inputNode`).
/// `.system(bundleID)` captures a single running app's audio via ScreenCaptureKit
/// (`SystemAudioSource`). The two sources are mutually exclusive — switching
/// while active goes through `LiveCaptionManager.switchSource(to:)`.
enum AudioSourceKind: Equatable, Sendable {
    case mic
    case system(bundleID: String)
}

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
    /// `statusBarController.setLiveCaptionActiveSource(_:)` so the submenu
    /// reflects programmatic state changes (e.g. auto-stop on model unload,
    /// auto-switch from one source to another). `nil` means Live Caption is off.
    var onStateChanged: ((AudioSourceKind?) -> Void)?

    // MARK: - State

    private(set) var isActive: Bool = false
    private(set) var isPanelVisible: Bool = false
    private(set) var currentSource: AudioSourceKind?

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

    /// Turn live caption on with the default source (mic). Back-compat wrapper
    /// around `start(source:)`. Idempotent.
    func start() async throws {
        try await start(source: .mic)
    }

    /// Turn live caption on with the requested audio source. Idempotent.
    /// Throws if permission is denied or the source fails to start.
    func start(source requestedSource: AudioSourceKind) async throws {
        guard !isActive else { return }
        log.info("LiveCaption start requested (source=\(String(describing: requestedSource), privacy: .public))")

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

        // Pre-flight: per-source permission check.
        switch requestedSource {
        case .mic:
            // Mic permission (mirror OnboardingManager.alert pattern).
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
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
        case .system:
            // Screen-recording permission is gated upstream by
            // `SystemAudioPermissionFlow.ensurePermission(then:)` (called from
            // AppDelegate before this manager is invoked). We trust that gate
            // here — `SCStream.startCapture()` below will throw if the gate
            // was bypassed, surfacing the error via the regular error path.
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
        if !isPanelVisible {
            panel?.show()
            isPanelVisible = true
        }

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

        // Audio source — mic or system. Backpressure: if the worker actor is
        // more than ~2s of audio behind (e.g. during a slow first-cold
        // transcribe), drop incoming frames instead of unboundedly queueing
        // Tasks that each retain a sample buffer. Plain NSLock-guarded
        // counters — IO thread mutates rarely and contention is negligible.
        let pendingFrames = BackpressureCounter()
        let maxPendingFrames = tuning.backpressureMaxPending

        let source: any AudioSource
        switch requestedSource {
        case .mic:
            source = MicAudioSource(service: captureService)
        case .system(let bundleID):
            source = SystemAudioSource(bundleID: bundleID)
        }

        source.onSamples = { [weak worker] samples in
            // Fires on the IO thread that produced the samples
            // (CoreAudio for mic, SCStream sample queue for system).
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
                let wasSystem: Bool
                if case .system = self.currentSource { wasSystem = true } else { wasSystem = false }
                self.stop()
                if wasSystem {
                    SystemAudioPermissionFlow.showRevocationAlert()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Microphone unavailable"
                    alert.informativeText = "Live Caption was stopped: \(error.localizedDescription)"
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
        do {
            try await source.start()
            audioSource = source
        } catch {
            log.error("AudioSource start failed: \(error.localizedDescription, privacy: .public)")
            segmentStreamTask?.cancel()
            segmentStreamTask = nil
            self.worker = nil
            cont.finish()
            hidePanel()
            // Surface the error so AppDelegate can show a clearer message —
            // particularly for system-audio failures like "app not running".
            if case .system = requestedSource {
                showSystemAudioStartFailedAlert(error)
            }
            throw error
        }

        startForceSplitTimer()

        isActive = true
        currentSource = requestedSource
        AppConfig.shared.liveCaptionEnabled = true
        AppConfig.shared.liveCaptionUsesMicSource = (requestedSource == .mic)
        onStateChanged?(requestedSource)
        log.info("LiveCaption started")
    }

    /// Stop the current source and start a different one without tearing down
    /// the panel or reloading the VAD model. Caller is responsible for
    /// arranging permission gating (mic check / `SystemAudioPermissionFlow`)
    /// before invoking this — same contract as `start(source:)`.
    func switchSource(to newSource: AudioSourceKind) async throws {
        guard isActive else {
            try await start(source: newSource)
            return
        }
        guard currentSource != newSource else { return }
        log.info("LiveCaption switching source \(String(describing: self.currentSource), privacy: .public) → \(String(describing: newSource), privacy: .public)")

        // Tear down the source-specific bits but keep the panel visible.
        forceSplitTimer?.cancel()
        forceSplitTimer = nil

        audioSource?.stop()
        audioSource = nil

        // Reset the worker so VAD/ASR state doesn't bleed across the swap.
        if let worker {
            await worker.reset()
        }
        // Worker can keep going; we'll re-attach to a fresh AsyncStream below.
        segmentStreamTask?.cancel()
        segmentStreamTask = nil

        // Re-run the start path's "wire audio source onto a fresh worker +
        // continuation" sub-block. Simpler to mark the manager inactive and
        // call start(source:) which will skip the panel rebuild because panel
        // is already non-nil and visible.
        isActive = false
        currentSource = nil
        // Note: we do NOT clear viewModel.segments — the panel keeps showing
        // prior captions across the swap.

        try await start(source: newSource)
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
        currentSource = nil
        AppConfig.shared.liveCaptionEnabled = false
        AppConfig.shared.liveCaptionUsesMicSource = false
        onStateChanged?(nil)
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

    private func showSystemAudioStartFailedAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't Start System Audio Capture"
        alert.informativeText = error.localizedDescription
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
