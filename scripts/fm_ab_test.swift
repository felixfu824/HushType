// Iteration 2: Path B tuned with composite examples + new grading rules.
//
// Grading changes from iter 1:
//   - Space-insensitive comparison: 買了3本書 == 買了 3 本書
//   - FoundationModels safety filter errors → treated as "return original text",
//     classified as MISS (acceptable fallback), NOT CORRUPT
//   - CORRUPT count is the only hard failure. MISS is acceptable (user just sees
//     their original transcription, which is no worse than status quo)
//
// Path A is kept for reference but is clearly dead (41% vs Path B's 70% in iter 1).
//
// Both prompts are tested against 27 cases spanning:
//   - ITN (Chinese numerals → Arabic digits)
//   - Particle / fixed-phrase preservation
//   - Filler removal + repetition collapse
//   - Must-not-touch baselines (no filler, contradictions, emphasis)
//   - Self-correction resolution (NEW — Tier 2 feature)
//   - Self-correction trap cases (rhetorical buts that must NOT be "resolved")
//
// Run: swift scripts/fm_ab_test.swift

import Foundation
import FoundationModels

// MARK: - Path C prompt (hybrid: English rules 1+2, Chinese rule 3)
//
// Hypothesis: FoundationModels is primarily English-trained, so rules expressed
// in English have stronger effect on English input than Chinese rules do. By
// writing universal rules (filler, SC) in English and the Chinese-specific rule
// (ITN) in Chinese, we hope to fix English corruption cases without regressing
// the Chinese adversarial set.

let PROMPT_C = """
You are a voice-to-text post-processor. Your job is mechanical cleanup, not rewriting.

ABSOLUTELY FORBIDDEN: rewriting, omitting content, rephrasing the user's words, correcting contradictions (even if the sentences sound contradictory, that's what the user said — preserve it), changing word order, adding or removing punctuation, translating between languages.

Rule 1 — Remove sentence-leading filler words and collapse immediate duplicates.
Delete filler words ONLY at the very start of a sentence. Leave fillers in the middle or at the end alone — they may carry meaning.
Leading fillers to remove: "um", "uh", "hmm", "er", "ah", "like", "you know", 嗯, 啊, 呃, 欸, 那個, 就是.
Collapse immediate word-level duplicates: "I I I think" → "I think", "我我我覺得" → "我覺得", "then then" → "then", "然後然後" → "然後".
DO NOT collapse emphatic repetitions: "yes yes yes", "no no no", 對對對, 好好好 are intentional emphasis — keep them intact.

Rule 2 — Resolve explicit speaker self-corrections.
Trigger ONLY on these exact correction markers: "no actually", "no wait", "I mean", "I meant", "scratch that", "correction", 不對, 我是說, 應該是, 更正.
When a marker appears, identify the sentence stem (context that applies to both the wrong and corrected value), then output: stem + corrected value. Discard the incorrect value AND the marker itself.
Example: "I'll send it Wednesday no actually Friday" → stem is "I'll send it", wrong is "Wednesday", correct is "Friday", output is "I'll send it Friday".
Example: 我想約禮拜三不對禮拜五 → stem is 我想約, wrong is 禮拜三, correct is 禮拜五, output is 我想約禮拜五.
If there is no stem (just "X marker Y"), output only Y. Example: "Wednesday no actually Friday" → "Friday".
If NO marker appears, NEVER modify the content, even if sentences sound contradictory. Transitions and softeners are NOT correction markers — keep both sides: "but", "however", "though", 但是, 不過, 可是.

規則 3 — 中文數字轉阿拉伯數字（此規則僅適用於中文內容）。
只在表達數量、編號、度量、百分比、日期、時間、小數的時候才轉換。
- 量詞前面要轉：「五個蘋果」→「5 個蘋果」、「三本書」→「3 本書」、「二十五度」→「25 度」、「一百公里」→「100 公里」
- 編號要轉：「一零一大樓」→「101 大樓」
- 小數的「點」轉「.」:「三點一四」→「3.14」
- 百分比：「百分之三十二」→「32%」
- 年份日期：「兩千零二十六年三月五日」→「2026 年 3 月 5 日」

「一」當助詞或固定詞時絕對不要轉：想一下、看一看、等一等、試一試、第一、一直、一起、一定、一樣、一些、一會兒、一輩子。

英文數字（five, three, twenty, 等等）不要轉換，它們不是這個規則的對象。

Output only the corrected sentence. No prefix, no quotes, no explanation.

Examples:

輸入：我住在一零一大樓
輸出：我住在 101 大樓

輸入：想一下喔
輸出：想一下喔

輸入：嗯那個我覺得這個方案不錯
輸出：我覺得這個方案不錯

輸入：我想約禮拜三不對禮拜五
輸出：我想約禮拜五

輸入：我們有三個選項我是說四個選項
輸出：我們有 4 個選項

輸入：總共花了兩萬不對是三萬
輸出：總共花了 30000

輸入：我昨天去了公司不對是圖書館
輸出：我昨天去了圖書館

輸入：嗯那個我跑了五公里
輸出：我跑了 5 公里

輸入：我覺得這個方案很好但是我覺得它不會成功
輸出：我覺得這個方案很好但是我覺得它不會成功

輸入：um I think we should meet at three
輸出：I think we should meet at three

輸入：I'll send it Monday no actually Tuesday
輸出：I'll send it Tuesday

輸入：I have five books on my desk
輸出：I have five books on my desk
"""

