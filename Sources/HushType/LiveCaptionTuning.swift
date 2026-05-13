import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "liveCaptionTuning")

/// User-editable knobs for Live Caption. Mirrors the dictionary-file pattern:
/// the file lives in `~/Library/Application Support/HushType/live_caption.json`,
/// edits take effect on the next `LiveCaptionManager.start()` (toggle off →
/// on). The status bar menu has an "Edit Live Caption Settings" item that
/// opens the file in the default editor.
///
/// Keep the schema small and inline-documented — comment keys are siblings
/// (`"_comment_X": "..."`), so the file remains valid JSON while explaining
/// every knob in place.
struct LiveCaptionTuning: Codable, Sendable {
    /// ASR decoder max generated tokens per segment. Larger budgets cost
    /// more decoder KV cache per call and risk runaway generation past EOS.
    /// Speech-swift default is 448 — validated stable on the 15-min long
    /// session test.
    var maxTokens: Int = 448

    /// MLX GPU buffer pool cap in MB. Lower = less RAM but cold transcribes;
    /// higher = warm cache. 128 was too tight (thrashed against the limit
    /// and slowed every call). 1024 is generous on Apple Silicon.
    var mlxCacheLimitMB: Int = 1024

    /// VAD probability threshold to enter speech state (0.0–1.0). Lower = more
    /// sensitive (fires on quieter audio). Silero default 0.5.
    var vadOnset: Float = 0.5
    /// VAD probability threshold to drop out of speech state. Silero default 0.35.
    var vadOffset: Float = 0.35
    /// Minimum confirmed speech duration (seconds). Silero default 0.25.
    var vadMinSpeechSeconds: Float = 0.25
    /// Minimum silence required to close a segment (seconds). Silero default 0.1.
    var vadMinSilenceSeconds: Float = 0.1

    /// Force-split a continuous speech segment that runs longer than this
    /// (seconds). Spec default 10.
    var forceSplitSeconds: Double = 10.0

    /// Drop audio frames when more than this many feeds are pending at the
    /// worker actor. 50 ≈ 2 s of audio at the AVAudioEngine buffer cadence.
    var backpressureMaxPending: Int = 50

    /// Default panel size. Persisted overrides from window drag/resize take
    /// precedence — see UserDefaults key `hushtype.liveCaption.panelFrame`.
    var panelDefaultWidth: Double = 1000
    var panelDefaultHeight: Double = 160

    // MARK: - File location

    static var fileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("HushType", isDirectory: true)
            .appendingPathComponent("live_caption.json")
    }

    // MARK: - Load / Template

    /// Reads `live_caption.json`. Missing or malformed → returns defaults
    /// and (if missing) writes the template so the user can find it.
    static func load() -> LiveCaptionTuning {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            createTemplateIfMissing()
            return LiveCaptionTuning()
        }

        do {
            let data = try Data(contentsOf: url)
            // Strip `_comment_*` keys before decoding so the user can edit the
            // file with inline annotations and still have it decode.
            let stripped = try stripCommentKeys(from: data)
            let decoded = try JSONDecoder().decode(LiveCaptionTuning.self, from: stripped)
            log.info("Loaded live caption tuning from \(url.path, privacy: .public)")
            return decoded
        } catch {
            log.error("Failed to parse live_caption.json (\(error.localizedDescription, privacy: .public)) — falling back to defaults")
            return LiveCaptionTuning()
        }
    }

    /// Creates the JSON template with inline `_comment_*` annotations on
    /// first run. No-op if the file already exists.
    static func createTemplateIfMissing() {
        let url = fileURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try templateContent().write(to: url, atomically: true, encoding: .utf8)
            log.info("Wrote live caption tuning template at \(url.path, privacy: .public)")
        } catch {
            log.error("Could not write tuning template: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internals

    private static func stripCommentKeys(from data: Data) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        for key in Array(obj.keys) where key.hasPrefix("_comment_") || key == "_comment" {
            obj.removeValue(forKey: key)
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    private static func templateContent() -> String {
        """
        {
          "_comment_about": "HushType — Live Caption tunables. Edit values then toggle Live Caption off and on for changes to apply. Keys prefixed _comment_ are documentation only and are ignored by the parser.",

          "_comment_maxTokens": "ASR decoder max generated tokens per segment. Larger budgets cost more decoder KV cache per call and risk runaway generation past EOS. Speech-swift default is 448 — validated stable on the 15-min long session test. Bumping past 1024 has been observed to push unified memory off a cliff.",
          "maxTokens": 448,

          "_comment_mlxCacheLimitMB": "MLX GPU buffer pool cap in MB. Lower = less RAM but cold transcribes; higher = warm cache. 128 was too tight; 1024 is the perf-tuned default on Apple Silicon. Drop to 256 or 512 if you want a tighter RAM ceiling.",
          "mlxCacheLimitMB": 1024,

          "_comment_vad_thresholds": "VAD probability thresholds to enter and exit speech state (0.0–1.0). Silero defaults 0.5 / 0.35. Lower onset = more sensitive (more fragments in noisy rooms).",
          "vadOnset": 0.5,
          "vadOffset": 0.35,

          "_comment_vad_durations": "minSpeech: how long confirmed speech must run before a segment can be emitted. minSilence: how much pause closes a segment. Both in seconds. Silero defaults 0.25 / 0.10.",
          "vadMinSpeechSeconds": 0.25,
          "vadMinSilenceSeconds": 0.10,

          "_comment_forceSplit": "Force-split a continuous monologue at this duration (seconds). Spec default 10.",
          "forceSplitSeconds": 10.0,

          "_comment_backpressure": "Drop new audio buffers when more than this many feeds are pending at the worker actor. 50 ≈ 2 s of audio — enough room for a cold first-cold transcribe without unbounded queueing.",
          "backpressureMaxPending": 50,

          "_comment_panel": "Default panel size (pixels). Window drag / resize values persist separately and override this on next launch.",
          "panelDefaultWidth": 1000,
          "panelDefaultHeight": 160
        }
        """
    }
}
