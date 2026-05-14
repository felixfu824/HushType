import Foundation
import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "openaiKey")

/// Reads (and on first call, creates) the user's OpenAI API key file used by
/// the cloud Live Caption engine. Plaintext JSON on disk; same security
/// profile as a `.env` file. Documented inside the file itself.
///
/// File format (forward-migrating, comments preserved on read):
/// ```json
/// {
///   "_comment_overview": "...",
///   "_comment_api_key":  "...",
///   "api_key":           "sk-...",
///   "_comment_organization": "...",
///   "organization":      ""
/// }
/// ```
///
/// Loader rules (§6):
/// 1. File missing → create with all-empty values + `_comment_*` keys. No
///    error surfaced.
/// 2. `api_key` empty → returns a status of `.empty`; cloud features stay
///    disabled. UI shows "Status: Key empty".
/// 3. `api_key` non-empty but doesn't start with `sk-` → log a warning,
///    still pass through. UI shows "Status: Key format unusual".
/// 4. Hot-reloadable: caller re-reads on every Live Caption start. No
///    daemon, no FSEvents.
///
/// The key is captured into the backend instance at `start()` and used for
/// the lifetime of that session including all reconnect retries (§6 bearer-
/// token lifetime). Editing `openai.json` mid-session has no effect until
/// the user stops and re-starts Live Caption.
enum OpenAIKeyStore {

    /// Result of a load. Distinct cases so the Settings UI can label status
    /// distinctly without inspecting the loaded credentials.
    enum LoadStatus: Equatable {
        case ok(apiKey: String, organization: String?)
        case empty
        case unusualFormat(apiKey: String, organization: String?)
    }

    private static let fileURL: URL = AppConfig.openAIKeyFileURL

    /// Read the key file, creating it on first call if missing. Never throws —
    /// I/O failures fall back to `.empty` so the UI can recover.
    static func load() -> LoadStatus {
        ensureExists()

        guard let data = try? Data(contentsOf: fileURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log.warning("openai.json present but unparseable; treating as empty")
            return .empty
        }

        let rawKey = (json["api_key"] as? String) ?? ""
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawOrg = (json["organization"] as? String) ?? ""
        let organization: String? = {
            let trimmed = rawOrg.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        if apiKey.isEmpty {
            return .empty
        }
        if !apiKey.hasPrefix("sk-") {
            log.warning("openai.json api_key does not start with 'sk-'; passing through anyway")
            return .unusualFormat(apiKey: apiKey, organization: organization)
        }
        return .ok(apiKey: apiKey, organization: organization)
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
        let body = """
        {
          "_comment_overview": "HushType cloud features — OpenAI API key. This file is plaintext on disk; treat it like a .env file. Get a key at https://platform.openai.com/api-keys. Cloud features stay disabled until 'api_key' is filled in AND you switch the engine in Settings.",
          "_comment_api_key": "Your OpenAI API key (sk-proj-... or sk-...). Leave empty to disable cloud features entirely.",
          "api_key": "",
          "_comment_organization": "Optional. Only set if you specifically need to scope usage to an org. Format: org-...",
          "organization": ""
        }
        """
        do {
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            log.info("Created openai.json at \(fileURL.path, privacy: .public) with empty values")
        } catch {
            log.error("Failed to create openai.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
