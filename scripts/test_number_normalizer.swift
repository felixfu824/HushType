// Regression harness for NumberNormalizer.swift.
//
// Self-contained standalone script — runs outside the main HushType build so
// we can iterate without linking the whole app. The NumberNormalizer source
// is included inline via #sourceLocation so the file under test stays the
// single source of truth.
//
// Run: swift scripts/test_number_normalizer.swift
//
// Corpus mirrors /tmp/claude-501/itn_experiment/cases2.py (57 cases). Scoring
// rules match the Python runner so results are directly comparable.

import Foundation
import os

// MARK: - Inline copy of NumberNormalizer (keep in sync with Sources/HushType/NumberNormalizer.swift)
// Swift scripts can't `import HushType`, so we embed the module body here.
//
// BEGIN NUMBER_NORMALIZER ----------------------------------------

private let log = Logger(subsystem: "com.felix.hushtype", category: "itn")

enum NumberNormalizer {

    struct Result {
        let text: String
        let applied: Bool
        let note: String
    }

    static func normalize(_ input: String) -> Result {
        if IdiomGuard.contains(input) {
            return Result(text: input, applied: false, note: "skip (idiom)")
        }
        if SelfCorrectionGuard.contains(input) {
            return Result(text: input, applied: false, note: "skip (self-correction)")
        }
        if DegreeAmbiguityGuard.contains(input) {
            return Result(text: input, applied: false, note: "skip (度-ambiguity)")
        }

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

enum ChineseIntParser {
    static let digitMap: [Character: Int] = [
        "零": 0, "〇": 0,
        "一": 1, "二": 2, "兩": 2,
        "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    static let unitMap: [Character: Int] = [
        "十": 10, "百": 100, "千": 1000,
    ]

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
                if !sawDigit { current = 1 }
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

    static func parseDigitSequence(_ s: Substring) -> String? {
        var out = ""
        for ch in s {
            guard let d = digitMap[ch] else { return nil }
            out.append(Character("\(d)"))
        }
        return out
    }
}

enum IdiomGuard {
    static let blacklist: [String] = [
        "一下", "一些", "一點", "一般", "一樣", "一定", "一直", "一起",
        "一邊", "一共", "一旦", "一向", "一概", "一律", "一會", "一輩子",
        "一心一意", "一五一十", "一心", "一意",
        "一個人", "一家人",
        "三三兩兩", "兩三", "一兩", "兩兩", "三兩",
        "九牛二虎", "九死一生",
        "三國", "三皇", "三星", "三明治",
        "萬一", "千萬要", "千萬別", "萬萬", "千千",
        "第一", "第二", "第三", "第四", "第五",
        "第六", "第七", "第八", "第九", "第十",
        "九成九", "八九不離十",
        "不二", "獨一無二",
    ]
    static func contains(_ text: String) -> Bool {
        for idiom in blacklist { if text.contains(idiom) { return true } }
        return false
    }
}

enum SelfCorrectionGuard {
    static let markers: [String] = ["不對", "錯了", "我是說", "不是說"]
    static func contains(_ text: String) -> Bool {
        for m in markers { if text.contains(m) { return true } }
        return false
    }
}

enum DegreeAmbiguityGuard {
    static let markers: [String] = [
        "再度", "又一度", "又二度", "又三度", "又四度", "又五度",
    ]
    static func contains(_ text: String) -> Bool {
        for m in markers { if text.contains(m) { return true } }
        if matchesDegreeBeiPattern(text) { return true }
        if matchesOrdinalDegreePattern(text) { return true }
        return false
    }
    private static func matchesDegreeBeiPattern(_ text: String) -> Bool {
        let chars = Array(text)
        let nums: Set<Character> = ["一", "二", "兩", "三", "四", "五",
                                    "六", "七", "八", "九", "十"]
        if chars.count < 3 { return false }
        for i in 0..<chars.count - 2 {
            if nums.contains(chars[i]) && chars[i + 1] == "度" && chars[i + 2] == "被" {
                return true
            }
        }
        return false
    }
    private static func matchesOrdinalDegreePattern(_ text: String) -> Bool {
        let chars = Array(text)
        let nums: Set<Character> = ["一", "二", "兩", "三", "四", "五",
                                    "六", "七", "八", "九", "十", "0", "1",
                                    "2", "3", "4", "5", "6", "7", "8", "9"]
        var i = 0
        while i < chars.count {
            if chars[i] == "第" && i + 2 < chars.count {
                var j = i + 1
                while j < chars.count && nums.contains(chars[j]) { j += 1 }
                if j > i + 1 && j < chars.count && chars[j] == "度" { return true }
            }
            i += 1
        }
        return false
    }
}

enum DecimalRule {
    static func apply(_ text: String) -> String {
        let intClass = "[零一二三四五六七八九兩十百千]+"
        let digitClass = "[零一二三四五六七八九]+"
        let pattern = "(\(intClass))點(\(digitClass))(?![半分整])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var result = ns
        for m in matches.reversed() {
            let intSub = ns.substring(with: m.range(at: 1))
            let fracSub = ns.substring(with: m.range(at: 2))
            guard let intVal = ChineseIntParser.parse(Substring(intSub)),
                  let fracDigits = ChineseIntParser.parseDigitSequence(Substring(fracSub))
            else { continue }
            result = result.replacingCharacters(in: m.range, with: "\(intVal).\(fracDigits)") as NSString
        }
        return result as String
    }
}

enum PercentRule {
    static func apply(_ text: String) -> String {
        var work = text

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

enum MagnitudeRule {
    static let intClass = "[零一二三四五六七八九兩十百千]+"

    static func apply(_ text: String) -> String {
        var work = applyYiWanCompound(text)
        work = applySingleUnit(work, unit: "萬")
        work = applySingleUnit(work, unit: "億")
        return work
    }

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
            mutable = mutable.replacingCharacters(in: m.range, with: "\(leadVal)億\(midVal)萬") as NSString
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
            mutable = mutable.replacingCharacters(in: m.range, with: "\(val)\(unit)") as NSString
        }
        return mutable as String
    }
}

enum YearRule {
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

enum RangeRule {
    static func apply(_ text: String) -> String {
        let intClass = "[零一二三四五六七八九兩十百千]+"
        let monthPattern = "(\(intClass))月到(\(intClass))月"
        var work = applyPattern(text, pattern: monthPattern, sep: "月到", trailing: "月")
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
            mutable = mutable.replacingCharacters(in: m.range, with: "\(aVal)\(sep)\(bVal)\(trailing)") as NSString
        }
        return mutable as String
    }
}

enum CounterRule {
    static let counters: [String] = [
        "個", "本", "位", "名", "只", "條", "張", "顆", "杯", "碗", "瓶",
        "袋", "盒", "箱", "件", "台", "輛", "艘", "架", "頭", "匹", "隻",
        "份", "輪", "雙", "對", "圈", "回",
        "歲", "年", "月", "日", "週", "小時", "分鐘", "秒",
        "公斤", "公里", "公尺", "公分", "公噸",
        "元", "塊",
        "度",
    ]
    static func apply(_ text: String) -> String {
        let intClass = "[零一二三四五六七八九兩十百千]+"
        var work = text
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

enum UnitRewriteRule {
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

enum OutputGuard {
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

    static func hasPartialConversion(_ output: String) -> Bool {
        let arabic: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        let chars = Array(output)
        if chars.count < 2 { return false }
        for i in 0..<chars.count - 1 {
            let a = chars[i]
            let b = chars[i + 1]
            if zhMagnitudeSmall.contains(a) && arabic.contains(b) { return true }
            if arabic.contains(a) && zhSmallNum.contains(b) { return true }
        }
        return false
    }
    static func hasCurrencySymbol(_ output: String) -> Bool {
        for ch in output where currencySymbols.contains(ch) { return true }
        return false
    }
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

// END NUMBER_NORMALIZER ------------------------------------------

// MARK: - Test corpus (mirrors /tmp/claude-501/itn_experiment/cases2.py)

enum Rule {
    case keep                         // must equal input
    case allowMiss                    // unchanged acceptable, CORRUPT forbidden
    case oneOf([String])              // PASS on any of these outputs
}

struct Case {
    let category: String
    let input: String
    let rule: Rule
}

let cases: [Case] = [
    // A — safe counts / measurements
    Case(category: "A", input: "三個蘋果",            rule: .oneOf(["3個蘋果"])),
    Case(category: "A", input: "我買了五本書",        rule: .oneOf(["我買了5本書"])),
    Case(category: "A", input: "大概十個人",          rule: .oneOf(["大概10個人"])),
    Case(category: "A", input: "二十五度",            rule: .oneOf(["25°", "25度"])),
    Case(category: "A", input: "今天三十二度",        rule: .oneOf(["今天32°", "今天32度"])),
    Case(category: "A", input: "三十公斤",            rule: .oneOf(["30kg", "30公斤"])),
    Case(category: "A", input: "三十歲",              rule: .oneOf(["30歲"])),
    Case(category: "A", input: "二零二五年",          rule: .oneOf(["2025年"])),
    Case(category: "A", input: "時速六十公里",        rule: .oneOf(["時速60km", "時速60公里"])),
    Case(category: "A", input: "五公尺",              rule: .oneOf(["5m", "5公尺"])),

    // B — business numbers
    Case(category: "B", input: "一百二十萬",          rule: .oneOf(["120萬"])),
    Case(category: "B", input: "五百萬美金",          rule: .oneOf(["500萬美金"])),
    Case(category: "B", input: "三千五百元",          rule: .oneOf(["3500元", "NT$3500"])),
    Case(category: "B", input: "預算一百二十萬到一百五十萬", rule: .oneOf(["預算120萬到150萬", "預算120萬~150萬"])),
    Case(category: "B", input: "大概五百萬左右",      rule: .oneOf(["大概500萬左右"])),
    Case(category: "B", input: "這案子大概五百萬美金", rule: .oneOf(["這案子大概500萬美金"])),
    Case(category: "B", input: "五千塊",              rule: .allowMiss),
    Case(category: "B", input: "一千元台幣",          rule: .oneOf(["1000元台幣", "NT$1000"])),

    // C — tricky magnitudes
    Case(category: "C", input: "兩千三百萬",          rule: .oneOf(["2300萬", "23000000"])),
    Case(category: "C", input: "應該是兩千三百萬",    rule: .oneOf(["應該是2300萬", "應該是23000000"])),
    Case(category: "C", input: "兩千萬",              rule: .oneOf(["2000萬", "20000000"])),
    Case(category: "C", input: "一億兩千萬",          rule: .oneOf(["1億2000萬", "12000萬", "120000000"])),
    Case(category: "C", input: "三千五百萬",          rule: .oneOf(["3500萬", "35000000"])),

    // D — idioms / must-not-touch
    Case(category: "D", input: "大概有個一兩百萬吧",  rule: .keep),
    Case(category: "D", input: "三三兩兩的人",        rule: .keep),
    Case(category: "D", input: "一心一意",            rule: .keep),
    Case(category: "D", input: "九牛二虎之力",        rule: .keep),
    Case(category: "D", input: "一般來說",            rule: .keep),
    Case(category: "D", input: "三國演義",            rule: .keep),
    Case(category: "D", input: "九成九",              rule: .keep),
    Case(category: "D", input: "萬一出事",            rule: .keep),
    Case(category: "D", input: "千萬要小心",          rule: .keep),
    Case(category: "D", input: "他五度被提名",        rule: .keep),
    Case(category: "D", input: "再度出發",            rule: .keep),
    Case(category: "D", input: "第三度空間",          rule: .keep),
    Case(category: "D", input: "又一度失敗",          rule: .keep),

    // E — self-correction
    Case(category: "E", input: "應該是五百萬不對六百萬", rule: .allowMiss),
    Case(category: "E", input: "預算一百萬不對一百二十萬", rule: .allowMiss),

    // F — mixed-language
    Case(category: "F", input: "這個 deal 大概五百萬美金", rule: .oneOf(["這個 deal 大概500萬美金"])),
    Case(category: "F", input: "應該差不多 five million",  rule: .allowMiss),
    Case(category: "F", input: "我有 3 個 idea",           rule: .keep),
    Case(category: "F", input: "KPI 是一百萬",             rule: .oneOf(["KPI 是100萬"])),

    // G — pure text
    Case(category: "G", input: "你好嗎",              rule: .keep),
    Case(category: "G", input: "今天天氣不錯",        rule: .keep),
    Case(category: "G", input: "幫我打開設定",        rule: .keep),

    // H — small-number idiomatic
    Case(category: "H", input: "等我一下",            rule: .keep),
    Case(category: "H", input: "有一些問題",          rule: .keep),
    Case(category: "H", input: "一點點而已",          rule: .keep),
    Case(category: "H", input: "我一個人",            rule: .allowMiss),
    Case(category: "H", input: "第一個",              rule: .keep),

    // I — decimals / percents / ranges
    Case(category: "I", input: "百分之三十",          rule: .oneOf(["30%", "百分之30"])),
    Case(category: "I", input: "百分之五點五",        rule: .oneOf(["5.5%", "百分之5.5"])),
    Case(category: "I", input: "三點一四",            rule: .oneOf(["3.14"])),
    Case(category: "I", input: "三十到五十個人",      rule: .oneOf(["30到50個人", "30~50個人"])),

    // J — time expressions
    Case(category: "J", input: "晚上七點到九點",      rule: .allowMiss),
    Case(category: "J", input: "七點半",              rule: .allowMiss),
    Case(category: "J", input: "三月到五月",          rule: .allowMiss),
]

// MARK: - Scoring

enum Verdict: String {
    case pass = "PASS"
    case soft = "SOFT"
    case miss = "MISS"
    case corrupt = "CORRUPT"
}

func score(input: String, output: String, rule: Rule) -> Verdict {
    switch rule {
    case .keep:
        return output == input ? .pass : .corrupt
    case .allowMiss:
        if output == input { return .miss }
        if OutputGuard.hasPartialConversion(output) { return .corrupt }
        if OutputGuard.hasCurrencySymbol(output) { return .corrupt }
        if OutputGuard.nonNumericDrift(original: input, output: output) { return .corrupt }
        return .pass
    case .oneOf(let options):
        if options.contains(output) { return .pass }
        if output == input { return .miss }
        if OutputGuard.hasPartialConversion(output) { return .corrupt }
        if OutputGuard.hasCurrencySymbol(output) { return .corrupt }
        if OutputGuard.nonNumericDrift(original: input, output: output) { return .corrupt }
        return .soft
    }
}

// MARK: - Runner

struct Row {
    let cat: String
    let input: String
    let output: String
    let verdict: Verdict
    let note: String
}

var rows: [Row] = []
var tally: [Verdict: Int] = [.pass: 0, .soft: 0, .miss: 0, .corrupt: 0]

let start = Date()
for c in cases {
    let res = NumberNormalizer.normalize(c.input)
    let v = score(input: c.input, output: res.text, rule: c.rule)
    tally[v, default: 0] += 1
    rows.append(Row(cat: c.category, input: c.input, output: res.text, verdict: v, note: res.note))
}
let elapsed = Date().timeIntervalSince(start)

print("# NumberNormalizer regression — \(cases.count) cases")
print()
print("## Summary")
print()
print("| PASS | SOFT | MISS | CORRUPT |")
print("|---|---|---|---|")
print("| \(tally[.pass] ?? 0) | \(tally[.soft] ?? 0) | \(tally[.miss] ?? 0) | \(tally[.corrupt] ?? 0) |")
print()
print(String(format: "_Elapsed: %.3fs_", elapsed))
print()

print("## Per-case")
print()
print("| Cat | Input | Output | V | Note |")
print("|---|---|---|---|---|")
for r in rows {
    let mark: String
    switch r.verdict {
    case .pass: mark = "✓PASS"
    case .soft: mark = "~SOFT"
    case .miss: mark = "·MISS"
    case .corrupt: mark = "✗CORRUPT"
    }
    let inEsc = r.input.replacingOccurrences(of: "|", with: "\\|")
    let outEsc = r.output.replacingOccurrences(of: "|", with: "\\|")
    print("| \(r.cat) | \(inEsc) | \(outEsc) | \(mark) | \(r.note) |")
}
print()

let corrupts = rows.filter { $0.verdict == .corrupt }
if !corrupts.isEmpty {
    print("## Corruptions")
    print()
    for r in corrupts {
        print("- `\(r.input)` → `\(r.output)` (\(r.note))")
    }
    print()
}

let softs = rows.filter { $0.verdict == .soft }
if !softs.isEmpty {
    print("## Soft results (changed, but not the ideal form)")
    print()
    for r in softs {
        print("- `\(r.input)` → `\(r.output)`")
    }
    print()
}

// Exit nonzero if any CORRUPT — hard regression gate
if (tally[.corrupt] ?? 0) > 0 {
    FileHandle.standardError.write("FAIL: \(tally[.corrupt] ?? 0) CORRUPT case(s)\n".data(using: .utf8)!)
    exit(1)
}
exit(0)
