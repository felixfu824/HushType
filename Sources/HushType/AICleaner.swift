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
    static func clean(_ text: String) async -> String {
        guard AppConfig.shared.aiCleanupEnabled else { return text }

        if #available(macOS 26.0, *) {
            return await FoundationModelsCleaner.clean(text)
        }
        return text
    }
}
