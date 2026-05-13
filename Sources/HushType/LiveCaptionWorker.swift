import Foundation
import AudioCommon
import SpeechVAD
import Qwen3ASR
import MLX
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "liveCaptionWorker")

/// Result of an ASR transcription emitted by `LiveCaptionWorker`.
struct LiveCaptionSegment: Sendable {
    let text: String
    /// Wall-clock time when the worker emitted this segment.
    let emittedAt: Date
    /// Speech duration in seconds.
    let duration: Float
}

/// Confines all non-thread-safe VAD/ASR state to a serial actor executor.
///
/// Mirrors `speech-swift`'s `StreamingASR.swift` for the audio-accumulation
/// contract: `VADEvent.speechEnded` carries `SpeechSegment` start/end times
/// in seconds, and the audio buffer to transcribe is sliced from a rolling
/// outer `samplesBuffer` whose index 0 corresponds to absolute sample
/// `sliceBaseSample`.
actor LiveCaptionWorker {
    private let asrModel: Qwen3ASRModel
    private let vadProcessor: StreamingVADProcessor
    private let segmentContinuation: AsyncStream<LiveCaptionSegment>.Continuation
    private let language: String?
    private let maxTokens: Int

    /// Rolling buffer of all live samples received since the most recent
    /// segment emission. `samplesBuffer[i]` corresponds to absolute sample
    /// index `sliceBaseSample + i`.
    private var samplesBuffer: [Float] = []
    private var sliceBaseSample: Int = 0
    private var currentSpeechStartTime: Date?

    private static let sampleRate: Int = 16000

    init(
        asrModel: Qwen3ASRModel,
        vadModel: SileroVADModel,
        segmentContinuation: AsyncStream<LiveCaptionSegment>.Continuation,
        language: String?,
        maxTokens: Int
    ) {
        self.asrModel = asrModel
        self.vadProcessor = StreamingVADProcessor(model: vadModel, config: .sileroDefault)
        self.segmentContinuation = segmentContinuation
        self.language = language
        self.maxTokens = maxTokens
    }

    /// Feed a buffer of 16kHz mono samples. Appends to the rolling buffer,
    /// runs VAD, and emits a segment per `.speechEnded` event.
    func feed(_ samples: [Float]) {
        samplesBuffer.append(contentsOf: samples)
        let events = vadProcessor.process(samples: samples)
        for event in events {
            switch event {
            case .speechStarted:
                currentSpeechStartTime = Date()
            case .speechEnded(let segment):
                emitSegment(segment)
            }
        }
        trimBufferIfNeeded()
    }

    /// Bound the rolling sample buffer so a long silent stretch (with no
    /// `.speechEnded` events to drain it) doesn't grow without bound.
    ///
    /// - When VAD is in confirmed silence (`currentSpeechStartTime == nil`),
    ///   trim to a small lookback window. The lookback must cover the
    ///   `pendingSpeech` window (`minSpeechDuration = 0.25s` at sileroDefault)
    ///   so a not-yet-confirmed speech start retains its leading audio.
    ///   `LookbackSeconds = 2` is safely larger than that.
    /// - When VAD is mid-speech (`currentSpeechStartTime != nil`), tolerate
    ///   growth up to the §10 force-split watermark (2× the 10s window) so
    ///   the force-split timer can still grab the full active utterance.
    ///   If the buffer crosses the hard cap before force-split fires, we
    ///   force-split immediately to drain.
    private func trimBufferIfNeeded() {
        let lookbackSamples = 2 * Self.sampleRate           // 2 s
        let hardCapSamples  = 32 * Self.sampleRate          // 32 s

        if currentSpeechStartTime == nil {
            if samplesBuffer.count > lookbackSamples * 2 {
                let drop = samplesBuffer.count - lookbackSamples
                samplesBuffer.removeFirst(drop)
                sliceBaseSample += drop
            }
            return
        }

        if samplesBuffer.count > hardCapSamples {
            log.warning("samplesBuffer exceeded hard cap (\(self.samplesBuffer.count, privacy: .public) samples) — force-splitting")
            forceSplit()
        }
    }

    /// Force-split a long monologue: §10 algorithm. Transcribe whatever's in
    /// `samplesBuffer` corresponding to the active speech, emit, trim,
    /// re-anchor the timer, but DO NOT reset VAD — hysteresis state continues
    /// across the split.
    func forceSplit() {
        // Only force-split if there is in-flight speech (timer was anchored).
        guard currentSpeechStartTime != nil else { return }
        guard !samplesBuffer.isEmpty else { return }

        let duration = Float(samplesBuffer.count) / Float(Self.sampleRate)
        let text = asrModel.transcribe(
            audio: samplesBuffer,
            sampleRate: Self.sampleRate,
            language: language,
            maxTokens: maxTokens
        )

        log.info("forceSplit emitted segment, duration=\(duration, privacy: .public)s, chars=\(text.count, privacy: .public)")
        segmentContinuation.yield(LiveCaptionSegment(text: text, emittedAt: Date(), duration: duration))

        sliceBaseSample += samplesBuffer.count
        samplesBuffer.removeAll(keepingCapacity: true)
        currentSpeechStartTime = Date()  // re-anchor for next force-split window

        MLX.Memory.clearCache()
    }

    /// Wall-clock time of the currently-active speech segment, if any. Used
    /// by `LiveCaptionManager` to decide whether the 10s force-split timer
    /// should fire.
    func activeSpeechStartedAt() -> Date? {
        currentSpeechStartTime
    }

    /// Tear down all worker state. Called from `LiveCaptionManager.stop()`.
    func reset() {
        samplesBuffer.removeAll(keepingCapacity: false)
        sliceBaseSample = 0
        currentSpeechStartTime = nil
        vadProcessor.reset()
    }

    // MARK: - Private

    private func emitSegment(_ segment: SpeechSegment) {
        let startSampleAbs = Int(segment.startTime * Float(Self.sampleRate))
        let endSampleAbs   = Int(segment.endTime   * Float(Self.sampleRate))

        let startIdx = max(0, startSampleAbs - sliceBaseSample)
        let endIdx   = min(samplesBuffer.count, endSampleAbs - sliceBaseSample)

        guard endIdx > startIdx else {
            log.warning("emitSegment: empty slice (startIdx=\(startIdx) endIdx=\(endIdx) baseSample=\(self.sliceBaseSample) bufLen=\(self.samplesBuffer.count))")
            currentSpeechStartTime = nil
            return
        }

        let audioSlice = Array(samplesBuffer[startIdx..<endIdx])
        let duration = Float(audioSlice.count) / Float(Self.sampleRate)

        let text = asrModel.transcribe(
            audio: audioSlice,
            sampleRate: Self.sampleRate,
            language: language,
            maxTokens: maxTokens
        )

        log.info("emitSegment duration=\(duration, privacy: .public)s chars=\(text.count, privacy: .public)")
        segmentContinuation.yield(LiveCaptionSegment(text: text, emittedAt: Date(), duration: duration))

        // Trim consumed samples and advance the base.
        samplesBuffer.removeFirst(endIdx)
        sliceBaseSample += endIdx
        currentSpeechStartTime = nil

        // Release MLX's buffer pool after every transcribe. Without this the
        // pool retains decoder KV-cache buffers between calls and unified
        // memory can climb hundreds of MB across a meeting.
        MLX.Memory.clearCache()
    }
}
