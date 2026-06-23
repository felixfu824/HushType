import Foundation

/// Deterministic script classifier for the post-processing pipeline.
///
/// Several stages are Chinese-specific (OpenCC s2twp, ITN, punctuation
/// normalization). They previously keyed off "contains a Han char", which also
/// matches Japanese kanji and silently corrupted Japanese (本当→本當,
/// 三日坊主→3日坊主). This classifier gates those stages to `.zh` only.
///
/// The discriminator is kana: hiragana/katakana never appear in Chinese, so
/// their presence is a ~100% reliable Japanese signal. U+30FB (・ katakana
/// middle dot) is DELIBERATELY excluded from the kana range because Chinese
/// uses it as a foreign-name separator (約翰・藍儂) and must not read as JP.
enum Script {
    case zh    // Han, no kana / no hangul
    case ja    // contains kana
    case ko    // contains hangul, no kana
    case other // Latin / digits / symbols only
}

enum ScriptDetector {

    /// Single source of truth for "is a Han ideograph" — kept identical to the
    /// range `PunctuationNormalizer` uses for boundary-aware spacing.
    static func isHan(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v)        // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(v) // CJK Extension A
            || (0xF900...0xFAFF).contains(v) // CJK Compatibility Ideographs
    }

    static func isHan(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return isHan(v)
    }

    /// Classify by script. Kana wins over Han (Japanese mixes both); hangul wins
    /// over Han (Sino-Korean hanja). Pure Han with no kana ⇒ Chinese.
    static func detect(_ text: String) -> Script {
        var hasKana = false, hasHan = false, hasHangul = false
        for u in text.unicodeScalars {
            let v = u.value
            // Kana: hiragana + katakana letters + prolonged/iteration marks +
            // halfwidth katakana. EXCLUDES U+30FB (・) — shared with Chinese.
            if (0x3040...0x30FA).contains(v) || (0x30FC...0x30FF).contains(v) || (0xFF66...0xFF9F).contains(v) {
                hasKana = true
            } else if (0xAC00...0xD7A3).contains(v) {
                hasHangul = true
            } else if isHan(v) {
                hasHan = true
            }
        }
        if hasKana { return .ja }
        if hasHangul { return .ko }
        if hasHan { return .zh }
        return .other
    }
}
