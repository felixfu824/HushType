import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "dictionary")

/// User-editable customized dictionary applied as the final post-processing
/// step in the transcription pipeline. Pipeline order:
///
///     Qwen3-ASR → OpenCC s2twp → AI Cleanup → DictionaryReplacer → TextInserter
///
/// The dictionary is a plain text file at `~/Library/Application Support/HushType/dictionary.txt`,
/// one rule per line in `source -> target` format. Lines starting with `#` are
/// comments. The file is hot-reloaded on every transcription if its modification
/// time changed (single stat() call — negligible cost).
///
/// Separator: `->` with optional surrounding whitespace. Unicode arrow `→` also
/// accepted for users who paste it. The separator is intentionally visible
/// (unlike tab) so the format is self-documenting in any text editor.
///
/// Matching semantics:
///   - Longest match first (entries sorted by source length descending)
///   - All non-overlapping occurrences replaced
///   - Single pass — replacements do NOT cascade (rule A producing text that
///     would match rule B will NOT trigger rule B)
///   - **Case-insensitive on the source side, literal on the target side.**
///     The ASR model's output case is unpredictable (sometimes "cloud code",
///     sometimes "Cloud Code", sometimes "CLOUD CODE"), so source matching
///     ignores case. The target string is inserted verbatim, so "Claude Code"
///     always comes out exactly as "Claude Code". This uses Foundation's
///     `caseInsensitiveCompare` which handles Unicode case folding correctly.
///   - No regex, no wildcards — plain string matching only
///
/// Behavior on missing/empty/malformed file:
///   - File missing → returns input unchanged, no entries loaded
///   - Empty file (only comments/blank lines) → same as missing
///   - Malformed line (no tab, empty source) → skipped with log warning
enum DictionaryReplacer {

    private struct Entry {
        let source: String
        let target: String
    }

    /// Cached entries, sorted by source length descending (longest first).
    /// Empty when no file or all lines are comments/malformed.
    private static var entries: [Entry] = []

    /// Modification date of the file at last load. Used to detect external edits.
    private static var lastModified: Date?

    /// Whether the file existed at last check. Tracked separately from
    /// `lastModified` to detect file deletion.
    private static var fileExisted: Bool = false

    // MARK: - Public API

    /// Reload entries from disk if the file has changed since last load.
    /// Cheap to call before every transcription — does a single stat() and
    /// returns immediately if mtime is unchanged.
    static func reloadIfNeeded() {
        let url = AppConfig.dictionaryFileURL
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            // File deleted since last check — clear entries
            if fileExisted {
                entries = []
                lastModified = nil
                fileExisted = false
                log.info("Dictionary file removed — entries cleared")
            }
            return
        }

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date

        // Skip reload if mtime is unchanged AND we already loaded the file
        if let mtime, mtime == lastModified, fileExisted {
            return
        }