// MARK: - Path B prompt (current + Rule 3 appended)

let PROMPT_B = """
你是一個語音轉文字的後處理器。你的任務是做下面三種**機械性**的修正。

**絕對禁止：不要改寫、不要省略內容、不要重新表達使用者的話、不要修正前後矛盾的句子（即使聽起來矛盾，那是使用者本來的話，要原封保留）、不要改變詞序、不要加標點。**

規則 1 — 中文數字轉阿拉伯數字。
**只在表達數量、編號、度量、百分比、日期、時間、小數的時候才轉換。**
- 量詞前面要轉:「五個蘋果」→「5 個蘋果」、「三本書」→「3 本書」、「二十五度」→「25 度」、「一百公里」→「100 公里」
- 編號要轉:「一零一大樓」→「101 大樓」
- 小數的「點」轉「.」:「三點一四」→「3.14」
- 百分比:「百分之三十二」→「32%」
- 年份日期:「兩千零二十六年三月五日」→「2026 年 3 月 5 日」

**「一」當助詞或固定詞時絕對不要轉**：想一下、看一看、等一等、試一試、第一、一直、一起、一定、一樣、一些、一會兒、一輩子。

規則 2 — 移除句首明顯的口頭禪贅字 + 收縮連續重複的字。
- **只移除句首**的這幾個詞：嗯、啊、呃、欸、那個、就是。例如「嗯我覺得」→「我覺得」、「那個我想問」→「我想問」。
- **不要動句子中間或結尾的這些字**——它們可能是有意義的內容。例如「我覺得這個那個其實還行」要保留「那個」不變。
- **連續重複的代名詞或語氣詞要收縮**:「我我我覺得」→「我覺得」、「然後然後」→「然後」。
-「對對對」、「好好好」這種重複是強調，**不要收縮**。

規則 3 — 處理明確的自我修正。
- **只在出現明確自我修正訊號時才處理**：「不對」、「我是說」、「應該是」、「更正」。
- 看到這類訊號時，只保留修正後的版本。例：「禮拜三不對禮拜五」→「禮拜五」、「三個選項我是說四個選項」→「4 個選項」（注意還要套用規則 1）。
- **沒有明確訊號就絕對不要改**。即使前後矛盾，只要沒有上面這幾個詞，保留原文。
-「不過」、「但是」、「可是」不算自我修正訊號——它們是轉折或軟化語氣，要保留兩邊。

只輸出修正後的句子，不要加前綴、不要加引號、不要解釋。繁體簡體都可以，後續會由其他工具統一處理。

範例：
輸入：我住在一零一大樓
輸出：我住在 101 大樓

輸入：想一下喔
輸出：想一下喔

輸入：嗯那個我覺得這個方案不錯
輸出：我覺得這個方案不錯

輸入：我想約禮拜三不對禮拜五
輸出：我想約禮拜五

輸入：我們有三個選項我是說四個選項
輸出：我們有 4 個選項

輸入：總共花了兩萬不對是三萬
輸出：總共花了 30000

輸入：我昨天去了公司不對是圖書館
輸出：我昨天去了圖書館

輸入：嗯那個我跑了五公里
輸出：我跑了 5 公里

輸入：我覺得這個方案很好但是我覺得它不會成功
輸出：我覺得這個方案很好但是我覺得它不會成功
"""

// MARK: - Test cases

struct TestCase {
    let input: String
    let category: String
    let label: String
    let expected: String
}

