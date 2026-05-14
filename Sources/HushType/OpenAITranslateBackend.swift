import Foundation
import AVFoundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "backendCloud")

/// Cloud translate `TranscriptionBackend` via OpenAI's realtime translation
/// endpoint. Architecture per spec §4 / §7 / §8 / §9 / §10:
///
/// - Actor isolation: a single actor owns the WebSocket, the resampler, the
///   debounce timers, and the cost tap. The audio-IO thread calls
///   `Task { await backend.feed(samples) }` — same backpressure model as
///   the local path.
/// - Resample: `AVAudioConverter` 16 kHz F32 → 24 kHz Int16 (the realtime
///   endpoint mandates 24 kHz mono PCM16). The converter is stateful and
///   created once per session.
/// - Outbound cadence: accumulate ≥ 2400 Int16 samples (100 ms @ 24 kHz),
///   base64-encode, send as `session.input_audio_buffer.append`. Tail bytes
///   carry over to the next flush.
/// - Segment commit (the endpoint has no server-side completion event):
///   client-side 800 ms silence-debounce, independently per stream. On fire,
///   yield `.segmentComplete(accumulatedText)` and clear the buffer.
/// - Graceful stop: send `session.close`, wait up to 1.5 s for the trailing
///   deltas + `session.closed` confirmation, flush any pending buffers, then
///   close the WS with status 1000.
/// - Reconnect: 3 retries at 0.5 / 1 / 2 s on transport drop. Each retry
///   yields `.reconnecting(n, max)` for the header. All retries fail →
///   yield `.error(...)` and let the manager surface "Switch to Local".
final class OpenAITranslateBackend: TranscriptionBackend, @unchecked Sendable {

    let events: AsyncStream<BackendEvent>
    private let eventsContinuation: AsyncStream<BackendEvent>.Continuation

    // MARK: - Configuration captured at start()

    /// Bearer token captured from `openai.json` at construction. Used for the
    /// lifetime of the session including all retries (§6 "bearer-token
    /// lifetime"). Mid-session rotation has no effect — user must stop and
    /// restart to pick up a new key.
    private let apiKey: String
    private let organization: String?
    private let targetLanguage: String
    private let showSourceLine: Bool
    private let usageTracker: CloudUsageTracker

    // MARK: - Actor-isolated state (guarded by serial dispatch)

    private let stateQueue = DispatchQueue(label: "hushtype.openaiBackend.state")

    /// All mutable state lives behind `stateQueue`. We're not a Swift `actor`
    /// because URLSessionWebSocketTask's receive handler is a closure that
    /// fires off-actor and recursion through it from inside an actor's executor
    /// is awkward; serialized DispatchQueue is plainer and matches our existing
    /// `BackpressureCounter` pattern.
    private struct State {
        var task: URLSessionWebSocketTask?
        var session: URLSession?
        var resampler: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var outputFormat: AVAudioFormat?
        var int16Accumulator: Data = Data()   // bytes pending flush
        var currentSourceBuf: String = ""
        var currentTargetBuf: String = ""
        var sourceDebounce: DispatchSourceTimer?
        var targetDebounce: DispatchSourceTimer?
        var reconnectAttempt: Int = 0
        var stopped: Bool = false
        var awaitingGracefulClose: Bool = false
        /// Tracks the in-flight WS receive loop so `stop()` can await its
        /// exit before invalidating the URLSession — without this, the loop
        /// captures `self` and keeps the backend (resampler, accumulator,
        /// URLSession internals) alive past `stop()`, which Felix observed
        /// as a long memory tail when followed by a dictation hotkey.
        var receiveLoopTask: Task<Void, Never>?
    }
    private var state = State()

    // MARK: - Constants

    /// 24 kHz mono PCM16 — endpoint contract.
    private static let outSampleRate: Double = 24_000
    /// 100 ms minimum flush = 2400 samples @ 24 kHz = 4800 bytes.
    private static let minFlushSamples: Int = 2400
    /// 800 ms silence-debounce per spec §8.
    private static let debounceMs: Int = 800
    /// 3-retry reconnect ladder per spec §10.
    private static let reconnectDelaysSec: [Double] = [0.5, 1.0, 2.0]
    /// Maximum wait after sending `session.close` before forcibly closing.
    /// Originally 1.5s to let trailing deltas settle; lowered to 300ms after
    /// Felix saw a long memory tail when stopping cloud LC and immediately
    /// triggering dictation. The trailing-delta loss is acceptable — the
    /// user is explicitly stopping, they don't expect the last 1.5s of
    /// translated speech to keep appearing on screen.
    private static let gracefulCloseTimeoutSec: TimeInterval = 0.3

