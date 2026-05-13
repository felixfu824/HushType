import Foundation
import Qwen3ASR
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "transcription")

// MARK: - Protocol

protocol TranscriptionEngine {
    var isLoaded: Bool { get }
    func load(progressHandler: ((Double, String) -> Void)?) async throws
    func transcribe(audio: [Float], language: String?) async -> String
}

// MARK: - Qwen3 Implementation

final class Qwen3TranscriptionEngine: TranscriptionEngine {
    private var model: Qwen3ASRModel?

    var isLoaded: Bool { model != nil }

    /// Read-only handle for the live-caption pipeline. Returns the loaded
    /// model instance so `LiveCaptionManager` can call `transcribe()` directly
    /// without going through the dictation post-processing chain.
    var loadedModel: Qwen3ASRModel? { model }

    func load(progressHandler: ((Double, String) -> Void)? = nil) async throws {
        let modelId = AppConfig.shared.modelId
        log.info("Loading model: \(modelId)")

        model = try await Qwen3ASRModel.fromPretrained(
            modelId: modelId,
            progressHandler: progressHandler
        )

        log.info("Model loaded successfully")
    }

    func transcribe(audio: [Float], language: String?) async -> String {
        guard let model else {
            log.error("Model not loaded")
            return ""
        }

        guard !audio.isEmpty else {
            log.warning("Empty audio buffer")
            return ""
        }

        let duration = Double(audio.count) / 16000.0
        log.info("Transcribing \(String(format: "%.1f", duration))s of audio...")

        let startTime = CFAbsoluteTimeGetCurrent()

        let rawText = model.transcribe(
            audio: audio,
            sampleRate: 16000,
            language: language
        )

        let asrElapsed = CFAbsoluteTimeGetCurrent() - startTime
        log.info("Raw transcription (\(String(format: "%.2f", asrElapsed))s): \(rawText)")

        // Apply Traditional Chinese conversion
        let convertedText = ChineseConverter.convert(rawText)
        if convertedText != rawText {
            log.info("After conversion: \(convertedText)")
        }

        // Apply number conversion (ITN) if enabled. Deterministic regex-based
        // pass that converts Chinese numerals to Arabic digits. Runs before
        // AI Cleanup so the cleanup prompt doesn't need to handle numbers.
        let itnResult: NumberNormalizer.Result
        if AppConfig.shared.numberConversionEnabled {
            itnResult = NumberNormalizer.normalize(convertedText)
            if itnResult.applied {
                log.info("After ITN: \(itnResult.text, privacy: .public) [\(itnResult.note, privacy: .public)]")
            } else if itnResult.note != "no-op" {
                log.debug("ITN skipped: \(itnResult.note, privacy: .public)")
            }
        } else {
            itnResult = NumberNormalizer.Result(text: convertedText, applied: false, note: "disabled")
        }

        // Apply AI Cleanup if enabled. No-op when disabled, when running on
        // macOS < 26, or when FoundationModels errors — in all those cases
        // the input is returned unchanged.
        let cleanup = await AICleaner.cleanWithTiming(itnResult.text)
        if cleanup.text != convertedText {
            log.info("After AI cleanup: \(cleanup.text)")
        }

        // Apply user customized dictionary as the final post-processing step.
        // No-op if the dictionary file doesn't exist or is empty.
        let dictText = DictionaryReplacer.apply(cleanup.text)
        if dictText != cleanup.text {
            log.info("After dictionary: \(dictText)")
        }

        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        let inCh = rawText.count
        let outCh = dictText.count
        let asrMs = Int(asrElapsed * 1000)
        let totalMs = Int(totalElapsed * 1000)
        let stateLabel = cleanup.state.rawValue

        let itnLabel = itnResult.applied ? "applied" : itnResult.note
        log.info("timings asr=\(asrMs, privacy: .public)ms itn=\(itnLabel, privacy: .public) cleanup_init=\(cleanup.initMs, privacy: .public)ms cleanup_respond=\(cleanup.respondMs, privacy: .public)ms cleanup_state=\(stateLabel, privacy: .public) cleanup_entries=\(cleanup.transcriptEntries, privacy: .public) total=\(totalMs, privacy: .public)ms in=\(inCh, privacy: .public)ch out=\(outCh, privacy: .public)ch")

        return dictText
    }

    func unload() {
        model = nil
        log.info("Model unloaded")
    }
}
