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
    /// precedence — see UserDefaults key `hushtype.liveCaption.panelFrame.v2`.
    var panelDefaultWidth: Double = 1500
    var panelDefaultHeight: Double = 160

    /// One-shot signal: set to `true` in the JSON file to force the next
    /// Live Caption start to ignore any persisted frame and re-apply
    /// `panelDefaultWidth`/`panelDefaultHeight`. The app clears the persisted
    /// frame and resets this flag back to `false` after applying.
    var resetPanelOnNextStart: Bool = false

    /// Audio source for Live Caption: `"mic"` or `"system"`.
    /// Switch via the menu submenu or by editing here + toggling Live Caption
    /// off → on. The menu always wins on conflict (last write).
    var audioSource: String = "mic"

    /// Last-picked app's bundle identifier for system-audio Live Caption.
    /// Set automatically by `SystemAudioPicker`; can be hand-edited.
    /// Empty string means "no app picked yet — show picker on next start".
    var systemAudioBundleID: String = ""

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
            // Forward-migrate: if a newer build added knobs that aren't in
            // the user's file yet, write them in (with defaults) so the user
            // can edit them in place without losing their other tweaks.
            migrateMissingKeysIfNeeded(url: url, decoded: decoded)
            // Apply one-shot value bumps (e.g. panel width default raised
            // between builds — see runOneOffMigrationsIfNeeded).
            return runOneOffMigrationsIfNeeded(url: url, decoded: decoded)
        } catch {
            log.error("Failed to parse live_caption.json (\(error.localizedDescription, privacy: .public)) — falling back to defaults")
            return LiveCaptionTuning()
        }
    }

    /// Flip `resetPanelOnNextStart` back to `false` after the manager honored
    /// the one-shot reset. Preserves `_comment_*` keys and other user edits
    /// by doing a partial in-place rewrite.
    static func clearResetFlag() {
        writeKey("resetPanelOnNextStart", value: false)
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
    /// user edits. Used by `clearResetFlag` / `setAudioSource` /
    /// `setSystemAudioBundleID`.
    private static func writeKey(_ key: String, value: Any) {
        let url = fileURL
        guard
            let data = try? Data(contentsOf: url),
            var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        obj[key] = value
        guard let out = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? out.write(to: url, options: .atomic)
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

    /// One-shot migrations that bump existing values (as opposed to filling in
    /// new keys). Tracked via UserDefaults flags so each migration runs at
    /// most once. New users (no file) never hit these because the template
    /// already carries the latest defaults.
    private static func runOneOffMigrationsIfNeeded(url: URL, decoded: LiveCaptionTuning) -> LiveCaptionTuning {
        var current = decoded
        let defaults = UserDefaults.standard

        // panelDefaultWidth v2 bump (1300 → 1500). Felix's MBA testing showed
        // the prior default still felt cramped. Anything below 1500 that
        // looks like an unedited app default (1300, or the pre-Widen 700)
        // gets pushed up. Custom narrower widths (everything outside this
        // exact set) are left alone so we don't fight an explicit user choice.
        let migrationKey = "hushtype.liveCaption.tuningMigration.panelWidth.v2"
        if !defaults.bool(forKey: migrationKey) {
            defaults.set(true, forKey: migrationKey)
            let appDefaults: Set<Double> = [700, 800, 900, 1000, 1100, 1300]
            if appDefaults.contains(current.panelDefaultWidth) {
                writeKey("panelDefaultWidth", value: 1500)
                current.panelDefaultWidth = 1500
                log.info("Migration: bumped panelDefaultWidth → 1500")
            }
        }
        return current
    }

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
          "panelDefaultWidth": 1500,
          "panelDefaultHeight": 160,

          "_comment_resetPanelOnNextStart": "Set to true to discard any persisted frame and re-apply panelDefaultWidth/Height the next time Live Caption is toggled on. The app flips it back to false after applying.",
          "resetPanelOnNextStart": false,

          "_comment_audioSource": "Source for Live Caption: 'mic' or 'system'. Defaults to 'mic'. Switch via menu (Live Caption submenu) or by editing here + toggling Live Caption off/on. The menu always wins on conflict.",
          "audioSource": "mic",

          "_comment_systemAudioBundleID": "Last-picked app's bundle identifier for system-audio Live Caption. Set automatically by the picker; can be hand-edited. Empty means show picker on next start.",
          "systemAudioBundleID": ""
        }
        """
    }
}
