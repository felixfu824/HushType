import Foundation

/// How aggressively to strip the model's Chinese inline punctuation.
enum PunctuationMode: String {
    case soft  // drop inline 「，、；：」, keep sentence enders 。！？ (default)
    case hard  // drop all punctuation, keep neighbour-aware spacing
    case off   // passthrough
}

/// Removes Qwen3-ASR's over-aggressive *Chinese* inline punctuation.
///
/// Empirically the model over-punctuates Chinese (comma:period ≈ 1.94) but not
/// English / Japanese / Korean. So callers run this ONLY on text classified
/// `.zh` (via `ScriptDetector.detect`). It preserves sentence separation with
/// neighbour-aware spacing.
///
/// Rule ("Option 4", validated against 27 zh clips + ITN interaction):
///   - fullwidth inline 「，、；：」 → always removed
///   - ASCII inline `,;:` → removed ONLY adjacent to a Han char. This keeps
///     genuine code-switched English commas ("right, for sure") and ASCII
///     thousands/decimals produced by ITN (10,000 / 3.5).
///   - sentence enders 。！？.!?… → kept (soft) / removed (hard)
///   - brackets/dashes/middle-dot → kept (soft) / removed (hard)
///
/// Spacing on removal: a removed sentence-ender always leaves one space; an
/// inline mark between two Han chars leaves none (CJK needs no space); any
/// other boundary (Latin↔CJK, digit↔CJK) leaves one space. Runs of spaces are
/// collapsed and the result is trimmed.
enum PunctuationNormalizer {

    private static let finals:   Set<Character> = ["。", "！", "？", ".", "!", "?", "…"]
    private static let fwInline: Set<Character> = ["，", "、", "；", "："]
    private static let asInline: Set<Character> = [",", ";", ":"]
    private static let other:    Set<Character> = ["「", "」", "『", "』", "（", "）", "《", "》",
                                                   "〈", "〉", "【", "】", "—", "～", "·", "．"]

    static func apply(_ text: String, mode: PunctuationMode) -> String {
        guard mode != .off else { return text }

        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)

        for (i, ch) in chars.enumerated() {
            let prevHan = out.last.map { ScriptDetector.isHan($0) } ?? false
            let nextHan = (i + 1 < chars.count) ? ScriptDetector.isHan(chars[i + 1]) : false

            let isFinal = finals.contains(ch)
            let isFw    = fwInline.contains(ch)
            let isAs    = asInline.contains(ch)
            let isOther = other.contains(ch)

            let remove: Bool
            switch mode {
            case .off:
                remove = false
            case .soft:
                remove = isFw || (isAs && (prevHan || nextHan))
            case .hard:
                remove = isFinal || isFw || (isAs && (prevHan || nextHan)) || isOther
            }

            if !remove {
                out.append(ch)
                continue
            }
            if isFinal {
                out.append(" ")                  // sentence boundary → keep a gap
            } else if !(prevHan && nextHan) {
                out.append(" ")                  // space unless CJK↔CJK
            }
        }

        return String(out)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
