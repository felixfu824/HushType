import XCTest
@testable import HushType

/// Spec §12.10 golden regression for the dictation post-processor chain
/// (OpenCC → ITN → dictionary → punctuation). Pins CURRENT text-level
/// behavior so the cloud engines that reuse the chain don't drift.
///
/// Note: the chain runs the real OpenCC binary and the real user dictionary
/// file; these tests therefore pick inputs known to be dictionary-clean and
/// use Traditional (conversion-stable) inputs where the OpenCC step must be
/// a no-op.
final class DictationPostProcessorTests: XCTestCase {

    private var savedNumberConversionEnabled: Bool = true
    private var savedPunctuationMode: PunctuationMode = .soft

    override func setUp() {
        super.setUp()
        DictionaryReplacer.setDictionaryFileURLForTesting(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("lamitype-dictation-tests-no-dictionary.txt")
        )
        savedNumberConversionEnabled = AppConfig.shared.numberConversionEnabled
        savedPunctuationMode = AppConfig.shared.punctuationMode
        AppConfig.shared.numberConversionEnabled = true
        AppConfig.shared.punctuationMode = .soft // default mode
    }

    override func tearDown() {
        DictionaryReplacer.setDictionaryFileURLForTesting(nil)
        AppConfig.shared.numberConversionEnabled = savedNumberConversionEnabled
        AppConfig.shared.punctuationMode = savedPunctuationMode
        super.tearDown()
    }

    private func assertGolden(_ input: String, _ expected: String) {
        let output = DictationPostProcessor.apply(input)
        XCTAssertEqual(output, expected, "Golden mismatch for input: \(input)")
    }

    // MARK: - Golden ITN (cribbed verbatim from scripts/test_number_normalizer.swift)

    func testItnThreeApples() {
        assertGolden("三個蘋果", "3個蘋果")
    }

    func testItnBoughtFiveBooks() {
        assertGolden("我買了五本書", "我買了5本書")
    }

    func testItnAboutTenPeople() {
        assertGolden("大概十個人", "大概10個人")
    }

    func testItnTwentyFiveDegrees() {
        assertGolden("二十五度", "25°")
    }

    func testItnTwoThousandThirtyMillion() {
        assertGolden("兩千三百萬", "2300萬")
    }

    func testItnYearDigits() {
        assertGolden("二零二五年", "2025年")
    }

    func testItnThirtyPercent() {
        assertGolden("百分之三十", "30%")
    }

    func testItnPi() {
        assertGolden("三點一四", "3.14")
    }

    func testItnIdiomMustNotTouch() {
        assertGolden("等我一下", "等我一下")
    }

    func testItnIdiomMustNotTouchTwo() {
        assertGolden("三三兩兩的人", "三三兩兩的人")
    }

    // MARK: - Simplified → Traditional (OpenCC s2twp)

    func testS2twpWeZaiTaiwanKaihui() {
        assertGolden("我们在台湾开会", "我們在臺灣開會")
    }

    func testS2twpShujuXuexi() {
        assertGolden("数据学习", "資料學習")
    }

    func testS2twpAlreadyTraditional() {
        // Conversion-stable input passes through unchanged.
        assertGolden("我們", "我們")
    }

    // MARK: - English passthrough (script gate skips zh-only stages)

    func testEnglishPassthrough() {
        assertGolden("Hello world, this is a test.", "Hello world, this is a test.")
    }

    // MARK: - Mixed zh + EN with a number, full-chain output

    func testMixedZhEnNumber() {
        assertGolden("這個 deal 大概五百萬美金", "這個 deal 大概500萬美金")
    }

    func testMixedZhEnWithSimplified() {
        assertGolden("这个 deal 大概三百萬美金", "這個 deal 大概300萬美金")
    }

    // MARK: - Edge

    func testEmptyString() {
        assertGolden("", "")
    }
}