    private static let endpoint = URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!

    // MARK: - Init

    init(
        apiKey: String,
        organization: String?,
        targetLanguage: String,
        showSourceLine: Bool,
        usageTracker: CloudUsageTracker = .shared
    ) {
        self.apiKey = apiKey
        self.organization = organization
        self.targetLanguage = targetLanguage
        self.showSourceLine = showSourceLine
        self.usageTracker = usageTracker

        let (stream, cont) = AsyncStream.makeStream(of: BackendEvent.self)
        self.events = stream
        self.eventsContinuation = cont
    }

    // MARK: - TranscriptionBackend

    func start() async throws {
        try await openSocket(isReconnect: false)
    }

    func feed(samples: [Float]) async {
        await processInbound(samples)
    }

    func stop() async {
        // Shortened graceful close per Felix's 2026-05-14 feedback: 300ms
        // window is enough for the server to receive the close frame, but
        // doesn't keep the URLSession holding receive buffers for ~1.5s
        // after the user has already moved on (often to dictation).
        let (task, receiveTask) = stateQueue.sync { () -> (URLSessionWebSocketTask?, Task<Void, Never>?) in
            state.stopped = true
            state.awaitingGracefulClose = true
            cancelDebounceTimers_locked()
            return (state.task, state.receiveLoopTask)
        }

        if let task {
            await sendClientEvent(task: task, event: ["type": "session.close"])
            try? await Task.sleep(nanoseconds: UInt64(Self.gracefulCloseTimeoutSec * 1_000_000_000))
            flushPendingBuffers()
            task.cancel(with: .normalClosure, reason: nil)
        }

        // Wait for the receive loop to finish observing the cancel. Without
        // this await, the receive Task keeps a strong reference to self
        // (resampler / accumulator / URLSession state) for an indeterminate
        // window after stop() returns — which was the long memory tail Felix
        // observed when stopping cloud LC and starting dictation back-to-back.
        receiveTask?.cancel()
        await receiveTask?.value

        stateQueue.sync {
            state.session?.invalidateAndCancel()
            state.session = nil
            state.task = nil
            state.receiveLoopTask = nil
            state.resampler = nil
            state.inputFormat = nil
            state.outputFormat = nil
            state.int16Accumulator.removeAll()
            state.currentSourceBuf = ""
            state.currentTargetBuf = ""
        }

        eventsContinuation.finish()
        log.info("OpenAITranslateBackend stopped")
    }

    // MARK: - Socket lifecycle

    private func openSocket(isReconnect: Bool) async throws {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let organization, !organization.isEmpty {
            request.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
        }
        // No OpenAI-Beta header — the current realtime-websocket guide
        // example does not include it. No OpenAI-Safety-Identifier — see §6.

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60 * 60 * 24

        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: request)

        stateQueue.sync {
            state.session = session
            state.task = task
        }

        task.resume()

