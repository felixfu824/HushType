import Foundation
import AppKit
import AVFoundation
import SpeechVAD
import Qwen3ASR
import MLX
import UserNotifications
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
/// Lifecycle: constructed by `AppDelegate` at launch with the shared local
/// engine. The local model is derived lazily from that engine when local
/// captions start; cloud-translated captions never load it. Owns
/// the panel, the active `TranscriptionBackend` (`LocalQwen3Backend` or
/// `OpenAITranslateBackend`), the audio source, and the post-processing
/// queue. All start/stop flips of `AppConfig.shared.liveCaptionEnabled` MUST
/// go through here so the menu checkmark stays in sync via
/// `onStateChanged`.
@MainActor
final class LiveCaptionManager {

    // MARK: - Wiring

    private let localEngine: Qwen3TranscriptionEngine
    private weak var asrModel: Qwen3ASRModel?
    private let captureService: AudioCaptureService

    /// Called whenever the active state flips. AppDelegate forwards to
    /// `statusBarController.setLiveCaptionState(mode:source:)` so the submenu
    /// reflects programmatic state changes (e.g. auto-stop on model unload,
    /// auto-switch from one source to another). `(nil, nil)` means Live
    /// Caption is off. The `mode` distinguishes the two parallel products —
    /// local "Live Caption" vs cloud "Live Translated Caption" — which share
    /// this manager but have separate menu submenus.
    var onStateChanged: ((AppConfig.CaptionMode?, AudioSourceKind?) -> Void)?

    // MARK: - State

    private(set) var isActive: Bool = false
    private(set) var isPanelVisible: Bool = false
    private(set) var currentSource: AudioSourceKind?

    private var vadModel: SileroVADModel?
    private var backend: (any TranscriptionBackend)?
    private var audioSource: (any AudioSource)?
    private var panel: LiveCaptionWindow?
    private var viewModel: LiveCaptionViewModel?

    private var backendEventTask: Task<Void, Never>?
    private var stopTeardownTask: Task<Void, Never>?
    private var forceSplitTimer: DispatchSourceTimer?
    private var flashHideWork: DispatchWorkItem?

    /// 1 Hz cost-ticker / auto-stop / daily-cap watcher. Active only when
    /// engine = `.cloudTranslate`. Cancelled in `stop()` / `switchEngine()`.
    private var cloudWatchdogTimer: DispatchSourceTimer?

    /// Set true the moment auto-stop fires so the watchdog can short-circuit
    /// the rest of the second's checks without racing the teardown path.
    private var autoStopFiring: Bool = false

    /// Raw (un-converted) accumulator for the live target line. Kept
    /// separately from `viewModel.currentTargetLine` only when the cloud
    /// target requires OpenCC conversion (i.e., zh-Hant) — otherwise the
    /// rendered text and the raw text are the same and we write straight
    /// to the view model. `liveTargetConversionInFlight` is the one-slot
    /// rate limiter: every targetDelta that lands while a previous OpenCC
    /// subprocess is still running just sets `liveTargetRawDirty = true`,
    /// and the completion handler re-kicks itself with the latest text.
    /// That bounds OpenCC subprocess pressure to ~20–30 / sec on Apple
    /// Silicon and avoids the prior bug where simplified Chinese would
    /// flash in the current-line for the full 800 ms debounce window
    /// before flipping to traditional at segment commit.
    private var liveTargetRaw: String = ""
    private var liveTargetConversionInFlight: Bool = false
    private var liveTargetRawDirty: Bool = false

    /// Strictly-ordered post-processing of segments: OpenCC → FillerFilter →
    /// DictionaryReplacer for local; OpenCC-only for cloud. Static caches
    /// inside `DictionaryReplacer` have no lock today, so we serialize.
    private let postProcessingQueue = DispatchQueue(label: "hushtype.liveCaption.postProcessing")

    /// Rolling segments buffer cap — §9.b "last 50 segments".
    private static let segmentBufferCap: Int = 50

    /// Tuning knobs loaded from `~/Library/Application Support/Lamitype/live_caption.json`
    /// at every `start()` so the user can edit and toggle to apply.
    private var tuning: LiveCaptionTuning = .init()

