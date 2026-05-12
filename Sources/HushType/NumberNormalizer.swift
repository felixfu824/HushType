import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "itn")

/// Inverse Text Normalization (ITN) for Chinese numbers.
///
/// Converts Chinese-numeral expressions to Arabic-digit form as a
/// post-processing pass between OpenCC and AI Cleanup. Designed around
/// Felix's asymmetric requirement: PASS best, MISS acceptable, CORRUPT
/// near-zero. See `Product_WS/SPEC_itn-number-normalizer.md`.
///
/// Status: Phase 1 — implemented but NOT yet wired into `TranscriptionEngine`.
/// Run the regression harness with `swift scripts/test_number_normalizer.swift`.
enum NumberNormalizer {

    struct Result {
        let text: String      // transformed text (or original if skipped/rejected)
        let applied: Bool     // true if a non-trivial transformation was applied
        let note: String      // human-readable reason (for logs and tests)
    }

    /// Normalize a single string of transcription output.
    static func normalize(_ input: String) -> Result {
        // --- Pre-skip guards ---
        if IdiomGuard.contains(input) {
            return Result(text: input, applied: false, note: "skip (idiom)")
        }
        if SelfCorrectionGuard.contains(input) {
            return Result(text: input, applied: false, note: "skip (self-correction)")
        }
        if DegreeAmbiguityGuard.contains(input) {
            return Result(text: input, applied: false, note: "skip (度-ambiguity)")
        }

        // --- Rule passes (order matters) ---
        var work = input
        work = DecimalRule.apply(work)
        work = PercentRule.apply(work)
        work = MagnitudeRule.apply(work)
        work = YearRule.apply(work)
        work = RangeRule.apply(work)
        work = CounterRule.apply(work)
        work = UnitRewriteRule.apply(work)

        if work == input {
            return Result(text: input, applied: false, note: "no-op")
        }

        // --- Post-reject guards ---
        if OutputGuard.hasPartialConversion(work) {
            return Result(text: input, applied: false, note: "reject (partial-conversion)")
        }

        if OutputGuard.hasCurrencySymbol(work) {
            let rewritten = OutputGuard.rewriteCurrency(work)
            if OutputGuard.hasCurrencySymbol(rewritten) {
                return Result(text: input, applied: false, note: "reject (currency)")
            }
            work = rewritten
        }

        if OutputGuard.nonNumericDrift(original: input, output: work) {
            return Result(text: input, applied: false, note: "reject (non-numeric-drift)")
        }

        if OutputGuard.lengthRatioExtreme(original: input, output: work) {
            return Result(text: input, applied: false, note: "reject (length-extreme)")
        }

        return Result(text: work, applied: true, note: "applied")
    }
}

// MARK: - Chinese integer parser (0-9999)

/// Parses a run of Chinese numeric characters into an Int.
/// Supports zero through 9999 using the standard 十/百/千 positional system.
internal enum ChineseIntParser {

    static let digitMap: [Character: Int] = [
        "零": 0, "〇": 0,
        "一": 1, "二": 2, "兩": 2,
        "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9,
    ]

    static let unitMap: [Character: Int] = [
        "十": 10, "百": 100, "千": 1000,
    ]

    static let allChars: Set<Character> = {
        var s = Set(digitMap.keys)
        s.formUnion(unitMap.keys)
        return s
    }()

    /// Parse a Substring of Chinese digit + unit characters into an Int.
    /// Returns nil on unknown characters or structural inconsistencies.
    static func parse(_ s: Substring) -> Int? {
        if s.isEmpty { return nil }

        var total = 0
        var current = 0
        var sawDigit = false

        for ch in s {
            if let d = digitMap[ch] {
                current = d
                sawDigit = true
            } else if let u = unitMap[ch] {
                if !sawDigit {
                    // Bare 十 / 百 / 千 means 1 × unit (e.g., "十" = 10)
                    current = 1
                }
                total += current * u
                current = 0
                sawDigit = false
            } else {
                return nil
            }
        }
        total += current
        return total
    }

