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
///   3. Shared session caching to avoid cold-start on every cleanup call
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

    /// Shared session created on first successful validate/clean call and
    /// reused across subsequent cleanups. Without caching, every cleanup
    /// would pay a ~3.6s cold-start penalty on the first inference.
    private static var sharedSession: LanguageModelSession?

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

    /// Pre-create the shared cleanup session and run a priming call. Called
    /// after a successful `validate()` and on app launch when AI Cleanup is
    /// already enabled. Makes the first real transcription fast.
    static func warmup() async {
        if sharedSession == nil {
            sharedSession = LanguageModelSession(instructions: CleanupPrompt.systemPrompt)
        }
        guard let session = sharedSession else { return }

        let options = GenerationOptions(temperature: 0.0)
        do {
            _ = try await session.respond(to: "輸入：ok\n輸出：", options: options)
            log.info("Warmup complete")
        } catch {
            log.warning("Warmup failed (non-fatal): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tear down the shared session. Called when the user toggles AI Cleanup
    /// off so we don't keep model state around needlessly.
    static func releaseSession() {
        sharedSession = nil
        log.info("Shared session released")
    }

    // MARK: - Cleanup

    /// Clean a transcription. On success returns the model's output with any
    /// "輸出：" echo prefix stripped. On any generation failure (safety filter,
    /// timeout, runtime error) returns the input unchanged — callers don't
    /// need to handle errors.
    static func clean(_ text: String) async -> String {
        if sharedSession == nil {
            sharedSession = LanguageModelSession(instructions: CleanupPrompt.systemPrompt)
        }
        guard let session = sharedSession else { return text }

        let options = GenerationOptions(temperature: 0.0)
        let userPrompt = "輸入：\(text)\n輸出："

        do {
            let response = try await session.respond(to: userPrompt, options: options)
            return stripPrefix(response.content)
        } catch {
            log.warning("Cleanup failed, returning original text: \(error.localizedDescription, privacy: .public)")
            return text
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
