// Smoke test: Apple FoundationModels for HushType AI cleanup.
//
// Run:  swift scripts/fm_smoke_test.swift
// Or:   swiftc -O -o /tmp/fm_smoke scripts/fm_smoke_test.swift && /tmp/fm_smoke
//
// This is a throwaway experiment — not part of the build.

import Foundation
import FoundationModels

// MARK: - Prompt (mirrored from scripts/test_cleanup_prompt.py)

let SYSTEM_PROMPT = """
你是一個語音轉文字的後處理器。你的任務是做下面兩種**機械性**的修正。

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

只輸出修正後的句子，不要加前綴、不要加引號、不要解釋。繁體簡體都可以，後續會由其他工具統一處理。

範例：
輸入：我住在一零一大樓
輸出：我住在 101 大樓

輸入：我有五個蘋果
輸出：我有 5 個蘋果

輸入：想一下喔
輸出：想一下喔

輸入：今天氣溫二十五度
輸出：今天氣溫 25 度

輸入：三點一四
輸出：3.14

輸入：百分之三十二點六八
輸出：32.68%

輸入：嗯那個我覺得這個方案不錯
輸出：我覺得這個方案不錯

輸入：我我我覺得有道理
輸出：我覺得有道理

輸入：然後然後我就走了
輸出：然後我就走了

輸入：我覺得這件事其實沒那麼簡單
輸出：我覺得這件事其實沒那麼簡單
"""

// MARK: - Test cases (subset — start small)

struct TestCase {
    let input: String
    let label: String
    let expected: String
}

let CASES: [TestCase] = [
    // ITN
    TestCase(input: "我住在一零一大樓",       label: "ITN building",     expected: "我住在 101 大樓"),
    TestCase(input: "今天氣溫二十五度",        label: "ITN measurement",  expected: "今天氣溫 25 度"),
    TestCase(input: "三點一四",              label: "ITN decimal",      expected: "3.14"),
    TestCase(input: "買了三本書",             label: "ITN 量詞",         expected: "買了 3 本書"),
    // Particles — must NOT convert
    TestCase(input: "想一下喔",              label: "particle keep",    expected: "想一下喔"),
    TestCase(input: "我一直都在",             label: "fixed phrase",     expected: "我一直都在"),
    // Filler strip
    TestCase(input: "嗯我覺得這個方案不錯",     label: "strip 嗯",         expected: "我覺得這個方案不錯"),
    TestCase(input: "那個我想問你一個問題",     label: "strip 那個",       expected: "我想問你一個問題"),
    // Repetition collapse
    TestCase(input: "我我我覺得有道理",        label: "collapse 我我我",   expected: "我覺得有道理"),
    // Must NOT touch
    TestCase(input: "對對對沒錯",             label: "emphasis keep",    expected: "對對對沒錯"),
    TestCase(input: "我覺得這件事其實沒那麼簡單", label: "no filler",      expected: "我覺得這件事其實沒那麼簡單"),
    // English pass-through
    TestCase(input: "hello world",          label: "english",          expected: "hello world"),
]

// MARK: - Result classification

enum Result: String {
    case pass = "PASS"
    case miss = "MISS"
    case corrupt = "CORRUPT"
}

func classify(input: String, expected: String, actual: String) -> Result {
    if actual == expected { return .pass }
    if actual == input { return .miss }
    return .corrupt
}

// MARK: - Main

@available(macOS 26.0, *)
func run() async {
    let model = SystemLanguageModel.default

    switch model.availability {
    case .available:
        print("✅ FoundationModels available")
    case .unavailable(let reason):
        print("❌ FoundationModels unavailable: \(reason)")
        exit(1)
    @unknown default:
        print("❌ FoundationModels availability unknown")
        exit(1)
    }

    print("\n[LOADING SESSION]")
    let t0 = Date()
    let session = LanguageModelSession(instructions: SYSTEM_PROMPT)
    let loadElapsed = Date().timeIntervalSince(t0)
    print("  Session created in \(String(format: "%.2f", loadElapsed))s")

    // Deterministic generation
    let options = GenerationOptions(temperature: 0.0)

    print("\n[RUNNING \(CASES.count) CASES]")
    print(String(repeating: "-", count: 78))

    var counts: [Result: Int] = [.pass: 0, .miss: 0, .corrupt: 0]
    var failures: [(Int, TestCase, String, Result)] = []
    var totalInference: TimeInterval = 0

    for (i, tc) in CASES.enumerated() {
        let prompt = "輸入：\(tc.input)\n輸出："
        let t = Date()
        let raw: String
        do {
            let response = try await session.respond(to: prompt, options: options)
            raw = response.content
        } catch {
            print("[\(i+1)/\(CASES.count)] 💥 ERROR: \(error.localizedDescription)")
            raw = ""
        }
        let elapsed = Date().timeIntervalSince(t)
        totalInference += elapsed

        var actual = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["輸出：", "输出："] {
            if actual.hasPrefix(prefix) {
                actual = String(actual.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        let result = classify(input: tc.input, expected: tc.expected, actual: actual)
        counts[result, default: 0] += 1
        if result != .pass {
            failures.append((i + 1, tc, actual, result))
        }

        let marker: String
        switch result {
        case .pass: marker = "✅"
        case .miss: marker = "⚠️ "
        case .corrupt: marker = "🔴"
        }
        let ms = String(format: "%.0fms", elapsed * 1000)
        print("[\(i+1)/\(CASES.count)] \(marker) \(result.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(ms.padding(toLength: 7, withPad: " ", startingAt: 0))  (\(tc.label))")
        print("         in : \(tc.input)")
        if result != .pass {
            print("         exp: \(tc.expected)")
        }
        print("         out: \(actual)")
    }

    print("\n" + String(repeating: "=", count: 78))
    print("SUMMARY")
    print(String(repeating: "=", count: 78))
    print("  Pass:    \(counts[.pass] ?? 0) / \(CASES.count)")
    print("  Miss:    \(counts[.miss] ?? 0)  (benign — transformation skipped)")
    print("  Corrupt: \(counts[.corrupt] ?? 0)  (LLM modified content unexpectedly)")
    let avg = totalInference / Double(CASES.count)
    print("  Avg inference: \(String(format: "%.2f", avg))s per case")

    if (counts[.corrupt] ?? 0) > 0 {
        print("\n🔴 CORRUPTION DETECTED")
        for (i, tc, actual, _) in failures where actual != tc.input && actual != tc.expected {
            print("  [\(i)] \(tc.label)")
            print("      in : \(tc.input)")
            print("      exp: \(tc.expected)")
            print("      out: \(actual)")
        }
        exit(1)
    }

    print("\n✅ Zero corruption")
}

// Entry point
if #available(macOS 26.0, *) {
    await run()
} else {
    print("❌ Requires macOS 26.0+")
    exit(1)
}