    /// Digit-by-digit parse for year / room-number style sequences.
    /// "二零二五" → "2025"
    static func parseDigitSequence(_ s: Substring) -> String? {
        var out = ""
        for ch in s {
            guard let d = digitMap[ch] else { return nil }
            out.append(Character("\(d)"))
        }
        return out
    }
}

// MARK: - Pre-skip guards

internal enum IdiomGuard {
    static let blacklist: [String] = [
        // "一" used non-numerically
        "一下", "一些", "一點", "一般", "一樣", "一定", "一直", "一起",
        "一邊", "一共", "一旦", "一向", "一概", "一律", "一會", "一輩子",
        "一心一意", "一五一十", "一心", "一意",
        "一個人", "一家人",
        // Repeated-small idioms
        "三三兩兩", "兩三", "一兩", "兩兩", "三兩",
        // Counted-big idioms
        "九牛二虎", "九死一生",
        // Proper nouns starting with small Chinese num
        "三國", "三皇", "三星", "三明治",
        // 萬/千 used non-numerically
        "萬一", "千萬要", "千萬別", "萬萬", "千千",
        // Ordinals
        "第一", "第二", "第三", "第四", "第五",
        "第六", "第七", "第八", "第九", "第十",
        // Colloquial
        "九成九", "八九不離十",
        "不二", "獨一無二",
    ]

    static func contains(_ text: String) -> Bool {
        for idiom in blacklist {
            if text.contains(idiom) { return true }
        }
        return false
    }
}

internal enum SelfCorrectionGuard {
    static let markers: [String] = ["不對", "錯了", "我是說", "不是說"]

    static func contains(_ text: String) -> Bool {
        for m in markers {
            if text.contains(m) { return true }
        }
        return false
    }
}

internal enum DegreeAmbiguityGuard {
    // "度" meaning "times/occasion" rather than "degree"
    // Use a set of substring patterns that are cheap and precise.
    static let markers: [String] = [
        "再度", "又一度", "又二度", "又三度", "又四度", "又五度",
    ]

    static func contains(_ text: String) -> Bool {
        for m in markers {
            if text.contains(m) { return true }
        }
        // Pattern: [一二三四五六七八九十]度被  (e.g., 五度被提名)
        if matchesDegreeBeiPattern(text) { return true }
        // Pattern: 第[一二三四五六七八九十0-9]+度  (e.g., 第三度空間)
        if matchesOrdinalDegreePattern(text) { return true }
        return false
    }

    private static func matchesDegreeBeiPattern(_ text: String) -> Bool {
        let chars = Array(text)
        let nums: Set<Character> = ["一", "二", "兩", "三", "四", "五",
                                    "六", "七", "八", "九", "十"]
        for i in 0..<chars.count - 2 {
            if nums.contains(chars[i]) && chars[i + 1] == "度" && chars[i + 2] == "被" {
                return true
            }
        }
        return false
    }

    private static func matchesOrdinalDegreePattern(_ text: String) -> Bool {
        // Cheap scan: look for 第, then up to 4 chars of numeric, then 度
        let chars = Array(text)
        let nums: Set<Character> = ["一", "二", "兩", "三", "四", "五",
                                    "六", "七", "八", "九", "十", "0", "1",
                                    "2", "3", "4", "5", "6", "7", "8", "9"]
        var i = 0
        while i < chars.count {
            if chars[i] == "第" && i + 2 < chars.count {
                var j = i + 1
                while j < chars.count && nums.contains(chars[j]) { j += 1 }
                if j > i + 1 && j < chars.count && chars[j] == "度" {
                    return true
                }
            }
            i += 1
        }
        return false
    }
}

// MARK: - Transform rules

/// `X點Y → X.Y` where Y is a run of single-digit Chinese numerals.
/// Restricted to single-digit Y to avoid time ambiguity (三點十五分 → 3:15, not 3.15).
internal enum DecimalRule {
    static func apply(_ text: String) -> String {
        // Pattern: one-or-more Chinese int chars, 點, one-or-more single Chinese digits
        // but NOT followed by 半, 分, 整 (time markers)
        let intClass = "[零一二三四五六七八九兩十百千]+"
        let digitClass = "[零一二三四五六七八九]+"
        let pattern = "(\(intClass))點(\(digitClass))(?![半分整])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }

        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }

