import Foundation

/// Events a backend yields to the manager via its `events` AsyncStream.
///
/// Two streams are conceptually multiplexed onto one channel: source-language
/// deltas (only meaningful for the cloud translate path — it transcribes input
/// audio and exposes the recognition stream alongside the translation) and
/// target-language deltas (the canonical caption text). `.segmentComplete`
/// signals "this much text is final, hand it to `LiveCaptionManager.handleSegment`
/// for post-processing and append to the scrollback."
///
/// Local backend never emits `.sourceDelta` and never emits `.reconnecting`.
/// Cloud backend emits `.sourceDelta` only when the user has the source-line
/// preference on (filtered at the manager).
enum BackendEvent: Sendable {
    case sourceDelta(String)
    case targetDelta(String)
    /// Source-stream silence-debounce fired — clear the in-progress source
    /// current-line. Does NOT move anything to history (the recognized
    /// source-language text is a confidence-check, not content). Cloud only.
    case sourceComplete
    /// Target-stream silence-debounce fired — commit `text` to history and
    /// clear the in-progress target current-line. The source current-line
    /// is left untouched here so a new utterance that started in the gap
    /// between the source debounce firing and the target debounce firing
    /// doesn't get clobbered.
    case segmentComplete(String)
    case reconnecting(attempt: Int, max: Int)
    case error(Error)
}

/// Pluggable transcription/translation backend, owned by `LiveCaptionManager`.
///
/// Each backend owns its own `AsyncStream<BackendEvent>.Continuation` (created
/// at init) and yields events into it. The manager runs a single
/// `for await event in backend.events` loop and hops to `@MainActor` to apply
/// updates to the panel `LiveCaptionViewModel`.
///
/// `start()` may throw if the backend cannot initialize (auth failure for
/// cloud, model unavailable for local). `feed(samples:)` is called from the
/// audio IO thread via `Task { await backend.feed(...) }` — same backpressure
/// model as the existing local path. `stop()` must finish the `events`
/// continuation so the manager's consumer Task exits cleanly.
protocol TranscriptionBackend: AnyObject, Sendable {
    /// Hot stream the manager consumes from a single Task. Backend is
    /// responsible for finishing the stream on stop()/error.
    var events: AsyncStream<BackendEvent> { get }

    func start() async throws
    func feed(samples: [Float]) async
    func stop() async
}