        // Send session.update with the target language and the realtime-
        // translation client-event shape (§8). We previously tried
        // `output_modalities: ["text"]` here to stop the server from
        // streaming back synthesized audio, but the realtime-translate
        // endpoint rejects that field ("Unknown parameter:
        // 'session.output_modalities'") and drops the connection. Removed
        // until we know the right knob for this endpoint specifically; if
        // memory tail re-surfaces, the next lever is explicit
        // malloc_zone_pressure_relief on cloud teardown.
        let outputLangISO = mapTargetLanguage(targetLanguage)
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "audio": [
                    "input": [
                        "transcription": ["model": "gpt-realtime-whisper"],
                        "noise_reduction": NSNull()
                    ],
                    "output": ["language": outputLangISO]
                ]
            ]
        ]
        try await sendClientEvent(task: task, event: sessionUpdate)

        // Spin up the inbound receive loop. Each `receive()` is one-shot — we
        // re-arm in handleMessage. The loop terminates when the task throws
        // (transport drop) or when `state.stopped` is set.
        // We hold a handle to this Task in state so stop() can explicitly
        // await its exit — without that, the Task keeps a strong ref to
        // self past stop() and delays deallocation of resampler / URLSession
        // internals.
        let receiveTask: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(task: task)
        }
        stateQueue.sync {
            state.receiveLoopTask?.cancel()
            state.receiveLoopTask = receiveTask
        }

        if isReconnect {
            // Successful reconnect — let the manager know the transport is
            // up so it can return the header to `.live`. There is no
            // explicit ".reconnected" case; the manager treats a subsequent
            // server `session.created` / `.updated` as the implicit signal,
            // but we also yield a no-op "live again" hint by setting
            // reconnectAttempt back to 0 so the next failure starts fresh.
            stateQueue.sync { state.reconnectAttempt = 0 }
        }

        log.info("OpenAI WS opened (reconnect=\(isReconnect, privacy: .public))")
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while true {
            let stopped = stateQueue.sync { state.stopped }
            if stopped { return }

            do {
                let msg = try await task.receive()
                handleMessage(msg)
            } catch {
                let stopped = stateQueue.sync { state.stopped }
                if stopped { return }
                log.warning("WS receive failed: \(error.localizedDescription, privacy: .public)")
                await reconnectOrFail(reason: error)
                return
            }
        }
    }

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message) {
        switch msg {
        case .string(let text):
            handleServerEventJSON(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                handleServerEventJSON(text)
            }
        @unknown default:
            break
        }
    }

    private func handleServerEventJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            log.warning("WS message unparseable")
            return
        }

        switch type {
        case "session.created", "session.updated":
            log.info("WS \(type, privacy: .public)")

        case "session.input_transcript.delta":
            guard showSourceLine else { return }
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                appendDelta(delta, kind: .source)
            }

        case "session.output_transcript.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                appendDelta(delta, kind: .target)
            }

        case "session.output_audio.delta":
            // Discard — we don't play translated audio in v0.7. After the
            // output_modalities=["text"] addition to session.update we
            // shouldn't see this anymore; if it shows up it means OpenAI
            // is ignoring the modalities suppression and we'd want to
            // surface that in logs for diagnosis.
            log.debug("WS output_audio.delta received — output_modalities suppression may not be applying")

        case "session.closed":
            log.info("WS session.closed received")
            // Flush whatever we have and stop the receive loop. The caller's
            // stop() path is awaiting the timeout window; the buffer flush
            // happens there too.
            flushPendingBuffers()

        case "error":
            let message = (obj["error"] as? [String: Any]).flatMap { $0["message"] as? String } ?? "OpenAI error"
            let code = (obj["error"] as? [String: Any]).flatMap { $0["code"] as? String }
            log.error("WS error: \(message, privacy: .public) code=\(code ?? "-", privacy: .public)")
            let nsError = NSError(
                domain: "OpenAITranslate",
                code: code == "rate_limit_exceeded" ? 429 : 0,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            eventsContinuation.yield(.error(nsError))

        default:
            // Unknown event type — log at INFO (was debug) so Felix can pull
            // them out of Console.app when the panel stalls (the EN→ZH
            // language-switch case is suspected to involve a previously-
            // unseen event type from the translate endpoint when source and
            // target collapse to the same language). Don't drop the
            // connection on unknown events — forward-compat with new server
            // event types is worth the noise.
            log.info("WS unknown event type: \(type, privacy: .public)")
        }
    }

    // MARK: - Reconnect

    private func reconnectOrFail(reason: Error) async {
        // Check status codes that should NOT retry (401, 429 etc).
        if let httpResponse = (state.task?.response as? HTTPURLResponse) {
            switch httpResponse.statusCode {
            case 401, 403:
                eventsContinuation.yield(.error(NSError(
                    domain: "OpenAITranslate",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "OpenAI rejected the API key."]
                )))
                eventsContinuation.finish()
                return
            case 429:
                eventsContinuation.yield(.error(NSError(
                    domain: "OpenAITranslate",
                    code: 429,
                    userInfo: [NSLocalizedDescriptionKey: "OpenAI rate limit hit."]
                )))
                eventsContinuation.finish()
                return
            default:
                break
            }
        }

        let attempt = stateQueue.sync { () -> Int in
            state.reconnectAttempt += 1
            return state.reconnectAttempt
        }
        if attempt > Self.reconnectDelaysSec.count {
            eventsContinuation.yield(.error(reason))
            eventsContinuation.finish()
            return
        }

        let delay = Self.reconnectDelaysSec[attempt - 1]
        eventsContinuation.yield(.reconnecting(attempt: attempt, max: Self.reconnectDelaysSec.count))
        log.info("Reconnect attempt \(attempt, privacy: .public) in \(delay, privacy: .public)s")
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        do {
            try await openSocket(isReconnect: true)
        } catch {
            await reconnectOrFail(reason: error)
        }
    }

    // MARK: - Outbound audio

    private func processInbound(_ samples: [Float]) async {
        // Build / reuse resampler.
        let (resampler, inFmt, outFmt) = ensureResampler()
        guard let r = resampler, let ifmt = inFmt, let ofmt = outFmt else { return }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: ifmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let inPtr = inputBuffer.floatChannelData?[0] else {
            return
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inPtr.update(from: src.baseAddress!, count: samples.count)
        }

        // Output capacity ≥ ceil(samples * 24000/16000) + slack for converter
        // residual.
        let outCapacity = AVAudioFrameCount(Double(samples.count) * Self.outSampleRate / 16_000.0 + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: ofmt, frameCapacity: outCapacity) else {
            return
        }

        var convertError: NSError?
        var sentInput = false
        let status = r.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            if sentInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            sentInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error || convertError != nil {
            log.error("Resampler error: \(convertError?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }

        let outFrames = Int(outputBuffer.frameLength)
        guard outFrames > 0, let int16Ptr = outputBuffer.int16ChannelData?[0] else { return }

        let byteCount = outFrames * MemoryLayout<Int16>.size
        let chunk = Data(bytes: int16Ptr, count: byteCount)

        // Accumulate + flush when we have ≥ 100 ms.
        stateQueue.sync {
            state.int16Accumulator.append(chunk)
        }
        await flushIfReady()
    }

    private func ensureResampler() -> (AVAudioConverter?, AVAudioFormat?, AVAudioFormat?) {
        return stateQueue.sync {
            if let r = state.resampler, let ifmt = state.inputFormat, let ofmt = state.outputFormat {
                return (r, ifmt, ofmt)
            }
            let inFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )!
            // PCM16 mono interleaved at 24 kHz — endpoint contract.
            let outFmt = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.outSampleRate,
                channels: 1,
                interleaved: true
            )!
            guard let converter = AVAudioConverter(from: inFmt, to: outFmt) else {
                log.error("Could not build 16k→24k Int16 resampler")
                return (nil, nil, nil)
            }
            state.resampler = converter
            state.inputFormat = inFmt
            state.outputFormat = outFmt
            log.info("Built 16k F32 → 24k Int16 resampler")
            return (converter, inFmt, outFmt)
        }
    }

    /// If the accumulator has ≥ 100 ms of audio, slice off enough multiples
    /// of `minFlushSamples` and send. Tail bytes carry over.
    private func flushIfReady() async {
        let task: URLSessionWebSocketTask? = stateQueue.sync { state.task }
        guard let task else { return }

        // Take a snapshot of what we can flush, then leave the tail behind.
        let (payloads, secondsSent) = stateQueue.sync { () -> ([Data], Double) in
            let minBytes = Self.minFlushSamples * MemoryLayout<Int16>.size
            let available = state.int16Accumulator.count
            if available < minBytes { return ([], 0) }
            // Send all complete 100 ms blocks; remainder carries over.
            let blocks = available / minBytes
            let totalBytes = blocks * minBytes
            let payload = state.int16Accumulator.prefix(totalBytes)
            state.int16Accumulator.removeFirst(totalBytes)
            // Each block is 2400 samples = 0.1 s at 24 kHz.
            return ([Data(payload)], Double(blocks) * 0.1)
        }

        for payload in payloads {
            let b64 = payload.base64EncodedString()
            let event: [String: Any] = [
                "type": "session.input_audio_buffer.append",
                "audio": b64
            ]
            await sendClientEvent(task: task, event: event)
        }

        if secondsSent > 0 {
            await usageTracker.recordChunk(seconds: secondsSent)
        }
    }

    /// Send anything left in the accumulator regardless of size. Called on
    /// stop() and on session.closed.
    private func flushPendingBuffers() {
        let (payload, secondsSent, task) = stateQueue.sync { () -> (Data?, Double, URLSessionWebSocketTask?) in
            let bytes = state.int16Accumulator
            state.int16Accumulator.removeAll()
            let samples = bytes.count / MemoryLayout<Int16>.size
            let seconds = Double(samples) / Self.outSampleRate
            return (bytes.isEmpty ? nil : bytes, seconds, state.task)
        }
        if let payload, let task {
            let b64 = payload.base64EncodedString()
            let event: [String: Any] = [
                "type": "session.input_audio_buffer.append",
                "audio": b64
            ]
            Task { [usageTracker] in
                await sendClientEvent(task: task, event: event)
                if secondsSent > 0 {
                    await usageTracker.recordChunk(seconds: secondsSent)
                }
            }
        }
        // Also commit any pending text buffers.
        commitBuffer(kind: .source, force: true)
        commitBuffer(kind: .target, force: true)
    }

    // MARK: - Segment commit (silence-debounce)

    private enum StreamKind { case source, target }

    private func appendDelta(_ delta: String, kind: StreamKind) {
        stateQueue.sync {
            switch kind {
            case .source: state.currentSourceBuf += delta
            case .target: state.currentTargetBuf += delta
            }
        }
        // Yield the live delta for the UI's current-line region.
        switch kind {
        case .source: eventsContinuation.yield(.sourceDelta(delta))
        case .target: eventsContinuation.yield(.targetDelta(delta))
        }
        rearmDebounce(kind: kind)
    }

    private func rearmDebounce(kind: StreamKind) {
        stateQueue.sync {
            let existing: DispatchSourceTimer?
            switch kind {
            case .source: existing = state.sourceDebounce
            case .target: existing = state.targetDebounce
            }
            existing?.cancel()

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            timer.schedule(deadline: .now() + .milliseconds(Self.debounceMs))
            timer.setEventHandler { [weak self] in
                self?.commitBuffer(kind: kind, force: false)
            }
            timer.resume()
            switch kind {
            case .source: state.sourceDebounce = timer
            case .target: state.targetDebounce = timer
            }
        }
    }

    private func commitBuffer(kind: StreamKind, force: Bool) {
        let text: String = stateQueue.sync {
            let buf: String
            switch kind {
            case .source:
                buf = state.currentSourceBuf
                state.currentSourceBuf = ""
                state.sourceDebounce?.cancel()
                state.sourceDebounce = nil
            case .target:
                buf = state.currentTargetBuf
                state.currentTargetBuf = ""
                state.targetDebounce?.cancel()
                state.targetDebounce = nil
            }
            return buf
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .target:
            // Only target commits feed the scrollback. An empty translation
            // shouldn't pollute history; skip the yield.
            if !trimmed.isEmpty {
                eventsContinuation.yield(.segmentComplete(trimmed))
            }
        case .source:
            // Source commit clears the visible source line independently of
            // target — the recognized source-language text is a UI
            // confidence-check, not content, so it never goes to history.
            // Yielding `.sourceComplete` (rather than tying source clearing
            // to `.segmentComplete`) avoids a race where the source debounce
            // fires ~200 ms before the target debounce: if a new utterance
            // starts in that gap, the late `.segmentComplete` of the prior
            // utterance must not clobber the fresh source line.
            eventsContinuation.yield(.sourceComplete)
        }
        _ = force  // reserved for future use (e.g., committing both regardless)
    }

    private func cancelDebounceTimers_locked() {
        state.sourceDebounce?.cancel()
        state.sourceDebounce = nil
        state.targetDebounce?.cancel()
        state.targetDebounce = nil
    }

    // MARK: - Helpers

    /// Map our target-language UI value to the two-letter ISO code the
    /// endpoint expects. `zh-Hant` and `zh-Hans` both collapse to `"zh"`;
    /// downstream OpenCC handles the Hant conversion.
    private func mapTargetLanguage(_ uiValue: String) -> String {
        switch uiValue {
        case "zh-Hant", "zh-Hans": return "zh"
        default: return uiValue
        }
    }

    /// Serialize and send a client event over the WS. Errors are logged but
    /// not surfaced — a one-off send failure usually precedes a transport
    /// drop that the receive loop will catch and reconnect from.
    private func sendClientEvent(task: URLSessionWebSocketTask, event: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            log.error("Failed to encode client event of type \(event["type"] as? String ?? "?", privacy: .public)")
            return
        }
        do {
            try await task.send(.string(text))
        } catch {
            log.warning("WS send failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