        var result = text as NSString
        // Process from end to start so earlier ranges stay valid
        for m in matches.reversed() {
            let intSub = ns.substring(with: m.range(at: 1))
            let fracSub = ns.substring(with: m.range(at: 2))
            guard let intVal = ChineseIntParser.parse(Substring(intSub)),
                  let fracDigits = ChineseIntParser.parseDigitSequence(Substring(fracSub))
            else { continue }
            let replacement = "\(intVal).\(fracDigits)"
            result = result.replacingCharacters(in: m.range, with: replacement) as NSString
        }
        return result as String
    }
}

/// `百分之X → X%` (X may already be Arabic after DecimalRule).
internal enum PercentRule {
    static func apply(_ text: String) -> String {
        // Match 百分之 followed by either Arabic number or Chinese int
        // Run two passes: first on Arabic (post-Decimal), then on Chinese.
        var work = text

        // Pass 1: 百分之 + Arabic
        let arabicPattern = "百分之([0-9]+(?:\\.[0-9]+)?)"
        if let re = try? NSRegularExpression(pattern: arabicPattern) {
            let ns = work as NSString
            let matches = re.matches(in: work, range: NSRange(location: 0, length: ns.length))
            var mutable = ns
            for m in matches.reversed() {
                let num = ns.substring(with: m.range(at: 1))
                mutable = mutable.replacingCharacters(in: m.range, with: "\(num)%") as NSString
            }
            work = mutable as String
        }

        // Pass 2: 百分之 + Chinese int
        let zhPattern = "百分之([零一二三四五六七八九兩十百千]+)"
        if let re = try? NSRegularExpression(pattern: zhPattern) {
            let ns = work as NSString
            let matches = re.matches(in: work, range: NSRange(location: 0, length: ns.length))
            var mutable = ns
            for m in matches.reversed() {
                let zh = ns.substring(with: m.range(at: 1))
                guard let val = ChineseIntParser.parse(Substring(zh)) else { continue }
                mutable = mutable.replacingCharacters(in: m.range, with: "\(val)%") as NSString
            }
            work = mutable as String
        }

        return work
    }
}

/// Handles 萬 / 億 / 億+萬 compound forms.
///   一百二十萬 → 120萬
///   兩千三百萬 → 2300萬
///   一億兩千萬 → 1億2000萬
internal enum MagnitudeRule {
    static func apply(_ text: String) -> String {
        // Pass A: 億+萬 compound — run first so 兩千 inside 一億兩千萬 is attributed to 億 block
        var work = applyYiWanCompound(text)
        // Pass B: standalone 萬
        work = applySingleUnit(work, unit: "萬")
        // Pass C: standalone 億
        work = applySingleUnit(work, unit: "億")
        return work
    }

    private static let intClass = "[零一二三四五六七八九兩十百千]+"

    private static func applyYiWanCompound(_ text: String) -> String {
        let pattern = "(\(intClass))億(\(intClass))萬"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var mutable = ns
        for m in matches.reversed() {
            let lead = ns.substring(with: m.range(at: 1))
            let mid = ns.substring(with: m.range(at: 2))
            guard let leadVal = ChineseIntParser.parse(Substring(lead)),
                  let midVal = ChineseIntParser.parse(Substring(mid))
            else { continue }
            let replacement = "\(leadVal)億\(midVal)萬"
            mutable = mutable.replacingCharacters(in: m.range, with: replacement) as NSString
        }
        return mutable as String
    }

    private static func applySingleUnit(_ text: String, unit: Character) -> String {
        let pattern = "(\(intClass))\(unit)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var mutable = ns
        for m in matches.reversed() {
            let zh = ns.substring(with: m.range(at: 1))
            guard let val = ChineseIntParser.parse(Substring(zh)) else { continue }
            let replacement = "\(val)\(unit)"
            mutable = mutable.replacingCharacters(in: m.range, with: replacement) as NSString
        }
        return mutable as String
    }
}