    init(localEngine: Qwen3TranscriptionEngine, captureService: AudioCaptureService) {
        self.localEngine = localEngine
        self.asrModel = localEngine.loadedModel
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
        let engine = AppConfig.shared.liveCaptionEngine
        log.info("LiveCaption start requested (source=\(String(describing: requestedSource), privacy: .public), engine=\(engine.rawValue, privacy: .public))")

        // Reload tuning at every start so editing the JSON file and toggling
        // off → on is the simple feedback loop for tweaks.
        tuning = LiveCaptionTuning.load()
        log.info("Tuning: maxTokens=\(self.tuning.maxTokens, privacy: .public) cacheLimitMB=\(self.tuning.mlxCacheLimitMB, privacy: .public) vadOnset=\(self.tuning.vadOnset, privacy: .public) backpressure=\(self.tuning.backpressureMaxPending, privacy: .public)")

        // Bound MLX's buffer pool so a continuous-speech meeting can't push
        // unified memory off a cliff. Cloud engine doesn't transcribe locally
        // but we still hold the loaded ASR model in memory for an instant
        // engine swap, so MLX cache management still applies.
        MLX.Memory.cacheLimit = tuning.mlxCacheLimitMB * 1024 * 1024

        // Pre-flight: per-source permission check.
        switch requestedSource {
        case .mic:
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
                                  userInfo: [NSLocalizedDescriptionKey: L10n.string(
                                    "error.caption.microphone_denied",
                                    fallback: "Microphone permission denied"
                                  )])
                }
            case .denied, .restricted:
                showMicDeniedAlert()
                throw NSError(domain: "LiveCaption", code: 11,
                              userInfo: [NSLocalizedDescriptionKey: L10n.string(
                                "error.caption.microphone_denied",
                                fallback: "Microphone permission denied"
                              )])
            @unknown default:
                break
            }
        case .system:
            break
        }

        // If cloud is selected, verify the key file before doing anything
        // expensive. Surface a settings-pointing alert if missing.
        var cloudKey: (apiKey: String, organization: String?)? = nil
        if engine == .cloudTranslate {
            switch OpenAIKeyStore.load() {
            case .ok(let key, let org), .unusualFormat(let key, let org):
                cloudKey = (key, org)
            case .empty:
                showCloudKeyMissingAlert()
                throw NSError(domain: "LiveCaption", code: 30,
                              userInfo: [NSLocalizedDescriptionKey: L10n.string(
                                "error.caption.openai_key_missing",
                                fallback: "OpenAI API key not set"
                              )])
            }
        }

        // Set up panel + view model first so the user sees feedback while
        // the VAD model is loading (local) or the WS handshake fires (cloud).
        let vm = viewModel ?? LiveCaptionViewModel()
        viewModel = vm
        vm.segments.removeAll()
        vm.currentSourceLine = nil
        vm.currentTargetLine = nil
        vm.cloudCostChip = nil
        liveTargetRaw = ""
        liveTargetRawDirty = false
        // Don't touch liveTargetConversionInFlight here — if a prior session
        // left it stuck true (it shouldn't, but defensively), the in-flight
        // Task will still complete and reset the flag once. Forcing it false
        // here could let two conversion Tasks race.

        if panel == nil {
            panel = LiveCaptionWindow(
                viewModel: vm,
                onStop: { [weak self] in
                    Task { @MainActor in self?.stop() }
                }
            )
        }
        if !isPanelVisible {
            panel?.show()
            isPanelVisible = true
        }

        // VAD model is local-engine-only. The cloud endpoint owns its own
        // server-side segmentation; we don't run SileroVAD on cloud sessions.
        if engine == .local {
            // The dictation engine is the single owner/loader of Qwen. A
            // cloud-dictation launch intentionally arrives here with no
            // model; local captions load it lazily and derive a weak handle.
            asrModel = localEngine.loadedModel
            if asrModel == nil {
                vm.headerState = .loadingModel(0)
                do {
                    try await localEngine.load { [weak self] progress, _ in
                        // Qwen's progress callback fires off-main. Every
                        // @Published write must explicitly return to main.
                        DispatchQueue.main.async { [weak self] in
                            guard let self,
                                  AppConfig.shared.liveCaptionEngine == .local,
                                  self.isPanelVisible else { return }
                            self.viewModel?.headerState = .loadingModel(progress)
                        }
                    }
                    asrModel = localEngine.loadedModel
                } catch is CancellationError {
                    asrModel = nil
                    vm.headerState = .live
                    hidePanel()
                    return
                } catch {
                    log.error("Qwen model load failed: \(error.localizedDescription, privacy: .public)")
                    showASRLoadFailedAlert(error)
                    hidePanel()
                    throw error
                }
            }

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
        }
        vm.headerState = .live

        // Build the backend per engine.
        let newBackend: any TranscriptionBackend
        switch engine {
        case .local:
            guard let asrModel, let vadModel else {
                throw NSError(domain: "LiveCaption", code: 20,
                              userInfo: [NSLocalizedDescriptionKey: L10n.string(
                                "error.caption.local_model_unavailable",
                                fallback: "Local caption model unavailable after load"
                              )])
            }
            newBackend = LocalQwen3Backend(
                asrModel: asrModel,
                vadModel: vadModel,
                language: AppConfig.shared.language,
                tuning: tuning
            )
        case .cloudTranslate:
            guard let cloudKey else {
                throw NSError(domain: "LiveCaption", code: 31,
                              userInfo: [NSLocalizedDescriptionKey: L10n.string(
                                "error.caption.openai_key_lost",
                                fallback: "OpenAI key resolved but lost"
                              )])
            }
            newBackend = OpenAITranslateBackend(
                apiKey: cloudKey.apiKey,
                organization: cloudKey.organization,
                targetLanguage: AppConfig.shared.cloudTargetLanguage,
                showSourceLine: AppConfig.shared.cloudShowSourceLine
            )
            await CloudUsageTracker.shared.resetSession()
        }

        // Start the backend (does the handshake for cloud, no-op for local).
        do {
            try await newBackend.start()
        } catch {
            log.error("Backend start failed: \(error.localizedDescription, privacy: .public)")
            showBackendStartFailedAlert(error, engine: engine)
            hidePanel()
            throw error
        }

        backend = newBackend
        backendEventTask = makeBackendConsumerTask(for: newBackend)

        // Audio source.
        let pendingFrames = BackpressureCounter()
        let maxPendingFrames = tuning.backpressureMaxPending

        let source: any AudioSource
        switch requestedSource {
        case .mic:
            source = MicAudioSource(service: captureService)
        case .system(let bundleID):
            source = SystemAudioSource(bundleID: bundleID)
        }

        // The onSamples callback is captured against the manager (not the
        // current backend) so engine swaps re-route audio to the new backend
        // without rebuilding the source. The manager is `@MainActor`; reading
        // `self.backend` from the IO thread needs a hop, so we read it inside
        // the spawned Task.
        source.onSamples = { [weak self] samples in
            guard let self else { return }
            if !pendingFrames.tryReserve(maxPending: maxPendingFrames) {
                let dropped = pendingFrames.incrementDropped()
                if dropped & 31 == 1 {
                    log.warning("Live caption falling behind — dropped \(dropped, privacy: .public) audio buffers")
                }
                return
            }
            Task { [weak self] in
                if let backend = await self?.currentBackend() {
                    await backend.feed(samples: samples)
                }
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
                    alert.messageText = L10n.string(
                        "alert.caption.microphone_unavailable.title",
                        fallback: "Microphone unavailable"
                    )
                    alert.informativeText = L10n.format(
                        "alert.caption.microphone_unavailable.message",
                        "Live Caption was stopped: %1$@",
                        arguments: [error.localizedDescription]
                    )
                    alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
                    alert.runModal()
                }
            }
        }
        do {
            try await source.start()
            audioSource = source
        } catch {
            log.error("AudioSource start failed: \(error.localizedDescription, privacy: .public)")
            await newBackend.stop()
            backendEventTask?.cancel()
            backendEventTask = nil
            backend = nil
            hidePanel()
            if case .system = requestedSource {
                showSystemAudioStartFailedAlert(error)
            }
            throw error
        }

        // Engine-specific tickers.
        if engine == .local {
            startForceSplitTimer()
        } else {
            startCloudWatchdog()
        }

        isActive = true
        currentSource = requestedSource
        AppConfig.shared.liveCaptionEnabled = true
        let usingMic = (requestedSource == .mic)
        AppConfig.shared.liveCaptionUsesMicSource = usingMic
        // Persisted "last-started" memory — read by the Right ⌘ + / hotkey
        // to honor the user's previous source choice across stops. Distinct
        // from `liveCaptionUsesMicSource` which is reset on stop (it's the
        // "currently using mic" flag the dictation gate watches).
        AppConfig.shared.lastStartedCaptionUsesMicSource = usingMic
        let mode: AppConfig.CaptionMode = (engine == .cloudTranslate) ? .translated : .local
        AppConfig.shared.lastStartedCaptionMode = mode
        onStateChanged?(mode, requestedSource)
        log.info("LiveCaption started")
    }

    /// Stop the current source and start a different one without tearing down
    /// the panel or reloading the VAD model. Caller is responsible for
    /// arranging permission gating (mic check / `SystemAudioPermissionFlow`)
    /// before invoking this — same contract as `start(source:)`.
    ///
    /// Engine choice is not affected; only the audio source flips. Engine
    /// changes go through `switchEngine(to:)`.
    func switchSource(to newSource: AudioSourceKind) async throws {
        guard isActive else {
            try await start(source: newSource)
            return
        }
        guard currentSource != newSource else { return }
        log.info("LiveCaption switching source \(String(describing: self.currentSource), privacy: .public) → \(String(describing: newSource), privacy: .public)")

        // Tear down source-specific bits but keep panel visible.
        forceSplitTimer?.cancel()
        forceSplitTimer = nil
        cloudWatchdogTimer?.cancel()
        cloudWatchdogTimer = nil

        audioSource?.stop()
        audioSource = nil

        // Drain the current backend cleanly; start() below will build a new
        // one. We re-use the consumer-Task drain pattern from switchEngine
        // so trailing segments land before we clear the panel.
        if let backend {
            await backend.stop()
        }
        await backendEventTask?.value
        backendEventTask = nil
        backend = nil

        // start(source:) will re-instantiate everything. Panel content
        // clears (matches today's behavior — `start(source:)` calls
        // `vm.segments.removeAll()` first).
        isActive = false
        currentSource = nil

        try await start(source: newSource)
    }

    /// Swap the cloud/local engine mid-session per spec §10. The audio source
    /// stays mounted; only the backend rebuilds. Panel content clears (matches
    /// the source-swap semantics). If the user just changed `liveCaptionEngine`
    /// from Settings while Live Caption is not active, call sites should just
    /// rely on the next `start()` to pick up the new value — this method is
    /// only meaningful for the active-session swap.
    func switchEngine(to engine: AppConfig.LiveCaptionEngine) async {
        guard isActive, let source = currentSource else {
            AppConfig.shared.liveCaptionEngine = engine
            return
        }
        log.info("LiveCaption switching engine → \(engine.rawValue, privacy: .public)")
        AppConfig.shared.liveCaptionEngine = engine
        // The simplest correct path: stop the audio source + backend cleanly,
        // then call start(source:) — which picks up the new engine.
        await teardown(stopAudio: true)
        do {
            try await start(source: source)
        } catch {
            log.error("Engine swap restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Turn live caption off. Idempotent. Safe to call from any thread via
    /// `Task { @MainActor in manager.stop() }`.
    ///
    /// Re-entrancy: the `isActive` flag is flipped synchronously BEFORE
    /// dispatching the async teardown, so a second `stop()` call before the
    /// teardown Task runs is a no-op (the guard catches it).
    func stop() {
        guard isActive else { return }
        log.info("LiveCaption stop requested")
        isActive = false
        currentSource = nil
        AppConfig.shared.liveCaptionEnabled = false
        AppConfig.shared.liveCaptionUsesMicSource = false
        onStateChanged?(nil, nil)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.teardown(stopAudio: true)
            self.hidePanel()
            self.stopTeardownTask = nil
            log.info("LiveCaption stopped, source released")
        }
        stopTeardownTask = task
    }

    /// Called by Caption Settings. The visible panel moves immediately; if
    /// no panel has been created yet, clearing the store makes the next show
    /// use the built-in 1350 × 160 bottom-centred frame.
    func resetPanelSizeAndPosition() {
        if let panel {
            panel.resetSizeAndPosition()
        } else {
            LiveCaptionPanelFrameStore.clear()
        }
    }

    /// Release the manager's derived local-model handle. If a local caption
    /// backend is active it must stop first because that backend strongly
    /// retains Qwen. Cloud-translate backends never reference Qwen and remain
    /// active across a dictation-model unload.
    @discardableResult
    func releaseLocalModel() async -> Bool {
        let hasLocalBackend = backend is LocalQwen3Backend
        let stoppedLocalSession = isActive && hasLocalBackend

        if stoppedLocalSession {
            // This is the awaited variant of stop(): synchronously publish the
            // off state, then fully drain audio/backend ownership before the
            // caller releases the engine or clears MLX memory.
            log.info("LiveCaption local stop requested for model unload")
            isActive = false
            currentSource = nil
            AppConfig.shared.liveCaptionEnabled = false
            AppConfig.shared.liveCaptionUsesMicSource = false
            onStateChanged?(nil, nil)
            await teardown(stopAudio: true)
            hidePanel()
            log.info("LiveCaption local backend released for model unload")
        } else if hasLocalBackend, let stopTeardownTask {
            // A normal stop may already have flipped `isActive` and scheduled
            // teardown. Join it rather than racing a second teardown against
            // the same backend.
            await stopTeardownTask.value
        }

        asrModel = nil
        return stoppedLocalSession
    }

    /// Show the §9.d gated-flash on the panel header. No-op if the panel is
    /// not yet visible (race during the 0.16s fade-in immediately after
    /// toggling live caption on).
    func flashGatedMessage() {
        guard isPanelVisible, let viewModel else { return }
        // Don't overwrite a reconnecting/auto-stopped header — transport
        // state and terminal state win over the dictation-gate hint.
        switch viewModel.headerState {
        case .reconnecting, .autoStopped:
            return
        default:
            break
        }

        viewModel.headerState = .gatedFlash

        flashHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.viewModel?.headerState = .live
        }
        flashHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - Internal: read backend from off-main contexts

    /// Called from the audio IO Task to fetch the currently-installed
    /// backend. `@MainActor`-isolated, accessed via `await self?...`.
    private func currentBackend() -> (any TranscriptionBackend)? {
        backend
    }

    // MARK: - Teardown helper

    /// Stop tickers, backend, optionally audio source. Does not clear panel
    /// or reset `isActive` — caller decides whether this is a full stop or
    /// part of an engine swap.
    private func teardown(stopAudio: Bool) async {
        forceSplitTimer?.cancel()
        forceSplitTimer = nil

        cloudWatchdogTimer?.cancel()
        cloudWatchdogTimer = nil

        flashHideWork?.cancel()
        flashHideWork = nil

        if stopAudio {
            audioSource?.stop()
            audioSource = nil
        }

        // Note the backend kind BEFORE we tear it down — we need it to decide
        // whether MLX cache clearing is warranted, and `backend` is nil after
        // the await below.
        let backendUsedMLX = (backend is LocalQwen3Backend)

        if let backend {
            await backend.stop()
        }
        await backendEventTask?.value
        backendEventTask = nil
        backend = nil

        // Drop the SileroVAD model — same rationale as before: ~30 MB of
        // MLX-backed weights, holding it cached after stop misleads the user.
        vadModel = nil

        // Only clear the MLX buffer pool if the engine that just finished
        // actually used it. Cloud translate is a pure WebSocket path that
        // never touches MLX, so calling clearCache after a cloud session
        // throws away dictation's warm cache for no benefit — and observably
        // makes the next push-to-talk dictation slower. Local engine still
        // clears as before because it just filled the pool with decoder KV
        // and segment activations we no longer need.
        if backendUsedMLX {
            MLX.Memory.clearCache()
        }

        // Live-target raw accumulator and conversion gate clear regardless
        // of engine; they're cheap and stale state here would leak into the
        // next session.
        liveTargetRaw = ""
        liveTargetConversionInFlight = false
        liveTargetRawDirty = false

        viewModel?.cloudCostChip = nil
    }

    // MARK: - Backend event handling

    private func makeBackendConsumerTask(for backend: any TranscriptionBackend) -> Task<Void, Never> {
        return Task { [weak self] in
            for await event in backend.events {
                guard let self else { return }
                await self.handleBackendEvent(event)
            }
        }
    }

    private func handleBackendEvent(_ event: BackendEvent) async {
        switch event {
        case .sourceDelta(let text):
            guard let viewModel else { return }
            if !AppConfig.shared.cloudShowSourceLine { return }
            let existing = viewModel.currentSourceLine ?? ""
            viewModel.currentSourceLine = existing + text

        case .targetDelta(let text):
            guard let viewModel else { return }
            // The local backend yields .targetDelta right before
            // .segmentComplete; we ignore deltas there so the highlight stays
            // on segments.last (no flicker through the dual-line region).
            guard AppConfig.shared.liveCaptionEngine == .cloudTranslate else { return }
            liveTargetRaw += text
            if shouldConvertLiveTargetToTraditional() {
                // Rendered text is whatever the last OpenCC pass produced,
                // re-kicked by kickLiveTargetConversion below if it lags
                // behind raw. Do not overwrite currentTargetLine here — that
                // would let raw simplified text appear on screen for the
                // duration of the conversion subprocess.
                kickLiveTargetConversion()
            } else {
                viewModel.currentTargetLine = liveTargetRaw
            }

        case .sourceComplete:
            // Source debounce fired. If the target is still mid-stream
            // (translation lag — typically ~200ms behind recognition),
            // DEFER source clearing to .segmentComplete so the user keeps
            // seeing the source/translation pair together until the whole
            // thought commits. Only clear right now if target is empty —
            // that's the "source spoken, nothing translatable came back"
            // case where leaving source on screen would just hang there.
            let targetMidStream = !(viewModel?.currentTargetLine ?? "").isEmpty
            if !targetMidStream {
                viewModel?.currentSourceLine = nil
            }

        case .segmentComplete(let text):
            await handleSegment(text)
            // Clear both the target AND the source current-lines together.
            // The source-line clearing was previously owned only by
            // .sourceComplete, but that fires ~200ms before this event in
            // the common case, leaving an awkward window where the user saw
            // a translation with no source underneath. See the .sourceComplete
            // arm above for the matching defer.
            viewModel?.currentTargetLine = nil
            viewModel?.currentSourceLine = nil
            // The live accumulator is consumed by this commit. Wipe so the
            // next utterance starts clean. `liveTargetRawDirty` stays false
            // because we've reached the canonical end of the segment — any
            // in-flight conversion that completes after this point will
            // assign empty/short text to currentTargetLine which is fine
            // (immediately overwritten by the next delta).
            liveTargetRaw = ""
            liveTargetRawDirty = false
            // A successful segment-complete during a reconnecting header
            // means the stream is back; restore .live so the header reflects
            // real state.
            if case .reconnecting = viewModel?.headerState {
                viewModel?.headerState = .live
            }

        case .reconnecting(let attempt, let max):
            viewModel?.headerState = .reconnecting(attempt: attempt, max: max)

        case .error(let err):
            await handleBackendError(err)
        }
    }

    private func handleBackendError(_ error: Error) async {
        log.error("Backend error: \(error.localizedDescription, privacy: .public)")
        // 401/403 = auth failure → re-point user at the key file. Other
        // errors after exhausting reconnects → "Switch to Local" affordance.
        let ns = error as NSError
        if ns.domain == "OpenAITranslate" && (ns.code == 401 || ns.code == 403) {
            self.stop()
            showCloudKeyRejectedAlert()
            return
        }
        if ns.domain == "OpenAITranslate" && ns.code == 429 {
            self.stop()
            showCloudRateLimitedAlert()
            return
        }
        // Generic transport / API error → offer Switch to Local.
        showCloudErrorWithSwitchToLocalAlert(error)
    }

    // MARK: - Segment handling

    private func handleSegment(_ rawText: String) async {
        // Engine-branched post-processing. Local: OpenCC (if dictation toggle
        // on) → FillerFilter → DictionaryReplacer. Cloud: OpenCC iff target =
        // zh-Hant. Two different gates (§11) — easy to get wrong.
        let processed: String? = await withCheckedContinuation { cont in
            postProcessingQueue.async {
                switch AppConfig.shared.liveCaptionEngine {
                case .local:
                    let script = ScriptDetector.detect(rawText)
                    let afterOpenCC = AppConfig.shared.chineseConversionEnabled
                        ? ChineseConverter.convert(rawText) : rawText
                    guard FillerFilter.keep(afterOpenCC) else {
                        cont.resume(returning: nil); return
                    }
                    let afterDict = DictionaryReplacer.apply(afterOpenCC)
                    // Strip over-aggressive Chinese inline punctuation (zh only).
                    let finalText = (script == .zh)
                        ? PunctuationNormalizer.apply(afterDict, mode: AppConfig.shared.punctuationMode)
                        : afterDict
                    cont.resume(returning: finalText)
                case .cloudTranslate:
                    // For zh-Hant we've already been converting per delta, but
                    // the per-delta pass works on a rolling buffer that may
                    // include incomplete characters at chunk boundaries —
                    // doing one final s2twp pass on the committed segment
                    // guarantees we don't ship a half-converted token to
                    // scrollback. Cheap (one subprocess on a complete
                    // utterance) and idempotent on already-traditional text.
                    let needsHant = (AppConfig.shared.cloudTargetLanguage == "zh-Hant")
                    let afterOpenCC = needsHant ? ChineseConverter.convert(rawText) : rawText
                    cont.resume(returning: afterOpenCC)
                }
            }
        }

        guard let text = processed, !text.isEmpty else { return }
        appendSegmentText(text)
    }

    // MARK: - Live target conversion (cloud zh-Hant only)

    private func shouldConvertLiveTargetToTraditional() -> Bool {
        AppConfig.shared.cloudTargetLanguage == "zh-Hant"
            && AppConfig.shared.chineseConversionEnabled
    }

    /// Kick a single-slot OpenCC conversion of `liveTargetRaw` and assign the
    /// result to `viewModel.currentTargetLine`. If a conversion is already in
    /// flight, set `liveTargetRawDirty = true` and let the completion handler
    /// re-arm itself — that bounds OpenCC subprocess pressure to one
    /// concurrent call and naturally rate-limits to subprocess turnaround
    /// time (~30–50 ms cold, ~5–10 ms warm). The raw buffer is read inside
    /// MainActor, the subprocess runs detached, and the result is written
    /// back via MainActor.
    private func kickLiveTargetConversion() {
        if liveTargetConversionInFlight {
            liveTargetRawDirty = true
            return
        }
        liveTargetConversionInFlight = true
        let snapshot = liveTargetRaw
        Task.detached(priority: .userInitiated) { [weak self] in
            let converted = ChineseConverter.convert(snapshot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Only commit if the live target is still active. If the
                // segment has been committed (raw cleared) in the meantime,
                // skip the assign — the next delta will replace anyway, and
                // overwriting nil → empty-conversion would flash briefly.
                if !self.liveTargetRaw.isEmpty {
                    self.viewModel?.currentTargetLine = converted
                }
                self.liveTargetConversionInFlight = false
                if self.liveTargetRawDirty {
                    self.liveTargetRawDirty = false
                    self.kickLiveTargetConversion()
                }
            }
        }
    }

    private func appendSegmentText(_ text: String) {
        guard let viewModel else { return }
        let entry = LiveCaptionViewModel.SegmentEntry(text: text)
        viewModel.segments.append(entry)
        if viewModel.segments.count > Self.segmentBufferCap {
            viewModel.segments.removeFirst(viewModel.segments.count - Self.segmentBufferCap)
        }
    }

    // MARK: - Force-split timer (local engine only)

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
        guard let local = backend as? LocalQwen3Backend else { return }
        guard let startedAt = await local.activeSpeechStartedAt() else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= tuning.forceSplitSeconds {
            log.info("Force-split firing after \(elapsed, privacy: .public)s of in-flight speech")
            await local.forceSplit()
        }
    }

    // MARK: - Cloud watchdog (cost ticker + auto-stop + daily spend warning)

    private func startCloudWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.cloudWatchdogTick() }
        }
        timer.resume()
        cloudWatchdogTimer = timer
    }

    private func cloudWatchdogTick() async {
        guard isActive, !autoStopFiring else { return }
        let snap = await CloudUsageTracker.shared.snapshot()

        // Cost ticker chip: "MM:SS · $X.XX"
        let chip = "\(CloudUsageTracker.formatSessionTime(seconds: snap.sessionSeconds)) · \(CloudUsageTracker.formatDollars(snap.sessionDollars))"
        viewModel?.cloudCostChip = chip

        // Auto-stop check.
        let limitMin = AppConfig.shared.cloudAutoStopMinutes
        if snap.sessionSeconds >= Double(limitMin) * 60.0 {
            autoStopFiring = true
            await fireAutoStop(usedDollars: snap.dayDollars, minutes: limitMin)
            return
        }

        // Daily spend warning (one-time per day).
        let cap = AppConfig.shared.cloudDailyCapDollars
        let shouldWarn = await CloudUsageTracker.shared.shouldFireDailyCapWarning(cap: cap)
        if shouldWarn {
            await CloudUsageTracker.shared.markDailyCapWarned()
            postNotification(
                title: L10n.string(
                    "notification.daily_spend.title",
                    fallback: "Daily spend warning reached"
                ),
                body: L10n.format(
                    "notification.caption.daily_spend.body",
                    "You've used %1$@ today (warning: %2$@).",
                    arguments: [
                        CloudUsageTracker.formatDollars(snap.dayDollars),
                        CloudUsageTracker.formatDollars(cap)
                    ]
                )
            )
        }
    }

    private func fireAutoStop(usedDollars: Double, minutes: Int) async {
        log.info("Auto-stop firing at \(minutes, privacy: .public) min")
        viewModel?.headerState = .autoStopped

        postNotification(
            title: L10n.string(
                "notification.caption.auto_stop.title",
                fallback: "Live Caption auto-stopped"
            ),
            body: L10n.plural(
                "notification.caption.auto_stop.body",
                count: minutes,
                fallback: "Stopped after %1$d minutes (%2$@ used today).",
                arguments: [Int32(minutes), CloudUsageTracker.formatDollars(usedDollars)]
            )
        )

        // Hide panel after 5s so the autoStopped flash is visible. Use main
        // queue async so we don't block the watchdog event handler.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.stop()
            self?.autoStopFiring = false
        }
    }

    /// Best-effort notification. If `UNUserNotificationCenter` permission is
    /// not granted, the headerState flash is the only signal — never use
    /// `NSAlert.runModal()` here because Live Caption shares the screen with
    /// dictation, and a modal would steal focus from any active text field.
    private func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    log.warning("Notification post failed: \(error.localizedDescription, privacy: .public)")
                }
            }
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
        alert.messageText = L10n.string(
            "alert.caption.mic_access.title",
            fallback: "Microphone Access Required"
        )
        alert.informativeText = L10n.string(
            "alert.caption.mic_access.message",
            fallback: "Live Caption needs microphone access. Open System Settings → Privacy & Security → Microphone and enable Lamitype."
        )
        alert.addButton(withTitle: L10n.string(
            "common.button.open_system_settings",
            fallback: "Open System Settings"
        ))
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showVADLoadFailedAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.caption.vad_failed.title",
            fallback: "Failed to load voice-activity model"
        )
        alert.informativeText = L10n.format(
            "alert.caption.vad_failed.message",
            "Live Caption could not start: %1$@",
            arguments: [error.localizedDescription]
        )
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }

    private func showASRLoadFailedAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.caption.asr_failed.title",
            fallback: "Failed to load speech model"
        )
        alert.informativeText = L10n.format(
            "alert.caption.asr_failed.message",
            "Local Live Caption could not start: %1$@",
            arguments: [error.localizedDescription]
        )
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }

    private func showSystemAudioStartFailedAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.caption.system_audio_failed.title",
            fallback: "Couldn't Start System Audio Capture"
        )
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }

    private func showCloudKeyMissingAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "error.caption.openai_key_missing",
            fallback: "OpenAI API key not set"
        )
        alert.informativeText = L10n.string(
            "alert.caption.cloud_key_missing.message",
            fallback: "Live Translated Caption needs an OpenAI API key. Open the Cloud pane in Settings and paste your key into openai.json."
        )
        alert.addButton(withTitle: L10n.string("common.button.open_settings", fallback: "Open Settings"))
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            LamitypeSettingsWindowController.shared.presentAndFocus(pane: .cloud)
        }
    }

    private func showCloudKeyRejectedAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.caption.cloud_key_rejected.title",
            fallback: "OpenAI rejected the API key"
        )
        alert.informativeText = L10n.string(
            "alert.caption.cloud_key_rejected.message",
            fallback: "Check the value in openai.json."
        )
        alert.addButton(withTitle: L10n.string("common.button.open_file", fallback: "Open File"))
        alert.addButton(withTitle: L10n.string("common.button.settings", fallback: "Settings"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            OpenAIKeyStore.openInDefaultEditor()
        } else {
            LamitypeSettingsWindowController.shared.presentAndFocus(pane: .cloud)
        }
    }

    private func showCloudRateLimitedAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.caption.rate_limit.title",
            fallback: "OpenAI rate limit hit"
        )
        alert.informativeText = L10n.string(
            "alert.caption.rate_limit.message",
            fallback: "Try again in a minute, or upgrade your OpenAI plan."
        )
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }

    private func showCloudErrorWithSwitchToLocalAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.caption.connection_lost.title",
            fallback: "Cloud Live Caption connection lost"
        )
        alert.informativeText = L10n.format(
            "alert.caption.connection_lost.message",
            "Could not reach OpenAI: %1$@",
            arguments: [error.localizedDescription]
        )
        alert.addButton(withTitle: L10n.string("common.button.switch_to_local", fallback: "Switch to Local"))
        alert.addButton(withTitle: L10n.string("common.button.stop", fallback: "Stop"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { @MainActor in await self.switchEngine(to: .local) }
        } else {
            self.stop()
        }
    }

    private func showBackendStartFailedAlert(_ error: Error, engine: AppConfig.LiveCaptionEngine) {
        let alert = NSAlert()
        switch engine {
        case .cloudTranslate:
            alert.messageText = L10n.string(
                "alert.caption.cloud_start_failed.title",
                fallback: "Could not start Cloud Live Caption"
            )
            alert.informativeText = error.localizedDescription
        case .local:
            alert.messageText = L10n.string(
                "alert.caption.local_start_failed.title",
                fallback: "Could not start Live Caption"
            )
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
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
