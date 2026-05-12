import Foundation

/// Non-gated façade over the macOS 26+ `FoundationModelsCleaner`.
///
/// `TranscriptionEngine` calls into this unconditionally. The façade swallows
/// all conditional logic (feature toggle + OS availability) so the transcription
/// pipeline stays simple:
///
///     text = ChineseConverter.convert(rawText)
///     text = await AICleaner.clean(text)    // always safe
///     return text
///
/// Behavior:
///   - If `aiCleanupEnabled` is false → return input unchanged.
///   - If running on macOS < 26     → return input unchanged.
///   - Otherwise delegate to `FoundationModelsCleaner.clean`, which itself
///     returns the input unchanged on any generation error.
///
/// Never throws, never blocks the caller on a hard error.
enum AICleaner {
    enum CleanupState: String {
        case disabled
        case fresh
        case prewarmed
    }

    struct CleanupTiming {
        let text: String
        let initMs: Int
        let respondMs: Int
        let state: CleanupState
        let transcriptEntries: Int
    }

    static func clean(_ text: String) async -> String {
        await cleanWithTiming(text).text
    }

    static func cleanWithTiming(_ text: String) async -> CleanupTiming {
        guard AppConfig.shared.aiCleanupEnabled else {
            return CleanupTiming(
                text: text,
                initMs: 0,
                respondMs: 0,
                state: .disabled,
                transcriptEntries: 0
            )
        }

        if #available(macOS 26.0, *) {
            let result = await FoundationModelsCleaner.cleanWithTiming(text)
            return CleanupTiming(
                text: result.text,
                initMs: result.initMs,
                respondMs: result.respondMs,
                state: result.state,
                transcriptEntries: result.transcriptEntries
            )
        }
        return CleanupTiming(
            text: text,
            initMs: 0,
            respondMs: 0,
            state: .disabled,
            transcriptEntries: 0
        )
    }
}
