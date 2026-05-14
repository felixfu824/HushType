import Foundation
import SpeechVAD
import Qwen3ASR
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "backendLocal")

/// Thin `TranscriptionBackend` adapter around `LiveCaptionWorker`. Yields
/// `.targetDelta(text)` immediately followed by `.segmentComplete(text)` for
/// each segment the worker emits. The local path has no "current line"
/// concept (Qwen3-ASR doesn't expose partials between VAD boundaries), so
/// `currentTargetLine` is essentially toggled on and off in a single tick —
/// the manager-side dual-line region is never visibly populated on local. The
/// `isCurrent` highlight on `segments.last` stays the visible affordance.
///
/// `sourceDelta` is never yielded — local has only one stream.
///
/// Lifecycle: on `stop()`, cancel the inner consumer Task, `await worker.reset()`,
/// then finish the outer continuation so the manager's outer `for await` exits
/// cleanly. Responsibility for `worker.reset()` moves from `LiveCaptionManager`
/// into the backend (spec §14 "the manager no longer calls worker.reset()").
final class LocalQwen3Backend: TranscriptionBackend, @unchecked Sendable {

    let events: AsyncStream<BackendEvent>
    private let eventsContinuation: AsyncStream<BackendEvent>.Continuation

    private let worker: LiveCaptionWorker
    private let workerSegmentStream: AsyncStream<LiveCaptionSegment>
    private var consumerTask: Task<Void, Never>?

    init(
        asrModel: Qwen3ASRModel,
        vadModel: SileroVADModel,
        language: String?,
        tuning: LiveCaptionTuning
    ) {
        // Build the inner segment stream that LiveCaptionWorker yields into.
        let (segStream, segCont) = AsyncStream.makeStream(of: LiveCaptionSegment.self)
        self.workerSegmentStream = segStream
        self.worker = LiveCaptionWorker(
            asrModel: asrModel,
            vadModel: vadModel,
            segmentContinuation: segCont,
            language: language,
            tuning: tuning
        )

        // Build the outer event stream the manager consumes.
        let (evStream, evCont) = AsyncStream.makeStream(of: BackendEvent.self)
        self.events = evStream
        self.eventsContinuation = evCont
    }

    func start() async throws {
        // The worker is ready as soon as it's constructed. Spin up the
        // segment-to-event bridge here so `start()` is a single entry point.
        consumerTask = Task { [weak self, workerSegmentStream, eventsContinuation] in
            for await segment in workerSegmentStream {
                _ = self  // keep self alive; weak only for the cancellation guard
                if Task.isCancelled { break }
                let text = segment.text
                eventsContinuation.yield(.targetDelta(text))
                eventsContinuation.yield(.segmentComplete(text))
            }
        }
    }

    func feed(samples: [Float]) async {
        await worker.feed(samples)
    }

    func stop() async {
        consumerTask?.cancel()
        consumerTask = nil
        await worker.reset()
        eventsContinuation.finish()
        log.info("LocalQwen3Backend stopped")
    }

    /// Local-only: force-emit whatever's in the worker's in-flight buffer.
    /// Called by `LiveCaptionManager`'s force-split timer when an active
    /// speech segment exceeds the configured force-split duration. Cloud
    /// backend has its own commit cadence (silence debounce) and no
    /// equivalent operation.
    func forceSplit() async {
        await worker.forceSplit()
    }

    /// Local-only: wall-clock time the worker started its current speech
    /// segment, if any. Used by the manager's force-split timer.
    func activeSpeechStartedAt() async -> Date? {
        await worker.activeSpeechStartedAt()
    }
}
