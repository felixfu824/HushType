import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "liveCaptionTuning")

/// User-editable knobs for Live Caption. Mirrors the dictionary-file pattern:
/// the file lives in `~/Library/Application Support/HushType/live_caption.json`,
/// edits take effect on the next `LiveCaptionManager.start()` (toggle off →
/// on). The Caption pane has an advanced-tuning button that opens the file in
/// the default editor.
///
/// Keep the schema small and inline-documented — comment keys are siblings
/// (`"_comment_X": "..."`), so the file remains valid JSON while explaining
/// every knob in place.
struct LiveCaptionTuning: Codable, Sendable {
    /// ASR decoder max generated tokens per segment. Larger budgets cost
    /// more decoder KV cache per call and risk runaway generation past EOS.
    /// Speech-swift default is 448, validated stable on the 15-min long
    /// session test.
    var maxTokens: Int = 448

    /// MLX GPU buffer pool cap in MB. Lower = less RAM but cold transcribes;
    /// higher = warm cache. 128 was too tight (thrashed against the limit
    /// and slowed every call). 1024 is generous on Apple Silicon.
    var mlxCacheLimitMB: Int = 1024

    /// VAD probability threshold to enter speech state (0.0-1.0). Lower = more
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

    /// Audio source for Live Caption: `"mic"` or `"system"`.
    /// Switch via the menu submenu or by editing here + toggling Live Caption
    /// off → on. The menu always wins on conflict (last write).
    var audioSource: String = "mic"

    /// Last-picked app's bundle identifier for system-audio Live Caption.
    /// Set automatically by `SystemAudioPicker`; can be hand-edited.
    /// Empty string means "no app picked yet — show picker on next start".
    var systemAudioBundleID: String = ""

    init() {}

