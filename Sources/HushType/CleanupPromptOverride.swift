import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "cleanup-prompt-override")

enum CleanupPromptOverride {
    /// Absolute path to the override file. Reads `AppConfig.cleanupPromptOverrideURL`.
    static var fileURL: URL { AppConfig.cleanupPromptOverrideURL }

    /// mtime of the file the last time we successfully parsed it.
    private static var cachedMtime: Date?

    /// Parsed prompt contents, or nil when the file is missing/empty/all-comments.
    private static var cachedResult: String?

    /// Tracks whether the file existed at the last check so disappearances can
    /// be detected separately from mtime changes.
    private static var cachedFileExists = false

    /// Returns the override prompt (with full-line `#` comments stripped and
    /// globally trimmed) if the file exists and is non-empty after stripping.
    /// Returns nil otherwise, so callers fall back to the baked-in prompt.
    ///
    /// Internally cached by mtime. First call (or after mtime change or
    /// appearance/disappearance) re-reads and re-parses; subsequent calls with
    /// unchanged mtime are stat-only.
    ///
    /// Concurrency: not thread-safe by design. Current callers reach this via
    /// `CleanupPrompt.activePrompt()` from `FoundationModelsCleaner` on the main
    /// actor. If a non-main-actor caller is ever added, this cache state needs
    /// explicit synchronization.
    static func currentPrompt() -> String? {
        let previousResult = cachedResult
        let previousFileExists = cachedFileExists

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch {
            if previousFileExists {
                cachedMtime = nil
                cachedResult = nil
                cachedFileExists = false
                log.debug("Override file disappeared")
            }
            return nil
        }

        let mtime = attributes[.modificationDate] as? Date
        if let mtime, previousFileExists, cachedMtime == mtime {
            return cachedResult
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            cachedMtime = nil
            cachedResult = nil
            cachedFileExists = false
            log.warning("Failed to read override file at \(fileURL.path, privacy: .public)")
            return nil
        }

        guard let contents = String(data: data, encoding: .utf8) else {
            cachedMtime = nil
            cachedResult = nil
            cachedFileExists = false
            log.warning("Override file is not valid UTF-8: \(fileURL.path, privacy: .public)")
            return nil
        }

        let parsed = parseOverrideFile(contents)
        cachedMtime = mtime
        cachedResult = parsed
        cachedFileExists = true

        if !previousFileExists {
            log.debug("Override file appeared")
        } else if parsed != previousResult {
            log.debug("Override file changed")
        }

        return parsed
    }

    private static func parseOverrideFile(_ contents: String) -> String? {
        let kept = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmedForCheck = line.drop { $0 == " " || $0 == "\t" }
                return !trimmedForCheck.hasPrefix("#")
            }

        let joined = kept
            .map(String.init)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return joined.isEmpty ? nil : joined
    }
}
