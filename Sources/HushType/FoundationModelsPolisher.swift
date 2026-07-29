import Foundation
import FoundationModels
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "fm-polisher")

@available(macOS 26.0, *)
@MainActor
enum FoundationModelsPolisher {
    enum ValidationResult {
        case ok
        case unavailable(reason: String)
    }

    /// Prewarmed session pool of one. The OS does NOT share instruction-prefix
    /// KV cache across `LanguageModelSession` instances (measured 2026-07-22:
    /// identical vs unique instructions both ~690 ms), so a discarded warmup
    /// session buys nothing. Instead we keep one prewarmed standby, consume it
    /// for exactly one respond (statelessness preserved — no transcript
    /// accumulation), and prewarm a replacement afterwards. Measured saving:
    /// ~290 ms per polish; back-to-back polishes land on an in-flight prewarm
    /// and degrade gracefully to baseline, never worse.
    private static var standbySession: LanguageModelSession?
    private static var standbyFingerprint: Int?
    /// False after releaseSession() so an in-flight polish's replenish can't
    /// resurrect a standby for a feature the user just toggled off.
    private static var poolingEnabled = false

    static func availabilityReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return String(describing: reason)
        @unknown default:
            return "Unknown availability state"
        }
    }

    static func validate() async -> ValidationResult {
        if let reason = availabilityReason() {
            log.info("Validation: framework unavailable — \(reason, privacy: .public)")
            return .unavailable(reason: reason)
        }

        do {
            let session = LanguageModelSession(instructions: PolishPrompt.activePrompt())
            let options = GenerationOptions(temperature: 0.0)
            _ = try await session.respond(
                to: "Input: <selection>This sentence is correct.</selection>\nOutput:",
                options: options
            )
            log.info("Validation: round-trip succeeded")
            return .ok
        } catch {
            let reason = error.localizedDescription
            log.error("Validation: round-trip failed — \(reason, privacy: .public)")
            return .unavailable(reason: reason)
        }
    }

    static func warmup() {
        poolingEnabled = true
        replenishStandby(prompt: PolishPrompt.activePrompt())
        log.info("Warmup complete")
    }

    static func releaseSession() {
        poolingEnabled = false
        standbySession = nil
        standbyFingerprint = nil
        log.info("Text Polish standby session released")
    }

    private static func replenishStandby(prompt: String) {
        guard poolingEnabled else { return }
        let session = LanguageModelSession(instructions: prompt)
        // Must fire AFTER any in-flight respond has finished: the daemon
        // serializes a respond behind a just-issued prewarm (+320 ms measured).
        session.prewarm()
        standbySession = session
        standbyFingerprint = prompt.hashValue
    }

    static func polish(_ text: String, mixRetry: Bool = false) async -> Result<String, Error> {
        let prompt = PolishPrompt.activePrompt()
        let fingerprint = prompt.hashValue

        // Consume the standby if its instructions match the current prompt
        // (a polish_rules.txt edit changes the fingerprint and forces a cold
        // session). One respond per session — never reuse across polishes.
        let session: LanguageModelSession
        let standbyHit: Bool
        if let standby = standbySession, standbyFingerprint == fingerprint {
            session = standby
            standbyHit = true
        } else {
            session = LanguageModelSession(instructions: prompt)
            standbyHit = false
        }
        standbySession = nil
        standbyFingerprint = nil

        let options = GenerationOptions(temperature: 0.0)
        let reminder = mixRetry ? PolishPrompt.mixRetryReminder : ""
        // Chinese-dominant mixed selections get a strong English instruction
        // BEFORE the input — the only placement the model obeys — to stop it
        // from translating the embedded English (see PolishPrompt).
        let preReminder = PolishPrompt.isChineseDominantMix(text) ? PolishPrompt.mixPreReminder : ""
        let userPrompt = preReminder + "Input: <selection>\(text)</selection>\(reminder)\nOutput:"

        defer { replenishStandby(prompt: prompt) }
        do {
            let response = try await session.respond(to: userPrompt, options: options)
            log.debug("Polish response fingerprint=\(fingerprint, privacy: .public) standby_hit=\(standbyHit, privacy: .public) transcript_entries=\(response.transcriptEntries.count, privacy: .public)")
            return .success(sanitize(response.content, input: text))
        } catch LanguageModelSession.GenerationError.unsupportedLanguageOrLocale where preReminder.isEmpty {
            // The framework misclassifies some mixed selections as an
            // unsupported language. An English pre-reminder changes that
            // detection outcome (probe-verified 2026-07-29), so retry once
            // with it forced before surfacing the error.
            log.info("unsupportedLanguageOrLocale — retrying once with mix pre-reminder")
            do {
                let retrySession = LanguageModelSession(instructions: prompt)
                let retryPrompt = PolishPrompt.mixPreReminder
                    + "Input: <selection>\(text)</selection>\(reminder)\nOutput:"
                let response = try await retrySession.respond(to: retryPrompt, options: options)
                return .success(sanitize(response.content, input: text))
            } catch {
                log.error("Polish failed after language retry: \(error.localizedDescription, privacy: .public)")
                return .failure(error)
            }
        } catch {
            log.error("Polish failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    private static func stripPrefix(_ raw: String) -> String {
        let leadingTrimmed = raw.drop { $0.isWhitespace }
        for prefix in ["Output:", "output:", "輸出：", "输出："] {
            if leadingTrimmed.hasPrefix(prefix) {
                return String(leadingTrimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return raw
    }

    /// The model deterministically echoes the `<selection>` wrapper for some
    /// inputs (observed on trailing-apostrophe selections). Strip it unless the
    /// user's own selection was wrapped the same way.
    static func sanitize(_ raw: String, input: String) -> String {
        var value = stripPrefix(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<selection>"), value.hasSuffix("</selection>"),
           !(trimmedInput.hasPrefix("<selection>") && trimmedInput.hasSuffix("</selection>")) {
            value = String(value.dropFirst("<selection>".count).dropLast("</selection>".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}