/// Two-or-more Chinese digits followed by year/room-number marker, converted digit-by-digit.
/// 二零二五年 → 2025年
internal enum YearRule {
    static func apply(_ text: String) -> String {
        let digitClass = "[零一二三四五六七八九]{2,}"
        let markers = ["年", "號", "室", "棟", "班"]
        var work = text
        for marker in markers {
            let pattern = "(\(digitClass))\(marker)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = work as NSString
            let matches = re.matches(in: work, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }
            var mutable = ns
            for m in matches.reversed() {
                let digits = ns.substring(with: m.range(at: 1))
                guard let arabic = ChineseIntParser.parseDigitSequence(Substring(digits)) else { continue }
                mutable = mutable.replacingCharacters(in: m.range, with: "\(arabic)\(marker)") as NSString
            }
            work = mutable as String
        }
        return work
    }
}

/// `X到Y` where both X and Y are Chinese ints. Converts both sides.
/// 三十到五十 → 30到50  (keeps 到 rather than ~, for Taiwan readability)
internal enum RangeRule {
    static func apply(_ text: String) -> String {
        let intClass = "[零一二三四五六七八九兩十百千]+"
        // Month range (requires 月 context)
        let monthPattern = "(\(intClass))月到(\(intClass))月"
        var work = applyPattern(text, pattern: monthPattern, sep: "月到", trailing: "月")
        // General range (no unit) — must be fully Chinese ints on both sides
        let generalPattern = "(\(intClass))到(\(intClass))"
        work = applyPattern(work, pattern: generalPattern, sep: "到", trailing: "")
        return work
    }

    private static func applyPattern(_ text: String, pattern: String, sep: String, trailing: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var mutable = ns
        for m in matches.reversed() {
            let a = ns.substring(with: m.range(at: 1))
            let b = ns.substring(with: m.range(at: 2))
            guard let aVal = ChineseIntParser.parse(Substring(a)),
                  let bVal = ChineseIntParser.parse(Substring(b))
            else { continue }
            let replacement = "\(aVal)\(sep)\(bVal)\(trailing)"
            mutable = mutable.replacingCharacters(in: m.range, with: replacement) as NSString
        }
        return mutable as String
    }
}

/// Small-to-medium Chinese int followed by a counter / measure word.
internal enum CounterRule {
    static let counters: [String] = [
        // Generic counters
        "個", "本", "位", "名", "只", "條", "張", "顆", "杯", "碗", "瓶",
        "袋", "盒", "箱", "件", "台", "輛", "艘", "架", "頭", "匹", "隻",
        "份", "輪", "雙", "對", "圈", "回",
        // Time / age units
        "歲", "年", "月", "日", "週", "小時", "分鐘", "秒",
        // Physical units (Chinese long form — rewritten to kg/km/m in UnitRewriteRule)
        "公斤", "公里", "公尺", "公分", "公噸",
        // Currency
        "元", "塊",
        // Degrees / angles
        "度",
    ]

    static func apply(_ text: String) -> String {
        let intClass = "[零一二三四五六七八九兩十百千]+"
        var work = text
        // Sort longer counters first so 公里 is matched before 公
        let sorted = counters.sorted { $0.count > $1.count }
        for counter in sorted {
            let escaped = NSRegularExpression.escapedPattern(for: counter)
            let pattern = "(\(intClass))\(escaped)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = work as NSString
            let matches = re.matches(in: work, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }
            var mutable = ns
            for m in matches.reversed() {
                let zh = ns.substring(with: m.range(at: 1))
                guard let val = ChineseIntParser.parse(Substring(zh)) else { continue }
                mutable = mutable.replacingCharacters(in: m.range, with: "\(val)\(counter)") as NSString
            }
            work = mutable as String
        }
        return work
    }
}

