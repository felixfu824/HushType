import Foundation
import FoundationModels
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "fm-cleaner")

/// Apple FoundationModels wrapper for HushType AI Cleanup.
///
/// Compile-time gated to macOS 26+. Callers outside that availability must
/// go through `AICleaner` (the non-gated façade), never reference this type
/// directly.
///
/// Responsibilities:
///   1. Runtime availability check (`SystemLanguageModel.default.availability`)
///   2. Round-trip validation on toggle-ON (`validate()`)
///   3. Prompt-aware prewarm bookkeeping without transcript reuse
///   4. Graceful fallback on any generation error: returns input unchanged
///
/// Thread model: the whole enum is `@MainActor`. All session state lives on
/// the main actor. Callers hop in via `await`.
@available(macOS 26.0, *)
@MainActor
enum FoundationModelsCleaner {

    enum ValidationResult {
        case ok
        case unavailable(reason: String)
    }

    /// Prompt fingerprint last passed through `prewarm()`. Cleanup itself
    /// remains stateless: every cleanup call builds a fresh session so
    /// transcript history cannot accumulate across dictations.
    private static var prewarmedPromptFingerprint: Int?

    // MARK: - Validation

    /// Check whether FoundationModels can actually serve generations right now.
    /// Called when the user flips AI Cleanup on. Performs a minimal round-trip
    /// to catch cases where `availability == .available` but runtime then fails
    /// (e.g., model still warming up, transient IPC issues).
    static func validate() async -> ValidationResult {
        let model = SystemLanguageModel.default

        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            let description = String(describing: reason)
            log.info("Validation: framework unavailable — \(description, privacy: .public)")
            return .unavailable(reason: description)
        @unknown default:
            return .unavailable(reason: "Unknown availability state")
        }

        do {
            let session = LanguageModelSession(instructions: "Echo the user message verbatim.")
            let options = GenerationOptions(temperature: 0.0)
            _ = try await session.respond(to: "ok", options: options)
            log.info("Validation: round-trip succeeded")
            return .ok
        } catch {
            let msg = error.localizedDescription
            log.error("Validation: round-trip failed — \(msg, privacy: .public)")
            return .unavailable(reason: msg)
        }
    }

    // MARK: - Session lifecycle

    /// Prewarm the active prompt. Called after a successful `validate()` and
    /// on app launch when AI Cleanup is already enabled. Uses `prewarm()` so
    /// warmup does not create transcript history that could leak into future
    /// cleanups.
    static func warmup() async {
        let prompt = CleanupPrompt.activePrompt()
        let fingerprint = prompt.hashValue

        let session = LanguageModelSession(instructions: prompt)
        session.prewarm()
        prewarmedPromptFingerprint = fingerprint
        log.info("Warmup complete")
    }

    /// Clear prompt-level warmup bookkeeping. Called when the user toggles
    /// AI Cleanup off so the next enable starts from a known state.
    static func releaseSession() {
        prewarmedPromptFingerprint = nil
        log.info("AI Cleanup warmup state released")
    }

    // MARK: - Cleanup

    /// Clean a transcription. On success returns the model's output with any
    /// "輸出：" echo prefix stripped. On any generation failure (safety filter,
    /// timeout, runtime error) returns the input unchanged — callers don't
    /// need to handle errors.
    static func clean(_ text: String) async -> String {
        return await cleanWithTiming(text).text
    }

    static func cleanWithTiming(_ text: String) async -> (text: String, initMs: Int, respondMs: Int, state: AICleaner.CleanupState, transcriptEntries: Int) {
        let prompt = CleanupPrompt.activePrompt()
        let fingerprint = prompt.hashValue
        let state: AICleaner.CleanupState = (prewarmedPromptFingerprint == fingerprint) ? .prewarmed : .fresh

        let tInit = CFAbsoluteTimeGetCurrent()
        let session = LanguageModelSession(instructions: prompt)
        let initMs = Int((CFAbsoluteTimeGetCurrent() - tInit) * 1000)

        let options = GenerationOptions(temperature: 0.0)
        let userPrompt = "輸入：\(text)\n輸出："

        let tRespond = CFAbsoluteTimeGetCurrent()
        do {
            let response = try await session.respond(to: userPrompt, options: options)
            let respondMs = Int((CFAbsoluteTimeGetCurrent() - tRespond) * 1000)
            let cleaned = stripPrefix(response.content)
            let transcriptEntries = response.transcriptEntries.count
            log.debug("Cleanup response fingerprint=\(fingerprint, privacy: .public) state=\(state.rawValue, privacy: .public) transcript_entries=\(transcriptEntries, privacy: .public)")
            return (cleaned, initMs, respondMs, state, transcriptEntries)
        } catch {
            let respondMs = Int((CFAbsoluteTimeGetCurrent() - tRespond) * 1000)
            log.warning("Cleanup failed, returning original text: \(error.localizedDescription, privacy: .public)")
            return (text, initMs, respondMs, state, 0)
        }
    }

    // MARK: - Helpers

    /// Strip any "輸出：" / "Output:" prefix the model might echo back.
    /// Some generations leak the label from the prompt template.
    private static func stripPrefix(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["輸出：", "输出：", "Output:", "output:"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return s
    }
}
