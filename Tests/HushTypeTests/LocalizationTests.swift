import XCTest
import Foundation
@testable import HushType

/// Gate C Slice 1 — localization infrastructure tests (SPEC §12.1).
///
/// Covers: ordered resolver mappings, persisted-preference semantics,
/// explicit en / zh-Hant-TW lookup under BOTH lookup strategies (macOS 15.4+
/// API and legacy .lproj bundle, forced via `L10n.forceLegacyLookupForTests`
/// on this newer machine), the missing-key/table fallback chain, all-table
/// key parity, recursive format signatures, `L10n.plural` (0/1/2/large in
/// both languages), forced cross-process-locale formatting, and
/// bundle-selection rules.
final class LocalizationTests: XCTestCase {
    private var defaults: UserDefaults { .standard }

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: "hushtype.interfaceLanguage")
        L10n.overrideBaseBundle = nil
        L10n.forceLegacyLookupForTests = false
        L10n.resetLaunchStateForTests()
    }

    override func tearDown() {
        defaults.removeObject(forKey: "hushtype.interfaceLanguage")
        L10n.overrideBaseBundle = nil
        L10n.forceLegacyLookupForTests = false
        L10n.resetLaunchStateForTests()
        super.tearDown()
    }

    // MARK: - Bundle selection

    func testBaseBundleIsModuleForNonAppBundle() {
        // Under swift test the main bundle is .xctest, not .app — the
        // runtime rule must select Bundle.module, which carries our tables.
        XCTAssertEqual(L10n.baseBundle(), Bundle.module)
    }

    func testEffectiveBaseBundleUsesInjection() {
        let fixture = Bundle.module
        L10n.overrideBaseBundle = fixture
        XCTAssertEqual(L10n.effectiveBaseBundle(), fixture)
    }

    // MARK: - Ordered resolver (SPEC §5.3)

    func testFollowSystemOrderedMappings() {
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["fr", "zh-TW", "en"]), "zh-Hant-TW")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["zh-CN", "en"]), "en")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["zh-CN", "zh-HK", "en"]), "zh-Hant-TW")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["zh-HK", "en"]), "zh-Hant-TW")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["zh", "en"]), "en")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["zh-Hans", "en"]), "en")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["zh-SG"]), "en")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["zh-Hant"]), "zh-Hant-TW")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["zh-Hant-TW"]), "zh-Hant-TW")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["zh-Hant-MO"]), "zh-Hant-TW")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["en-US", "fr"]), "en")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: []), "en")
    }

    func testNormalizedScriptRegionSpelling() {
        XCTAssertEqual(InterfaceLocale.supportedTag(for: "zh_Hant_TW"), "zh-Hant-TW")
        XCTAssertEqual(InterfaceLocale.supportedTag(for: "ZH-hant-tw"), "zh-Hant-TW")
        XCTAssertEqual(InterfaceLocale.supportedTag(for: "zh-tw"), "zh-Hant-TW")
        XCTAssertNil(InterfaceLocale.supportedTag(for: "zh-cn"))
    }

    func testEnglishRegionalVariantsResolveEnglish() {
        XCTAssertEqual(InterfaceLocale.supportedTag(for: "en-US"), "en")
        XCTAssertEqual(InterfaceLocale.supportedTag(for: "en-GB"), "en")
        XCTAssertEqual(InterfaceLocale.supportedTag(for: "en-AU"), "en")
        XCTAssertEqual(InterfaceLocale.supportedTag(for: "en"), "en")
        // Ordered preference: en-* beats a later Traditional-Chinese entry.
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["en-US", "zh-TW"]), "en")
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["en-GB", "zh-Hant"]), "en")
    }

    func testBCP47ExtensionsDoNotChangeResolution() {
        // Unicode extension truncated: en-US-u-oxendict -> en-us -> en.
        XCTAssertEqual(InterfaceLocale.supportedTag(for: "en-US-u-oxendict"), "en")
        // Private-use extension truncated: zh-Hant-TW-x-private -> zh-Hant-TW.
        XCTAssertEqual(InterfaceLocale.supportedTag(for: "zh-Hant-TW-x-private"), "zh-Hant-TW")
        // zh-Hans with an extension must still be unsupported (no accidental
        // Traditional match via the region/script head).
        XCTAssertNil(InterfaceLocale.supportedTag(for: "zh-Hans-u-hans"))
        XCTAssertNil(InterfaceLocale.supportedTag(for: "zh-CN-u-co-pinyin"))
        XCTAssertEqual(InterfaceLocale.effectiveTag(preferences: ["zh-CN-u-co-pinyin", "en"]), "en")
    }

    func testCorruptPreferenceResolvesToSystem() {
        defaults.set("zh-Hant", forKey: "hushtype.interfaceLanguage") // unknown raw value
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(L10n.launchPreference, .system)
    }

    func testUnknownRawPrefersSystemFallback() {
        defaults.set("garbage", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(L10n.launchPreference, .system)
    }

    func testMissingPreferenceResolvesToSystem() {
        XCTAssertEqual(L10n.launchPreference, .system)
    }

    func testForcedPreferences() {
        defaults.set("en", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(L10n.launchPreference, .english)
        XCTAssertEqual(L10n.launchTag, "en")

        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(L10n.launchPreference, .traditionalChineseTaiwan)
        XCTAssertEqual(L10n.launchTag, "zh-Hant-TW")

        defaults.set("system", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        XCTAssertEqual(L10n.launchPreference, .system)
    }

    // MARK: - Lookup under both strategies

    /// Run a block with both forced strategies (15.4+ API and legacy
    /// .lproj) so the tests exercise the macOS 15.0–15.3 path on this
    /// newer machine.
    private func underBothStrategies(_ body: (String) -> Void) {
        for strategy in ["modern", "legacy"] {
            L10n.forceLegacyLookupForTests = (strategy == "legacy")
            body(strategy)
        }
    }

    func testKnownKeyBothLanguagesBothStrategies() {
        underBothStrategies { _ in
            // English process tag
            defaults.set("en", forKey: "hushtype.interfaceLanguage")
            L10n.resetLaunchStateForTests()
            XCTAssertEqual(L10n.string("menu.about", fallback: "About HushType"), "About HushType")
            XCTAssertEqual(L10n.string("common.button.ok", fallback: "OK"), "OK")
            XCTAssertEqual(L10n.string("menu.quit", fallback: "Quit HushType"), "Quit HushType")

            // zh-Hant-TW process tag — exact frozen catalog values
            defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
            L10n.resetLaunchStateForTests()
            XCTAssertEqual(L10n.string("menu.about", fallback: "About HushType"), "關於 HushType")
            XCTAssertEqual(L10n.string("common.button.ok", fallback: "OK"), "好")
            XCTAssertEqual(L10n.string("menu.quit", fallback: "Quit HushType"), "結束 HushType")
        }
    }

    func testRequestedLocaleMissingKeyFallsBackToEnglish() {
        // zh-Hant-TW has no entry for a key that only exists in English;
        // the algorithm must fall through to en.lproj, never show the key.
        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            L10n.overrideBaseBundle = Self.fixture(withZHTW: false, withEN: true)
            let s = L10n.string("menu.about", fallback: "About HushType")
            XCTAssertEqual(s, "About HushType")
            L10n.overrideBaseBundle = nil
        }
    }

    func testMissingLocaleTableFallsBackToEnglish() {
        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            // zh-Hant-TW.lproj exists but its Localizable.strings is deleted.
            L10n.overrideBaseBundle = Self.fixture(withZHTW: true, withEN: true, deleteZHTWLocalizable: true)
            XCTAssertEqual(L10n.string("common.button.ok", fallback: "OK"), "OK")
            L10n.overrideBaseBundle = nil
        }
    }

    func testMissingRequestedLocaleDirFallsBackToEnglish() {
        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            L10n.overrideBaseBundle = Self.fixture(withZHTW: false, withEN: true)
            XCTAssertEqual(L10n.string("common.button.ok", fallback: "OK"), "OK")
            L10n.overrideBaseBundle = nil
        }
    }

    func testBothLocalesMissingReturnsHumanFallback() {
        underBothStrategies { _ in
            defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
            L10n.resetLaunchStateForTests()
            L10n.overrideBaseBundle = Self.fixture(withZHTW: false, withEN: false)
            let s = L10n.string("menu.about", fallback: "About HushType")
            XCTAssertEqual(s, "About HushType")
            XCTAssertNotEqual(s, "menu.about") // semantic key never reaches UI
            L10n.overrideBaseBundle = nil
        }
    }

    func testMalformedTableReturnsHumanFallback() {
        underBothStrategies { _ in
            defaults.set("en", forKey: "hushtype.interfaceLanguage")
            L10n.resetLaunchStateForTests()
            L10n.overrideBaseBundle = Self.fixture(withZHTW: false, withEN: true, corruptENLocalizable: true)
            let s = L10n.string("menu.about", fallback: "About HushType")
            XCTAssertEqual(s, "About HushType")
            L10n.overrideBaseBundle = nil
        }
    }

    func testMissingRequestedKeyWithEnglishPresent() {
        // Key absent from zh-Hant-TW only (present in en) — both languages
        // share the same key set, so this is proven with the fixture that
        // has a reduced zh table.
        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            L10n.overrideBaseBundle = Self.fixture(withZHTW: true, withEN: true, deleteZHTWKey: "menu.quit")
            XCTAssertEqual(L10n.string("menu.quit", fallback: "Quit HushType"), "Quit HushType")
            L10n.overrideBaseBundle = nil
        }
    }

    // MARK: - Formatting and plurals (SPEC §8, §12.1)

    func testFormatUsesEffectiveLocaleNotProcessLocale() {
        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            // Catalog: zh-Hant-TW uses "US$" — a generic process-locale
            // formatter could not be trusted to produce that.
            let s = L10n.format("format.usd_total", "$%.2f", arguments: [3.5])
            XCTAssertEqual(s, "US$3.50")
        }
        defaults.set("en", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            let s = L10n.format("format.usd_total", "$%.2f", arguments: [3.5])
            XCTAssertEqual(s, "$3.50")
        }
    }

    func testRateFormatPrecision() {
        defaults.set("en", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            XCTAssertEqual(L10n.format("format.usd_rate_per_minute", "$%.3f/min", arguments: [0.145]), "$0.145/min")
        }
        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            let zh = L10n.string("format.usd_rate_per_minute", fallback: "$%.3f/min")
            XCTAssertTrue(zh.contains("US$"), "zh rate must carry explicit US$: \(zh)")
            let s = L10n.format("format.usd_rate_per_minute", "$%.3f/min", arguments: [0.145])
            XCTAssertTrue(s.hasPrefix("US$0.145"), s)
        }
    }

    func testPluralEnglishVariants() {
        defaults.set("en", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            XCTAssertEqual(L10n.plural("menu.dictionary.entries_loaded", 0, fallback: "%d entries loaded"), "0 entries loaded")
            XCTAssertEqual(L10n.plural("menu.dictionary.entries_loaded", 1, fallback: "%d entries loaded"), "1 entry loaded")
            XCTAssertEqual(L10n.plural("menu.dictionary.entries_loaded", 2, fallback: "%d entries loaded"), "2 entries loaded")
            XCTAssertEqual(L10n.plural("menu.dictionary.entries_loaded", 42, fallback: "%d entries loaded"), "42 entries loaded")
        }
    }

    func testPluralChineseInvariant() {
        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            XCTAssertEqual(L10n.plural("menu.dictionary.entries_loaded", 0, fallback: "%d entries loaded"), "已載入 0 個項目")
            XCTAssertEqual(L10n.plural("menu.dictionary.entries_loaded", 1, fallback: "%d entries loaded"), "已載入 1 個項目")
            XCTAssertEqual(L10n.plural("menu.dictionary.entries_loaded", 2, fallback: "%d entries loaded"), "已載入 2 個項目")
            XCTAssertEqual(L10n.plural("menu.dictionary.entries_loaded", 42, fallback: "%d entries loaded"), "已載入 42 個項目")
        }
    }

    func testDailyBreakdownWithExplicitArgumentsInBothLanguages() {
        defaults.set("en", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            for count in [1, 3] {
                XCTAssertEqual(
                    L10n.plural(
                        "usage.daily_breakdown",
                        count: count,
                        fallback: "Today's cloud usage: %1$@ total; dictation %2$@ (%3$d min), translated caption %4$@ (%5$d min)",
                        arguments: ["$0.44", "$0.12", count, "$0.32", 10]
                    ),
                    "Today's cloud usage: $0.44 total; dictation $0.12 (\(count) min), translated caption $0.32 (10 min)"
                )
            }
        }

        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            XCTAssertEqual(
                L10n.plural(
                    "usage.daily_breakdown",
                    count: 3,
                    fallback: "Today's cloud usage: %1$@ total; dictation %2$@ (%3$d min), translated caption %4$@ (%5$d min)",
                    arguments: ["US$0.44", "US$0.12", 3, "US$0.32", 10]
                ),
                "今天的雲端費用：合計 US$0.44；語音輸入 US$0.12（3 分鐘），即時翻譯字幕 US$0.32（10 分鐘）"
            )
        }
    }

    func testJSONStringLiteralRoundTripsSpecialCharacters() throws {
        let original = "quote: \" slash: \\ percent: % tab:\t lines:\r\n emoji: 🐑 separators:\u{2028}\u{2029}"
        let encoded = L10n.jsonStringLiteral(original)
        let data = Data("{\"value\":\(encoded)}".utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["value"], original)
        XCTAssertTrue(encoded.contains("\\u2028"))
        XCTAssertTrue(encoded.contains("\\u2029"))
    }

    func testLocalizedLiveCaptionTemplateRemainsExecutableJSON() throws {
        for language in ["en", "zh-Hant-TW"] {
            defaults.set(language, forKey: "hushtype.interfaceLanguage")
            L10n.resetLaunchStateForTests()
            let data = Data(LiveCaptionTuning.templateContent().utf8)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

            XCTAssertEqual(object["audioSource"] as? String, "mic")
            XCTAssertEqual(object["systemAudioBundleID"] as? String, "")
            XCTAssertNil(object["resetPanelOnNextStart"])
            XCTAssertNil(object["panelDefaultWidth"])
            XCTAssertNil(object["panelDefaultHeight"])
            XCTAssertEqual(object["forceSplitSeconds"] as? Double, 10.0)
            XCTAssertNotNil(object["_comment_audioSource"] as? String)
        }
    }

    func testPluralForcedCrossProcessLocales() {
        // The spec's forced cross-process-locale case: the *effective*
        // locale (not the process locale) must drive variant selection and
        // number formatting.
        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            XCTAssertEqual(L10n.plural("menu.dictionary.entries_loaded", 1, fallback: "%d entries loaded"), "已載入 1 個項目")
        }
        defaults.set("en", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            XCTAssertEqual(L10n.plural("menu.dictionary.entries_loaded", 1, fallback: "%d entries loaded"), "1 entry loaded")
        }
    }

    func testPluralMissingKeyUsesFallback() {
        underBothStrategies { _ in
            defaults.set("en", forKey: "hushtype.interfaceLanguage")
            L10n.resetLaunchStateForTests()
            L10n.overrideBaseBundle = Self.fixture(withZHTW: false, withEN: true, deleteENStringsdict: true)
            let s = L10n.plural("menu.dictionary.entries_loaded", 3, fallback: "%d entries loaded")
            XCTAssertEqual(s, "3 entries loaded")
            L10n.overrideBaseBundle = nil
        }
    }

    func testPositionalAndEscapedPercent() {
        defaults.set("en", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            // status.loading_model_percent = "Loading model (%1$d%%)..."
            let s = L10n.format("status.loading_model_percent", "Loading model (%d%%)...", arguments: [42])
            XCTAssertEqual(s, "Loading model (42%)...")
        }
        defaults.set("zh-Hant-TW", forKey: "hushtype.interfaceLanguage")
        L10n.resetLaunchStateForTests()
        underBothStrategies { _ in
            let s = L10n.format("status.loading_model_percent", "Loading model (%d%%)...", arguments: [42])
            XCTAssertEqual(s, "正在載入模型（42%）…")
        }
    }

    // MARK: - Manifest parity (all five tables)

    func testAllTablesKeyParityAndRecursiveSignatures() {
        // Mirrors scripts/check_localizations.sh so `swift test` enforces
        // the same gate in-repo (SPEC §11: required Swift test executable).
        let module = Bundle.module
        let locales = ["en", "zh-Hant-TW"]
        let tables: [(name: String, ext: String)] = [
            ("Localizable", "strings"),
            ("Localizable.stringsdict", "stringsdict"),
            ("Templates", "strings"),
            ("InfoPlist", "strings"),
            ("ServicesMenu", "strings"),
        ]
        var failures: [String] = []
        for (table, ext) in tables {
            var perLocale: [String: [String: String]] = [:]
            var perLocaleVariants: [String: [String: [String: String]]] = [:]
            for locale in locales {
                let url = module.url(forResource: locale, withExtension: "lproj")
                    ?? module.bundleURL.appendingPathComponent("\(locale).lproj")
                // Table names double as file names: "Localizable" ->
                // Localizable.strings; "Localizable.stringsdict" is the file.
                let fileURL = url.appendingPathComponent(table.hasSuffix("stringsdict") ? table : "\(table).strings")
                if ext == "stringsdict" {
                    guard let data = FileManager.default.contents(atPath: fileURL.path),
                          let top = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                          let dict = top as? [String: [String: Any]] else {
                        failures.append("\(table)/\(locale): unparseable")
                        break
                    }
                    var variants: [String: [String: String]] = [:]
                    for (k, node) in dict {
                        guard let c = node["count"] as? [String: Any] else {
                            failures.append("\(table)/\(locale)[\(k)]: malformed plural node")
                            continue
                        }
                        var v: [String: String] = [:]
                        for (variant, value) in c where variant == "one" || variant == "other" {
                            if let s = value as? String { v[variant] = s }
                        }
                        variants[k] = v
                    }
                    perLocaleVariants[locale] = variants
                    perLocale[locale] = [:]
                } else {
                    guard let data = FileManager.default.contents(atPath: fileURL.path),
                          let top = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                          let dict = top as? [String: String] else {
                        failures.append("\(table)/\(locale): unparseable")
                        break
                    }
                    perLocale[locale] = dict
                }
            }
            guard let en = perLocale["en"], let zh = perLocale["zh-Hant-TW"] else { continue }
            if Set(en.keys) != Set(zh.keys) {
                failures.append("\(table): key parity en-only=\(Set(en.keys).subtracting(zh.keys).sorted()) zh-only=\(Set(zh.keys).subtracting(en.keys).sorted())")
            }
            if ext == "stringsdict" {
                // Parity rule (SPEC §8 rule 5 / review MINOR 2): 'other' is
                // required in both locales and signatures must match; 'one'
                // must match where present; a zh collapsed to 'other' only
                // must still carry the same signature as the en variant it
                // replaces. Mirrors scripts/check_localizations.sh.
                guard let enV = perLocaleVariants["en"], let zhV = perLocaleVariants["zh-Hant-TW"] else { continue }
                for (k, enCount) in enV {
                    guard let zhCount = zhV[k] else { continue } // covered by key parity
                    guard let enOther = enCount["other"], let zhOther = zhCount["other"] else {
                        failures.append("\(table)[\(k)]: 'other' variant required in both locales")
                        continue
                    }
                    guard let a = Self.formatSignature(enOther), let b = Self.formatSignature(zhOther) else {
                        failures.append("\(table)[\(k)]: unparseable 'other' format")
                        continue
                    }
                    if Self.sigString(a) != Self.sigString(b) {
                        failures.append("\(table)[\(k)] other: signature mismatch en=\(enOther) zh=\(zhOther)")
                    }
                    if let enOne = enCount["one"], let zhOne = zhCount["one"] {
                        guard let a = Self.formatSignature(enOne), let b = Self.formatSignature(zhOne) else {
                            failures.append("\(table)[\(k)]: unparseable 'one' format")
                            continue
                        }
                        if Self.sigString(a) != Self.sigString(b) {
                            failures.append("\(table)[\(k)] one: signature mismatch en=\(enOne) zh=\(zhOne)")
                        }
                    } else if let enOne = enCount["one"] {
                        guard let a = Self.formatSignature(enOne), let b = Self.formatSignature(zhOther) else {
                            failures.append("\(table)[\(k)]: unparseable collapsed comparison")
                            continue
                        }
                        if Self.sigString(a) != Self.sigString(b) {
                            failures.append("\(table)[\(k)]: collapsed zh 'other' differs from en 'one'")
                        }
                    }
                }
                continue
            }
            for k in Set(en.keys).intersection(zh.keys) {
                guard let a = Self.formatSignature(en[k]!), let b = Self.formatSignature(zh[k]!) else {
                    failures.append("\(table)[\(k)]: unparseable format")
                    continue
                }
                if Self.sigString(a) != Self.sigString(b) {
                    failures.append("\(table)[\(k)]: signature mismatch en=\(en[k]!) zh=\(zh[k]!)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "parity failures:\n" + failures.joined(separator: "\n"))
    }

    /// Recursive C-format signature: ordered [(position, converter)],
    /// %% included. Mirrors the parser in scripts/check_localizations.sh so
    /// `swift test` and the shell gate enforce identical signatures.
    static func formatSignature(_ s: String) -> [(Int, String)]? {
        var out: [(Int, String)] = []
        let converters: Set<Character> = ["@", "d", "D", "i", "I", "o", "O", "u", "U", "x", "X", "f", "F", "e", "E", "g", "G", "a", "A", "c", "s", "p"]
        let flags: Set<Character> = ["-", "+", " ", "#", "0"]
        let lengths: Set<Character> = ["l", "h", "q", "t"]
        var rest = s
        while let pct = rest.firstIndex(of: "%") {
            rest = String(rest[rest.index(after: pct)...])
            guard !rest.isEmpty else { return nil }
            // The first '%' was already consumed: a remaining leading '%' is
            // an escaped %% (literal percent), not a conversion.
            if rest.hasPrefix("%") {
                out.append((0, "%%"))
                rest = String(rest.dropFirst())
                continue
            }
            // optional positional argument: digits immediately followed by $
            var pos = 0
            if let dollar = rest.firstIndex(of: "$"),
               rest[rest.startIndex..<dollar].isEmpty == false,
               rest[rest.startIndex..<dollar].allSatisfy({ $0.isNumber }) {
                pos = Int(rest[rest.startIndex..<dollar]) ?? 0
                rest = String(rest[rest.index(after: dollar)...])
            }
            // flags, width, precision, length modifiers
            while let c = rest.first, flags.contains(c) { rest = String(rest.dropFirst()) }
            while let c = rest.first, c.isNumber { rest = String(rest.dropFirst()) }
            if let c = rest.first, c == "." {
                rest = String(rest.dropFirst())
                while let c = rest.first, c.isNumber { rest = String(rest.dropFirst()) }
            }
            while let c = rest.first, lengths.contains(c) { rest = String(rest.dropFirst()) }
            // converter
            guard let c = rest.first, converters.contains(c) else { return nil }
            out.append((pos, String(c)))
            rest = String(rest.dropFirst())
        }
        return out
    }

    // MARK: - Fixture builder

    /// String form of a signature for comparison (nested tuples are not
    /// Equatable in Swift).
    static func sigString(_ s: [(Int, String)]) -> String {
        s.map { "\($0.0):\($0.1)" }.joined(separator: ",")
    }

    /// String form used in failure diagnostics.
    static func sigDisplay(_ s: String) -> String {
        (formatSignature(s) ?? []).map { "\($0.0)$\($0.1)" }.joined(separator: ",")
    }

    /// Build a throwaway base bundle (en.lproj + zh-Hant-TW.lproj) from a
    /// reduced set of entries so missing-locale/table/key/malformed cases
    /// are testable without the installed app.
    static func fixture(
        withZHTW: Bool,
        withEN: Bool,
        deleteZHTWLocalizable: Bool = false,
        corruptENLocalizable: Bool = false,
        deleteZHTWKey: String? = nil,
        deleteENStringsdict: Bool = false
    ) -> Bundle {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("l10n-fixture-\(UUID().uuidString)", isDirectory: true)
        // Bundle(path:) requires a root Info.plist even for fixture bundles.
        let infoData = try! PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.felix.hushtype.fixture", "CFBundleName": "fixture"],
            format: .xml, options: 0)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? infoData.write(to: tmp.appendingPathComponent("Info.plist"))
        let enEntries: [String: String] = [
            "menu.about": "About HushType",
            "common.button.ok": "OK",
            "menu.quit": "Quit HushType",
            "format.usd_total": "$%1$.2f",
        ]
        var zhEntries: [String: String] = [
            "menu.about": "關於 HushType",
            "common.button.ok": "好",
            "menu.quit": "結束 HushType",
            "format.usd_total": "US$%1$.2f",
        ]
        if let drop = deleteZHTWKey { zhEntries[drop] = nil }

        func writeStrings(_ locale: String, _ entries: [String: String], corrupt: Bool = false) {
            let dir = tmp.appendingPathComponent("\(locale).lproj", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("Localizable.strings")
            if corrupt {
                try? "not a plist at all".write(to: f, atomically: true, encoding: .utf8)
            } else {
                let body = entries.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
                try? body.write(to: f, atomically: true, encoding: .utf8)
            }
        }

        if withEN { writeStrings("en", enEntries, corrupt: corruptENLocalizable) }
        if withZHTW && !deleteZHTWLocalizable { writeStrings("zh-Hant-TW", zhEntries) }

        if !deleteENStringsdict {
            let variants: [String: [String: [String: String]]] = [
                "en": ["menu.dictionary.entries_loaded": ["one": "%1$ld entry loaded", "other": "%1$ld entries loaded"]],
                "zh-Hant-TW": ["menu.dictionary.entries_loaded": ["other": "已載入 %1$ld 個項目"]],
            ]
            for (locale, table) in variants {
                guard (locale == "en" && withEN) || (locale == "zh-Hant-TW" && withZHTW) else { continue }
                let dir = tmp.appendingPathComponent("\(locale).lproj", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var top: [String: Any] = [:]
                for (key, count) in table {
                    var countNode: [String: Any] = [
                        "NSStringFormatSpecTypeKey": "NSStringFormatSpecTypeInt",
                        "NSStringFormatValueTypeKey": "l",
                    ]
                    for (variant, value) in count { countNode[variant] = value }
                    top[key] = ["NSStringLocalizedFormatKey": "%#@count@", "count": countNode]
                }
                let data = try! PropertyListSerialization.data(fromPropertyList: top, format: .xml, options: 0)
                try? data.write(to: dir.appendingPathComponent("Localizable.stringsdict"))
            }
        }

        guard let bundle = Bundle(path: tmp.path) else {
            XCTFail("fixture bundle not constructable at \(tmp.path)")
            return Bundle.module
        }
        return bundle
    }
}