        // (Re)load
        load(from: url, mtime: mtime)
    }

    /// Apply all replacements to the input. Returns the input unchanged if
    /// no entries are loaded. Safe to call from any thread.
    ///
    /// Single-pass left-to-right scan: at each position, try to match the
    /// longest entry that fits. If a match is found, emit the target and skip
    /// past the source (so the inserted target text is NOT re-scanned —
    /// prevents cascading rules and infinite loops). Otherwise emit one
    /// character and advance.
    static func apply(_ text: String) -> String {
        reloadIfNeeded()

        guard !entries.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count)

        var index = text.startIndex
        let end = text.endIndex
        var anyReplaced = false

        outer: while index < end {
            // Try each entry (already sorted longest source first)
            for entry in entries {
                let sourceCount = entry.source.count

                // Cheap length guard before substring comparison
                guard let sourceEndIndex = text.index(index, offsetBy: sourceCount, limitedBy: end) else {
                    continue
                }

                // Case-insensitive comparison so the ASR model's unpredictable
                // casing ("cloud code" vs "Cloud Code" vs "CLOUD CODE") still
                // matches the user's source entry. Target is inserted literally.
                let candidate = text[index..<sourceEndIndex]
                if candidate.caseInsensitiveCompare(entry.source) == .orderedSame {
                    result.append(entry.target)
                    index = sourceEndIndex
                    anyReplaced = true
                    continue outer
                }
            }

            // No rule matched at this position — emit one character
            result.append(text[index])
            index = text.index(after: index)
        }

        if anyReplaced {
            log.debug("Dictionary applied: \(text) → \(result)")
        }
        return result
    }

    /// Number of currently loaded entries. Used by the menu subtitle.
    static var entryCount: Int {
        reloadIfNeeded()
        return entries.count
    }

    /// Whether the dictionary file currently exists on disk.
    /// Used by the menu to show "No dictionary file" vs "{N} entries loaded".
    static var fileExists: Bool {
        FileManager.default.fileExists(atPath: AppConfig.dictionaryFileURL.path)
    }

    /// Create the dictionary file with a friendly template at the standard
    /// location. Creates parent directories as needed. Idempotent: if the
    /// file already exists, returns false without overwriting.
    @discardableResult
    static func createTemplateIfMissing() -> Bool {
        let url = AppConfig.dictionaryFileURL
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            return false
        }

        // Ensure parent directory exists
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error("Failed to create dictionary directory: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let template = """
        # HushType Customized Dictionary
        # =============================
        #
        # One rule per line, in this format:
        #
        #     what you say  ->  what gets typed
        #
        # Use this to fix recurring transcription errors — proper nouns the
        # speech model always mishears, acronyms that come out spelled out,
        # technical terms with non-standard phonetics, etc.
        #
        # Rules:
        #   • Lines starting with #  are comments (ignored)
        #   • Blank lines are ignored
        #   • Source is CASE-INSENSITIVE: "cloud code", "Cloud Code", and
        #     "CLOUD CODE" all match the same rule. The target is inserted
        #     literally, so the output always matches what you wrote.
        #   • Plain string match only — no regex, no wildcards
        #   • Longest match wins when rules overlap
        #   • Changes take effect on the next transcription (no restart)
        #
        # ---------------------------------------------------------------
        # Examples (delete the # at the start of a line to activate it)
        # ---------------------------------------------------------------

        # Proper nouns the model mis-transcribes:
        # 拍粉       -> Python
        # Cloud code -> Claude Code
        # Enfropic   -> Anthropic

        # Acronym normalization:
        # U I U X    -> UI/UX

        # Technical jargon:
        # J.S.O.N    -> JSON

        # ---------------------------------------------------------------
        # Your entries below:
        # ---------------------------------------------------------------

        """

        do {
            try template.write(to: url, atomically: true, encoding: .utf8)
            log.info("Created dictionary template at \(url.path, privacy: .public)")
            return true
        } catch {
            log.error("Failed to write dictionary template: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Private

    private static func load(from url: URL, mtime: Date?) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            log.warning("Failed to read dictionary file at \(url.path, privacy: .public)")
            entries = []
            lastModified = nil
            fileExisted = false
            return
        }

        var loaded: [Entry] = []
        for (lineNumber, rawLine) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            // Skip blank lines and comments
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            // Find separator: prefer ASCII "->", fall back to Unicode "→"
            let separatorRange: Range<String.Index>?
            if let asciiRange = line.range(of: "->") {
                separatorRange = asciiRange
            } else if let unicodeRange = line.range(of: "→") {
                separatorRange = unicodeRange
            } else {
                separatorRange = nil
            }

            guard let range = separatorRange else {
                log.warning("Dictionary line \(lineNumber + 1) has no separator (expected ' -> '): \(line, privacy: .public)")
                continue
            }

            let source = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let target = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)

            if source.isEmpty {
                log.warning("Dictionary line \(lineNumber + 1) has empty source")
                continue
            }

            loaded.append(Entry(source: source, target: target))
        }

        // Sort by source length descending — longest match first prevents
        // partial replacement when one entry is a prefix of another
        loaded.sort { $0.source.count > $1.source.count }

        entries = loaded
        lastModified = mtime
        fileExisted = true
        log.info("Loaded \(loaded.count) dictionary entries")
    }
}