/// Post-process Chinese long-form units to short-form: 公里→km, 公斤→kg, 度→°.
/// Only fires on `\d+` prefix (i.e., after CounterRule has done its work).
internal enum UnitRewriteRule {
    static let rewrites: [(String, String)] = [
        ("公里", "km"),
        ("公尺", "m"),
        ("公分", "cm"),
        ("公斤", "kg"),
        ("公噸", "t"),
        ("度", "°"),
    ]

    static func apply(_ text: String) -> String {
        var work = text
        for (long, short) in rewrites {
            let pattern = "([0-9]+)\(long)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = work as NSString
            let matches = re.matches(in: work, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }
            var mutable = ns
            for m in matches.reversed() {
                let num = ns.substring(with: m.range(at: 1))
                mutable = mutable.replacingCharacters(in: m.range, with: "\(num)\(short)") as NSString
            }
            work = mutable as String
        }
        return work
    }
}

// MARK: - Post-reject guards

internal enum OutputGuard {

    static let currencySymbols: Set<Character> = ["¥", "$", "€", "£", "₩"]

    static let allowedNewSymbols: Set<Character> = [".", "%", "~", "°"]
    static let allowedNewLetters: Set<Character> = [
        "k", "g", "m", "c", "l", "t",
        "K", "G", "M", "C", "L", "T",
        "h",
    ]

    static let zhSmallNum: Set<Character> = [
        "一", "二", "三", "四", "五", "六", "七", "八", "九",
        "兩", "零", "〇",
    ]
    static let zhMagnitudeSmall: Set<Character> = ["十", "百", "千"]
    static let zhMagnitudeBig: Set<Character> = ["萬", "億", "兆"]

    /// Detects the pattern that a Chinese positional multiplier sits next to
    /// an Arabic digit, which is the classic "half-converted" failure mode.
    static func hasPartialConversion(_ output: String) -> Bool {
        let arabic: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        let chars = Array(output)
        for i in 0..<chars.count - 1 {
            let a = chars[i]
            let b = chars[i + 1]
            // 千300 / 百50 — small magnitude directly before Arabic
            if zhMagnitudeSmall.contains(a) && arabic.contains(b) { return true }
            // 3三 / 5五 — Arabic directly before Chinese small digit
            if arabic.contains(a) && zhSmallNum.contains(b) { return true }
        }
        return false
    }

    static func hasCurrencySymbol(_ output: String) -> Bool {
        for ch in output where currencySymbols.contains(ch) { return true }
        return false
    }

    /// Rewrite `¥123` → `123元` for Taiwan readability.
    static func rewriteCurrency(_ output: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "¥([0-9]+(?:\\.[0-9]+)?)") else {
            return output
        }
        let ns = output as NSString
        let matches = re.matches(in: output, range: NSRange(location: 0, length: ns.length))
        var mutable = ns
        for m in matches.reversed() {
            let num = ns.substring(with: m.range(at: 1))
            mutable = mutable.replacingCharacters(in: m.range, with: "\(num)元") as NSString
        }
        return mutable as String
    }

    /// Verify the output does not silently alter non-numeric content.
    /// Allows a whitelist of new symbols and letters introduced by ITN.
    static func nonNumericDrift(original: String, output: String) -> Bool {
        func skeleton(_ s: String) -> Set<Character> {
            let drop: Set<Character> = {
                var set: Set<Character> = [" ", "\t"]
                set.formUnion("0123456789")
                set.formUnion(zhSmallNum)
                set.formUnion(zhMagnitudeSmall)
                set.formUnion(zhMagnitudeBig)
                return set
            }()
            return Set(s.filter { !drop.contains($0) })
        }

        let inSet = skeleton(original)
        let outSet = skeleton(output)

        // Any char in output skeleton must be in input skeleton OR whitelisted
        for ch in outSet {
            if inSet.contains(ch) { continue }
            if allowedNewSymbols.contains(ch) { continue }
            if ch.isLetter && allowedNewLetters.contains(ch) { continue }
            return true
        }
        return false
    }

    static func lengthRatioExtreme(original: String, output: String) -> Bool {
        if original.isEmpty { return false }
        let ratio = Double(output.count) / Double(original.count)
        return ratio < 0.4 || ratio > 2.0
    }
}
