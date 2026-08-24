import Foundation
import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "geminiKey")

/// Reads (and on first call, creates) the user's Gemini API key file used by
/// the cloud Dictation engine. Plaintext JSON on disk; same security
/// profile as a `.env` file. Documented inside the file itself.
///
/// File format (forward-migrating, comments preserved on read):
/// ```json
/// {
///   "_comment_overview":  "...",
///   "_comment_api_key":   "...",
///   "api_key":            "AIza...",
///   "_comment_free_tier": "..."
/// }
/// ```
///
/// Loader rules (§6):
/// 1. File missing → create with all-empty values + `_comment_*` keys. No
///    error surfaced.
/// 2. `api_key` empty → returns a status of `.empty`; cloud features stay
///    disabled. UI shows "Status: Key empty".
/// 3. `api_key` non-empty but doesn't start with `AIza` → log a warning,
///    still pass through. UI shows "Status: Key format unusual".
/// 4. Hot-reloadable: caller re-reads on every session start. No
///    daemon, no FSEvents.
///
/// The key is captured into the backend instance at `start()` and used for
/// the lifetime of that session including all reconnect retries (§6 bearer-
/// token lifetime). Editing `gemini.json` mid-session has no effect until
/// the user stops and re-starts the session.
enum GeminiKeyStore {

    /// Result of a load. Distinct cases so the Settings UI can label status
    /// distinctly without inspecting the loaded credentials.
    enum LoadStatus: Equatable {
        case ok(apiKey: String)
        case empty
        case unusualFormat(apiKey: String)
    }

    /// Path to the Gemini API key file. (Defined here rather than in
    /// `AppConfig` so this file is self-contained.)
    private static var fileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("HushType", isDirectory: true)
        .appendingPathComponent("gemini.json")
    }

    /// Maximum accepted file size for `gemini.json`. Real keys fit in <200
    /// bytes; a 64 KB ceiling guards against errant editor / malware writing
    /// a gigabyte file that we'd otherwise faithfully read into RAM.
    private static let maxFileSize: Int = 64 * 1024

    /// Read the key file, creating it on first call if missing. Never throws —
    /// I/O failures fall back to `.empty` so the UI can recover.
    static func load() -> LoadStatus {
        ensureExists()

        // Defense in depth: refuse to follow symlinks AND refuse oversized
        // files. The path itself is system-controlled (Application Support /
        // HushType), so a malicious symlink there would already mean the user
        // account is compromised — but reading whatever the symlink points at
        // as JSON and pulling an `api_key` field out of it is a footgun we
        // don't need.
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path) {
            if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
                log.warning("gemini.json is a symlink; refusing to follow")
                return .empty
            }
            if let size = attrs[.size] as? Int, size > Self.maxFileSize {
                log.warning("gemini.json exceeds \(Self.maxFileSize, privacy: .public) byte cap (size=\(size, privacy: .public)); treating as empty")
                return .empty
            }
        }

        guard let data = try? Data(contentsOf: fileURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log.warning("gemini.json present but unparseable; treating as empty")
            return .empty
        }

        let rawKey = (json["api_key"] as? String) ?? ""
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if apiKey.isEmpty {
            return .empty
        }
        if !apiKey.hasPrefix("AIza") {
            log.warning("gemini.json api_key does not start with 'AIza'; passing through anyway")
            return .unusualFormat(apiKey: apiKey)
        }
        return .ok(apiKey: apiKey)
    }

    /// Open the key file in the user's default `.json` editor (TextEdit on a
    /// fresh macOS install — same flow as Edit Customized Dictionary).
    static func openInDefaultEditor() {
        ensureExists()
        NSWorkspace.shared.open(fileURL)
    }

    /// Absolute path string for display in Settings.
    static var displayPath: String {
        fileURL.path
    }

    /// Create the file with all-empty values + `_comment_*` keys if it does
    /// not exist. Idempotent.
    private static func ensureExists() {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) { return }

        // Create parent directory if needed.
        let parent = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        // Hand-write the file so the comment keys land in the expected order.
        // JSONSerialization with sorted keys won't preserve our human-friendly
        // ordering, and Apple's JSONEncoder doesn't guarantee key order at
        // all for dictionaries.
        let overview = L10n.jsonStringLiteral(L10n.string(
            "template.gemini.overview",
            table: "Templates",
            fallback: "HushType cloud features: Gemini API key. This file is plaintext on disk; treat it like a .env file. Get a key at https://aistudio.google.com/apikey. Cloud features stay disabled until 'api_key' is filled in. The engine is chosen in HushType's Dictation Engine settings."
        ))
        let apiKeyComment = L10n.jsonStringLiteral(L10n.string(
            "template.gemini.api_key",
            table: "Templates",
            fallback: "Your Gemini API key (AIza...). Leave empty to disable cloud features entirely."
        ))
        let freeTierComment = L10n.jsonStringLiteral(L10n.string(
            "template.gemini.free_tier_policy",
            table: "Templates",
            fallback: "On Google's free tier, Google may use submitted audio to improve its products. The paid tier does not."
        ))
        let body = """
        {
          "_comment_overview": \(overview),
          "_comment_api_key": \(apiKeyComment),
          "api_key": "",
          "_comment_free_tier": \(freeTierComment)
        }
        """
        do {
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            // 0600 by default — same threat model as `.env`, no reason to be
            // world-readable. `String.write(...)` respects the user's umask
            // which on macOS yields 0644; we override explicitly so users on
            // multi-user Macs don't get the key file readable by every other
            // local account.
            try? fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
            log.info("Created gemini.json at \(fileURL.path, privacy: .public) with empty values")
        } catch {
            log.error("Failed to create gemini.json: \(error.localizedDescription, privacy: .public)")
        }
    }

}