let CASES: [TestCase] = [
    // --- ITN positive (6)
    TestCase(input: "我住在一零一大樓",                  category: "ITN",    label: "building",       expected: "我住在 101 大樓"),
    TestCase(input: "今天氣溫二十五度",                   category: "ITN",    label: "measurement",    expected: "今天氣溫 25 度"),
    TestCase(input: "三點一四",                         category: "ITN",    label: "decimal",        expected: "3.14"),
    TestCase(input: "百分之四十七點五",                   category: "ITN",    label: "percent",        expected: "47.5%"),
    TestCase(input: "買了三本書",                        category: "ITN",    label: "量詞 本",         expected: "買了 3 本書"),
    TestCase(input: "跑了一百公里",                      category: "ITN",    label: "量詞 公里",       expected: "跑了 100 公里"),

    // --- Particle / fixed phrase — must NOT convert 一 (4)
    TestCase(input: "想一下喔",                         category: "PART",   label: "助詞 想一下",      expected: "想一下喔"),
    TestCase(input: "看一看再決定",                      category: "PART",   label: "助詞 看一看",      expected: "看一看再決定"),
    TestCase(input: "我一直都在",                        category: "PART",   label: "固定詞 一直",      expected: "我一直都在"),
    TestCase(input: "那邊的一些朋友",                    category: "PART",   label: "固定詞 一些",      expected: "那邊的一些朋友"),

    // --- Filler removal at sentence start (3)
    TestCase(input: "嗯我覺得這個方案不錯",                category: "FILLER", label: "strip 嗯",        expected: "我覺得這個方案不錯"),
    TestCase(input: "那個我想問你一個問題",                category: "FILLER", label: "strip 那個",      expected: "我想問你一個問題"),
    TestCase(input: "啊就是我想說的事情",                  category: "FILLER", label: "strip 啊就是",    expected: "我想說的事情"),

    // --- Repetition collapse (2)
    TestCase(input: "我我我覺得有道理",                   category: "REP",    label: "collapse 我我我", expected: "我覺得有道理"),
    TestCase(input: "然後然後我就走了",                   category: "REP",    label: "collapse 然後",   expected: "然後我就走了"),

    // --- Must NOT touch (3)
    TestCase(input: "我覺得這件事其實沒那麼簡單",           category: "KEEP",   label: "no filler",      expected: "我覺得這件事其實沒那麼簡單"),
    TestCase(input: "對對對沒錯",                        category: "KEEP",   label: "emphasis 對對對", expected: "對對對沒錯"),
    TestCase(input: "hello world",                      category: "KEEP",   label: "english",        expected: "hello world"),

    // --- Self-correction: should resolve (5) — NEW
    TestCase(input: "我想跟你約禮拜三哦不對禮拜五",         category: "SC",     label: "SC 不對",         expected: "我想跟你約禮拜五"),
    TestCase(input: "我們有三個選項我是說四個選項",         category: "SC",     label: "SC 我是說",       expected: "我們有 4 個選項"),
    TestCase(input: "時間是下午三點應該是四點",            category: "SC",     label: "SC 應該是",       expected: "時間是下午 4 點"),
    TestCase(input: "總共花了兩萬不對是三萬",              category: "SC",     label: "SC + ITN",       expected: "總共花了 30000"),
    TestCase(input: "他住在台北不對是新北",               category: "SC",     label: "SC 地點",         expected: "他住在新北"),

    // --- Self-correction traps: must NOT resolve (4) — NEW
    TestCase(input: "我覺得這個方案很好但是我覺得它不會成功", category: "TRAP",   label: "contradiction",  expected: "我覺得這個方案很好但是我覺得它不會成功"),
    TestCase(input: "A 方案比較好不過 B 方案其實也不錯",    category: "TRAP",   label: "軟化 不過",       expected: "A 方案比較好不過 B 方案其實也不錯"),
    TestCase(input: "可以選紅的也可以選藍的看你",           category: "TRAP",   label: "enumeration",    expected: "可以選紅的也可以選藍的看你"),
    TestCase(input: "他說好可是我覺得不一定",              category: "TRAP",   label: "轉折 可是",       expected: "他說好可是我覺得不一定"),

    // --- English-only (5) — filler + SC are universal, ITN is Chinese-only
    TestCase(input: "this is a simple sentence",                    category: "EN",     label: "pure EN",         expected: "this is a simple sentence"),
    TestCase(input: "I have five books on my desk",                 category: "EN",     label: "EN number keep",  expected: "I have five books on my desk"),
    TestCase(input: "uh I think we should meet at three",           category: "EN",     label: "EN filler uh",    expected: "I think we should meet at three"),
    TestCase(input: "um let me check my calendar",                  category: "EN",     label: "EN filler um",    expected: "let me check my calendar"),
    TestCase(input: "I'll send it Wednesday no actually Friday",    category: "EN",     label: "EN self-correct", expected: "I'll send it Friday"),

    // --- Chinese-English mixed (4)
    TestCase(input: "我今天有個 meeting 要開",                      category: "MIX",    label: "EN noun in ZH",   expected: "我今天有個 meeting 要開"),
    TestCase(input: "嗯那個我要三個 coffee",                        category: "MIX",    label: "ZH filler+ITN+EN", expected: "我要 3 個 coffee"),
    TestCase(input: "send me the report 謝謝",                      category: "MIX",    label: "EN head, ZH tail", expected: "send me the report 謝謝"),
    TestCase(input: "我買了 five 本書",                             category: "MIX",    label: "EN num in ZH",     expected: "我買了 five 本書"),

    // --- Japanese (2) — rules don't cover Japanese, expect pass-through
    TestCase(input: "えっと、ちょっと考えさせて",                    category: "JP",     label: "JP filler",        expected: "えっと、ちょっと考えさせて"),
    TestCase(input: "三つのリンゴ",                                 category: "JP",     label: "JP 三",            expected: "三つのリンゴ"),
]