    /// Decode every knob independently so an older tuning file remains valid
    /// when newer fields (notably `audioSource`) have not been written yet.
    /// Synthesized Codable would reject the whole file on the first missing
    /// non-optional key and silently discard all of the user's tuned values.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maxTokens = try values.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 448
        mlxCacheLimitMB = try values.decodeIfPresent(Int.self, forKey: .mlxCacheLimitMB) ?? 1024
        vadOnset = try values.decodeIfPresent(Float.self, forKey: .vadOnset) ?? 0.5
        vadOffset = try values.decodeIfPresent(Float.self, forKey: .vadOffset) ?? 0.35
        vadMinSpeechSeconds = try values.decodeIfPresent(Float.self, forKey: .vadMinSpeechSeconds) ?? 0.25
        vadMinSilenceSeconds = try values.decodeIfPresent(Float.self, forKey: .vadMinSilenceSeconds) ?? 0.1
        forceSplitSeconds = try values.decodeIfPresent(Double.self, forKey: .forceSplitSeconds) ?? 10
        backpressureMaxPending = try values.decodeIfPresent(Int.self, forKey: .backpressureMaxPending) ?? 50
        audioSource = try values.decodeIfPresent(String.self, forKey: .audioSource) ?? "mic"
        systemAudioBundleID = try values.decodeIfPresent(String.self, forKey: .systemAudioBundleID) ?? ""
    }

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
    static func load(at url: URL = fileURL) -> LiveCaptionTuning {
        if !FileManager.default.fileExists(atPath: url.path) {
            createTemplateIfMissing(at: url)
            return LiveCaptionTuning()
        }

        do {
            let data = try Data(contentsOf: url)
            // Strip `_comment_*` keys before decoding so the user can edit the
            // file with inline annotations and still have it decode.
            let stripped = try stripCommentKeys(from: data)
            let decoded = try JSONDecoder().decode(LiveCaptionTuning.self, from: stripped)
            log.info("Loaded live caption tuning from \(url.path, privacy: .public)")
            // Forward-migrate: if a newer build added knobs that aren't in
            // the user's file yet, write them in (with defaults) so the user
            // can edit them in place without losing their other tweaks.
            migrateMissingKeysIfNeeded(url: url, decoded: decoded)
            return decoded
        } catch {
            log.error("Failed to parse live_caption.json (\(error.localizedDescription, privacy: .public)) — falling back to defaults")
            return LiveCaptionTuning()
        }
    }

    /// Persist a new audio source ("mic" | "system") chosen via the menu.
    static func setAudioSource(_ source: String) {
        writeKey("audioSource", value: source)
    }

    /// Persist a new system-audio bundle identifier chosen via the picker.
    static func setSystemAudioBundleID(_ bundleID: String) {
        writeKey("systemAudioBundleID", value: bundleID)
    }

    /// Partial in-place rewrite that preserves `_comment_*` keys and other
    /// user edits. Used by the audio-source and system-app setters.
    private static func writeKey(_ key: String, value: Any, to url: URL = fileURL) {
        writeKeys([key: value], to: url)
    }

    /// Partial rewrite used by production setters and Phase 4 temporary-file
    /// tests. A missing file is initialized from the complete template before
    /// mutation; malformed existing JSON is left untouched.
    private static func writeKeys(_ updates: [String: Any], to url: URL) {
        createTemplateIfMissing(at: url)
        guard
            let data = try? Data(contentsOf: url),
            var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        for (key, value) in updates {
            obj[key] = value
        }
        guard let out = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? out.write(to: url, options: .atomic)
    }

    /// Creates the JSON template with inline `_comment_*` annotations on
    /// first run. No-op if the file already exists.
    static func createTemplateIfMissing() {
        createTemplateIfMissing(at: fileURL)
    }

    static func createTemplateIfMissing(at url: URL) {
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

    private static func migrateMissingKeysIfNeeded(url: URL, decoded: LiveCaptionTuning) {
        guard
            let raw = try? Data(contentsOf: url),
            var obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return }

        // Re-encode the decoded struct to a plain dictionary; whatever keys
        // it has are the canonical set we know about. Anything missing from
        // the user's file gets the default value written in. Existing user
        // values (and any `_comment_*` keys) are preserved untouched.
        guard
            let encoded = try? JSONEncoder().encode(decoded),
            let defaults = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { return }

        var dirty = false
        for (key, value) in defaults {
            if obj[key] == nil {
                obj[key] = value
                dirty = true
            }
        }
        guard dirty else { return }
        guard let out = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? out.write(to: url, options: .atomic)
        log.info("Migrated live_caption.json — added new default keys")
    }

    private static func stripCommentKeys(from data: Data) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        for key in Array(obj.keys) where key.hasPrefix("_comment_") || key == "_comment" {
            obj.removeValue(forKey: key)
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    static func templateContent() -> String {
        """
        {
          "_comment_about": \(localizedTemplateComment(
              "template.live_caption.about",
              fallback: "HushType: Live Caption tunables. Edit values then toggle Live Caption off and on for changes to apply. Keys prefixed _comment_ are documentation only and are ignored by the parser."
          )),

          "_comment_maxTokens": \(localizedTemplateComment(
              "template.live_caption.max_tokens",
              fallback: "ASR decoder max generated tokens per segment. Larger budgets cost more decoder KV cache per call and risk runaway generation past EOS. Speech-swift default is 448, validated stable on the 15-min long session test. Bumping past 1024 has been observed to push unified memory off a cliff."
          )),
          "maxTokens": 448,

          "_comment_mlxCacheLimitMB": \(localizedTemplateComment(
              "template.live_caption.mlx_cache",
              fallback: "MLX GPU buffer pool cap in MB. Lower = less RAM but cold transcribes; higher = warm cache. 128 was too tight; 1024 is the perf-tuned default on Apple Silicon. Drop to 256 or 512 if you want a tighter RAM ceiling."
          )),
          "mlxCacheLimitMB": 1024,

          "_comment_vad_thresholds": \(localizedTemplateComment(
              "template.live_caption.vad_thresholds",
              fallback: "VAD probability thresholds to enter and exit speech state (0.0-1.0). Silero defaults 0.5 / 0.35. Lower onset = more sensitive (more fragments in noisy rooms)."
          )),
          "vadOnset": 0.5,
          "vadOffset": 0.35,

          "_comment_vad_durations": \(localizedTemplateComment(
              "template.live_caption.vad_durations",
              fallback: "minSpeech: how long confirmed speech must run before a segment can be emitted. minSilence: how much pause closes a segment. Both in seconds. Silero defaults 0.25 / 0.10."
          )),
          "vadMinSpeechSeconds": 0.25,
          "vadMinSilenceSeconds": 0.10,

          "_comment_forceSplit": \(localizedTemplateComment(
              "template.live_caption.force_split",
              fallback: "Force-split a continuous monologue at this duration (seconds). Spec default 10."
          )),
          "forceSplitSeconds": 10.0,

          "_comment_backpressure": \(localizedTemplateComment(
              "template.live_caption.backpressure",
              fallback: "Drop new audio buffers when more than this many feeds are pending at the worker actor. 50 ≈ 2 s of audio, enough room for a cold first-cold transcribe without unbounded queueing."
          )),
          "backpressureMaxPending": 50,

          "_comment_audioSource": \(localizedTemplateComment(
              "template.live_caption.audio_source",
              fallback: "Source for Live Caption: 'mic' or 'system'. Defaults to 'mic'. Switch via menu (Live Caption submenu) or by editing here + toggling Live Caption off/on. The menu always wins on conflict."
          )),
          "audioSource": "mic",

          "_comment_systemAudioBundleID": \(localizedTemplateComment(
              "template.live_caption.system_bundle_id",
              fallback: "Last-picked app's bundle identifier for system-audio Live Caption. Set automatically by the picker; can be hand-edited. Empty means show picker on next start."
          )),
          "systemAudioBundleID": ""
        }
        """
    }

    /// Returns one complete JSON string literal for a localized template
    /// comment. Localized prose must never be interpolated into JSON raw.
    private static func localizedTemplateComment(_ key: String, fallback: String) -> String {
        L10n.jsonStringLiteral(L10n.string(key, table: "Templates", fallback: fallback))
    }
}
