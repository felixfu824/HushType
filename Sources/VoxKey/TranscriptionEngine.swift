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

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        log.info("Raw transcription (\(String(format: "%.2f", elapsed))s): \(rawText)")

        // Apply Traditional Chinese conversion
        let convertedText = ChineseConverter.convert(rawText)
        if convertedText != rawText {
            log.info("After conversion: \(convertedText)")
        }

        return convertedText
    }

    func unload() {
        model = nil
        log.info("Model unloaded")
    }
}