// MARK: - Result classification

enum Verdict: String {
    case pass = "PASS"
    case miss = "MISS"
    case corrupt = "CORRUPT"
}

/// Remove ALL whitespace for comparison — spacing around digits is noise, we
/// don't consider "買了3本書" vs "買了 3 本書" different.
func normalized(_ s: String) -> String {
    s.components(separatedBy: .whitespacesAndNewlines).joined()
}

func classify(input: String, expected: String, actual: String) -> Verdict {
    let ni = normalized(input)
    let ne = normalized(expected)
    let na = normalized(actual)
    if na == ne { return .pass }
    if na == ni { return .miss }
    return .corrupt
}

func strip(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["輸出：", "输出：", "Output:", "output:"] {
        if s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
    }
    return s
}

// MARK: - Runner

@available(macOS 26.0, *)
func runOneCase(_ tc: TestCase, session: LanguageModelSession, options: GenerationOptions) async -> (String, Verdict, TimeInterval, Bool) {
    let prompt = "輸入：\(tc.input)\n輸出："
    let t = Date()
    let raw: String
    var filteredBySafety = false
    do {
        let response = try await session.respond(to: prompt, options: options)
        raw = response.content
    } catch {
        // FoundationModels safety filter (or any other generation error) →
        // production fallback would return the original input unchanged.
        // Classify as MISS, not CORRUPT.
        let msg = error.localizedDescription
        filteredBySafety = msg.contains("unsafe") || msg.contains("safety")
        let elapsed = Date().timeIntervalSince(t)
        return (tc.input, .miss, elapsed, filteredBySafety)
    }
    let elapsed = Date().timeIntervalSince(t)
    let actual = strip(raw)
    return (actual, classify(input: tc.input, expected: tc.expected, actual: actual), elapsed, filteredBySafety)
}

struct Result {
    let tc: TestCase
    let actualA: String
    let actualB: String
    let verdictA: Verdict
    let verdictB: Verdict
    let elapsedA: TimeInterval
    let elapsedB: TimeInterval
    let safetyA: Bool
    let safetyB: Bool
}

