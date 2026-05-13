import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "fillerFilter")

/// Drops VAD-segmented transcripts that are just vocal fillers (`呃。` `嗯。`
/// `Um.`) or lone punctuation. Runs in the live-caption post-processing chain
/// between `ChineseConverter` (OpenCC) and `DictionaryReplacer`.
///
/// Rules (see SPEC_live-caption.md §6):
/// 1. Chinese filler — `^[呃嗯啊哦哎ㄜ]+[，,。.]?\s*$`
/// 2. English filler — `^(um|uh|ah|mm|hm|er)[,.]?\s*$` (case-insensitive)
/// 3. Lone punctuation — `count <= 2` AND no Latin letter / no CJK ideograph
enum FillerFilter {
    /// Returns `true` to keep the segment, `false` to drop it.
    static func keep(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            log.debug("Dropped filler segment: <empty>")
            return false
        }

        // Rule 1 — Chinese filler
        if cleaned.range(of: "^[呃嗯啊哦哎ㄜ]+[，,。.]?\\s*$", options: [.regularExpression]) != nil {
            log.debug("Dropped filler segment: \(cleaned, privacy: .public)")
            return false
        }

        // Rule 2 — English filler (case-insensitive)
        if cleaned.range(of: "^(um|uh|ah|mm|hm|er)[,.]?\\s*$", options: [.regularExpression, .caseInsensitive]) != nil {
            log.debug("Dropped filler segment: \(cleaned, privacy: .public)")
            return false
        }

        // Rule 3 — Lone punctuation / particle: short AND contains nothing
        // useful (no Latin letter and no CJK Unified Ideograph). Bopomofo is
        // intentionally excluded here — already covered by rule 1.
        if cleaned.count <= 2 && !containsContentCharacter(cleaned) {
            log.debug("Dropped filler segment: \(cleaned, privacy: .public)")
            return false
        }

        return true
    }

    private static func containsContentCharacter(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                return true
            }
            // CJK Unified Ideographs: U+4E00 ... U+9FFF
            if (0x4E00 ... 0x9FFF).contains(scalar.value) {
                return true
            }
        }
        return false
    }

    #if DEBUG
    /// Runs the §6 test cases. Returns `true` on full pass. On any failure,
    /// calls `assertionFailure` and returns `false`. Called once from
    /// `AppDelegate.applicationDidFinishLaunching` in Debug builds; release
    /// builds skip entirely.
    static func runSelfTests() -> Bool {
        struct Case { let input: String; let expectKeep: Bool; let rule: String }
        let cases: [Case] = [
            .init(input: "呃", expectKeep: false, rule: "1"),
            .init(input: "呃。", expectKeep: false, rule: "1"),
            .init(input: "嗯，", expectKeep: false, rule: "1"),
            .init(input: "Um.", expectKeep: false, rule: "2"),
            .init(input: "um.", expectKeep: false, rule: "2"),
            .init(input: "Uh,", expectKeep: false, rule: "2"),
            .init(input: "好。", expectKeep: true,  rule: "single CJK"),
            .init(input: "OK.", expectKeep: true,  rule: "Latin letters"),
            .init(input: "呃, 我們", expectKeep: true, rule: "rule 1 requires ^fillers$"),
            .init(input: "呃?", expectKeep: true,  rule: "? not in trailing set"),
            .init(input: ".", expectKeep: false, rule: "3"),
            .init(input: "，", expectKeep: false, rule: "3"),
            .init(input: "好", expectKeep: true,  rule: "CJK present"),
        ]

        var allPassed = true
        for c in cases {
            let actual = keep(c.input)
            if actual != c.expectKeep {
                allPassed = false
                let kind = c.expectKeep ? "should keep" : "should drop"
                assertionFailure("FillerFilter case \(c.rule) failed: \"\(c.input)\" — \(kind), got keep=\(actual)")
            }
        }
        return allPassed
    }
    #endif
}