@available(macOS 26.0, *)
func run() async {
    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        print("❌ FoundationModels unavailable")
        exit(1)
    }
    print("✅ FoundationModels available")
    print("Cases: \(CASES.count)  (ITN×6, PART×4, FILLER×3, REP×2, KEEP×3, SC×5, TRAP×4)")

    let options = GenerationOptions(temperature: 0.0)
    let sessionA = LanguageModelSession(instructions: PROMPT_C)  // Path A slot now holds Path C hybrid prompt
    let sessionB = LanguageModelSession(instructions: PROMPT_B)

    var results: [Result] = []
    var totalA: TimeInterval = 0
    var totalB: TimeInterval = 0

    print("\n" + String(repeating: "=", count: 82))
    for (i, tc) in CASES.enumerated() {
        let (aActual, aVerdict, aElapsed, aSafety) = await runOneCase(tc, session: sessionA, options: options)
        let (bActual, bVerdict, bElapsed, bSafety) = await runOneCase(tc, session: sessionB, options: options)
        totalA += aElapsed
        totalB += bElapsed
        results.append(Result(tc: tc, actualA: aActual, actualB: bActual, verdictA: aVerdict, verdictB: bVerdict, elapsedA: aElapsed, elapsedB: bElapsed, safetyA: aSafety, safetyB: bSafety))

        let markA = icon(aVerdict)
        let markB = icon(bVerdict)
        let idx = String(format: "%2d", i + 1)
        print("[\(idx)] [\(tc.category.padding(toLength: 6, withPad: " ", startingAt: 0))] A:\(markA) B:\(markB)  \(tc.label)")
        print("     in : \(tc.input)")
        if aVerdict != .pass || bVerdict != .pass {
            print("     exp: \(tc.expected)")
        }
        if aVerdict != .pass || aActual != bActual {
            print("     A  : \(aActual)  [\(aVerdict.rawValue)]")
        }
        if bVerdict != .pass || aActual != bActual {
            print("     B  : \(bActual)  [\(bVerdict.rawValue)]")
        }
    }

    // Aggregate
    var countsA: [Verdict: Int] = [.pass: 0, .miss: 0, .corrupt: 0]
    var countsB: [Verdict: Int] = [.pass: 0, .miss: 0, .corrupt: 0]
    var catA: [String: (pass: Int, total: Int)] = [:]
    var catB: [String: (pass: Int, total: Int)] = [:]

    for r in results {
        countsA[r.verdictA, default: 0] += 1
        countsB[r.verdictB, default: 0] += 1
        let cat = r.tc.category
        var a = catA[cat] ?? (0, 0)
        var b = catB[cat] ?? (0, 0)
        a.total += 1
        b.total += 1
        if r.verdictA == .pass { a.pass += 1 }
        if r.verdictB == .pass { b.pass += 1 }
        catA[cat] = a
        catB[cat] = b
    }

    print("\n" + String(repeating: "=", count: 82))
    print("SUMMARY")
    print(String(repeating: "=", count: 82))
    print("")
    print("             Path C (hybrid)     Path B (all-Chinese)")
    print("             ---------------     --------------------")
    let n = CASES.count
    print("  PASS:          \(String(format: "%2d", countsA[.pass] ?? 0)) / \(n)                  \(String(format: "%2d", countsB[.pass] ?? 0)) / \(n)")
    print("  MISS:          \(String(format: "%2d", countsA[.miss] ?? 0)) / \(n)                  \(String(format: "%2d", countsB[.miss] ?? 0)) / \(n)")
    print("  CORRUPT:       \(String(format: "%2d", countsA[.corrupt] ?? 0)) / \(n)                  \(String(format: "%2d", countsB[.corrupt] ?? 0)) / \(n)")
    print("  Avg latency:  \(String(format: "%5.0fms", totalA / Double(n) * 1000))              \(String(format: "%5.0fms", totalB / Double(n) * 1000))")

    let safetyCountA = results.filter { $0.safetyA }.count
    let safetyCountB = results.filter { $0.safetyB }.count
    print("  Safety filter: \(safetyCountA) / \(n)                   \(safetyCountB) / \(n)")

    print("\n  Per-category pass rate:")
    let categoryOrder = ["ITN", "PART", "FILLER", "REP", "KEEP", "SC", "TRAP", "EN", "MIX", "JP"]
    for cat in categoryOrder {
        guard let a = catA[cat], let b = catB[cat] else { continue }
        let padded = cat.padding(toLength: 8, withPad: " ", startingAt: 0)
        print("    \(padded) A: \(a.pass)/\(a.total)    B: \(b.pass)/\(b.total)")
    }

    // Critical failures (corruption)
    let corruptA = results.filter { $0.verdictA == .corrupt }
    let corruptB = results.filter { $0.verdictB == .corrupt }
    if !corruptA.isEmpty {
        print("\n🔴 Path C corruption (\(corruptA.count)):")
        for r in corruptA {
            print("  [\(r.tc.category)] \(r.tc.label)")
            print("    in : \(r.tc.input)")
            print("    exp: \(r.tc.expected)")
            print("    out: \(r.actualA)")
        }
    }
    if !corruptB.isEmpty {
        print("\n🔴 Path B corruption (\(corruptB.count)):")
        for r in corruptB {
            print("  [\(r.tc.category)] \(r.tc.label)")
            print("    in : \(r.tc.input)")
            print("    exp: \(r.tc.expected)")
            print("    out: \(r.actualB)")
        }
    }
}

func icon(_ v: Verdict) -> String {
    switch v {
    case .pass: return "✅"
    case .miss: return "⚠️ "
    case .corrupt: return "🔴"
    }
}

if #available(macOS 26.0, *) {
    await run()
} else {
    print("❌ Requires macOS 26.0+")
    exit(1)
}
