import Foundation
import os

// MARK: - Interface language model

/// User-selectable interface (UI) language. This is deliberately separate
/// from `AppConfig.language` (speech-recognition language) and from
/// `translateTargetLanguage` / `cloudTargetLanguage`. Selecting a value
/// persists the *next-launch* preference only; it never restarts, quits,
/// terminates, cancels, or stops any work (SPEC §4.6, §5.6, §5.7).
enum InterfaceLanguage: String, Hashable, Sendable {
    case system
    case english = "en"
    case traditionalChineseTaiwan = "zh-Hant-TW"
}

/// Ordered resolver + effective-locale holder for interface localization.
///
/// "Follow System" resolves exactly once at launch from the ordered
/// process/per-app preferred-language list (SPEC §5.3):
/// - `en`, `en-*`                -> English
/// - `zh-Hant-TW`, `zh-TW`, bare `zh-Hant` -> `zh-Hant-TW`
/// - `zh-HK`, `zh-MO`, `zh-Hant-HK`, `zh-Hant-MO` -> `zh-Hant-TW` (documented
///   nearest supported Traditional-Chinese UI)
/// - bare `zh`, `zh-Hans`, `zh-CN`, `zh-SG` -> unsupported; continue walking
/// - empty/corrupt list or no supported entry -> English
///
/// HushType deliberately prevents Foundation's accidental
/// Simplified-to-Traditional nearest match: a `zh-CN`-only system stays
/// English, and only the explicit mappings above produce Chinese.
enum InterfaceLocale {
    /// Tags this build supports for the in-app UI.
    static let supportedTags = ["en", "zh-Hant-TW"]

    /// Map one BCP-47 preference to a supported tag, or nil if unsupported.
    /// Normalizes script/region spelling before comparing.
    /// `en` and every `en-*` regional variant map to English; the Chinese
    /// mappings are the explicit spec list — nothing else ever produces
    /// Chinese (no generic `hasPrefix("zh")` rule).
    static func supportedTag(for raw: String) -> String? {
        let norm = normalize(raw)
        if norm == "en" || norm.hasPrefix("en-") {
            return "en"
        }
        switch norm {
        case "zh-hant-tw", "zh-tw", "zh-hant":
            return "zh-Hant-TW"
        case "zh-hk", "zh-mo", "zh-hant-hk", "zh-hant-mo":
            return "zh-Hant-TW"
        default:
            // bare zh, zh-hans, zh-cn, zh-sg, and everything else:
            // unsupported — the caller continues to the next preference.
            return nil
        }
    }

    /// Lowercase the tag, normalize separators (`zh_Hant_TW` -> `zh-hant-tw`),
    /// and truncate at the first BCP-47 extension sequence (`-u-` Unicode
    /// extension, `-x-` private-use), e.g. `en-US-u-oxendict` -> `en-us`,
    /// `zh-Hant-TW-x-private` -> `zh-hant-tw`. Malformed tails that are not
    /// u/x extensions are left in place and simply fail to match, which is
    /// the safe "continue to the next preference" behavior.
    static func normalize(_ raw: String) -> String {
        let segments = raw
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
        var kept: [String] = []
        for segment in segments {
            let s = String(segment)
            if segment.count == 1, s == "u" || s == "x" {
                break
            }
            kept.append(s)
        }
        return kept.joined(separator: "-")
    }

    /// Walk an ordered preference list once; return the effective tag.
    /// Falls back to `"en"` when nothing supported is found.
    static func effectiveTag(preferences: [String]) -> String {
        for raw in preferences {
            if let tag = supportedTag(for: raw) { return tag }
        }
        return "en"
    }

    /// The launch-time ordered process/per-app preferred-language list.
    static var processPreferredTags: [String] {
        Locale.preferredLanguages
    }
}

// MARK: - L10n

/// The single app-owned localization façade (SPEC §5.2, §5.4, §5.5, §8).
///
/// All app-owned UI must resolve strings through `L10n.string`,
/// `L10n.format`, or `L10n.plural` — never through implicit
/// `LocalizedStringKey`, `Bundle.main` convenience lookups, or direct
/// `String(format:)` for localized text.
///
/// Bundle selection (SPEC §5.2): if the real main bundle is a packaged
/// `.app`, use `Bundle.main` and never fall through to the developer module
/// bundle when it is missing or malformed; otherwise (swift run, direct
/// `.build` executable, tests) use `Bundle.module`. Tests may inject a
/// fixture bundle via `overrideBaseBundle`.
enum L10n {
    /// Runtime base-bundle rule: `.app` main bundle wins; else module bundle.
    /// A malformed packaged main bundle logs a fault and stays on
    /// `Bundle.main` (call sites supply human-readable English fallbacks);
    /// it never falls back to a developer build-path resource bundle.
    static func baseBundle() -> Bundle {
        let main = Bundle.main
        if main.bundleURL.pathExtension == "app" {
            return main
        }
        return Bundle.module
    }

    /// Test hook: injected bundle overrides the runtime rule.
    static var overrideBaseBundle: Bundle?

    /// Test hook: force the macOS 15.0–15.3 legacy `.lproj` lookup strategy
    /// even on newer machines so both strategies are exercised identically.
    /// Production code never sets this.
    static var forceLegacyLookupForTests = false

    static func effectiveBaseBundle() -> Bundle {
        overrideBaseBundle ?? baseBundle()
    }

    /// The preference the user persisted for the *next* launch
    /// (`hushtype.interfaceLanguage`). Corrupt/unknown values resolve to
    /// `.system` (SPEC §5.3/§5.6). Read on each access so tests (and the
    /// menu's one-time snapshot at construction) see the persisted value.
    static var launchPreference: InterfaceLanguage {
        let raw = AppConfig.shared.interfaceLanguageRaw ?? InterfaceLanguage.system.rawValue
        return InterfaceLanguage(rawValue: raw) ?? .system
    }

    /// The interface language this process actually runs in. Resolved exactly
    /// once at launch and cached; `resetLaunchStateForTests()` is the only
    /// escape hatch and is test-only.
    static var launchTag: String { launchState.tag() }

    /// The effective UI locale used for every lookup and for every
    /// `String(format:locale:arguments:)` call. Always exactly `en` or
    /// `zh-Hant-TW` — never the process locale (SPEC §8 rule 2).
    static var effectiveLocale: Locale { Locale(identifier: launchTag) }

    final class LaunchState {
        private var resolved: String?
        func tag() -> String {
            if let r = resolved { return r }
            let t: String
            switch launchPreference {
            case .english: t = "en"
            case .traditionalChineseTaiwan: t = "zh-Hant-TW"
            case .system: t = InterfaceLocale.effectiveTag(preferences: InterfaceLocale.processPreferredTags)
            }
            resolved = t
            return t
        }
        func reset() { resolved = nil }
    }
    static let launchState = LaunchState()

    /// Test-only: re-resolve `launchTag` after mutating the persisted
    /// preference in UserDefaults.
    static func resetLaunchStateForTests() { launchState.reset() }

    // MARK: Lookup

    /// Exact missing-key/table algorithm (SPEC §5.4), shared by the new and
    /// legacy lookup strategies:
    /// 1. query the requested localization with `value: nil` (never pass the
    ///    developer fallback on the first lookup);
    /// 2. if the locale bundle/table is absent, malformed, or returns the
    ///    semantic key unchanged, treat it as missing;
    /// 3. query the exact `en.lproj` the same way;
    /// 4. if English is also missing, return the nonempty human-readable
    ///    English `fallback` and log the manifest defect.
    /// The semantic key may appear in diagnostics only, never as normal UI.
    static func string(_ key: String, table: String = "Localizable", fallback: String) -> String {
        let base = effectiveBaseBundle()
        // 1. requested locale
        if launchTag != "en" {
            if let s = exactLookup(key, table: table, tag: launchTag, in: base), s != key {
                return s
            }
        }
        // 3. exact English
        if let s = exactLookup(key, table: table, tag: "en", in: base), s != key {
            return s
        }
        // 4. human-readable fallback
        if ProcessInfo.processInfo.environment["HUSHTYPE_L10N_ASSERT"] != nil {
            assertionFailure("L10n: missing localization key \(key) (table \(table))")
        }
        log.error("L10n missing key \(key, privacy: .public) table \(table, privacy: .public) tag \(launchTag, privacy: .public); using English fallback")
        return fallback
    }

    /// Format a localized string with the effective locale. This is the only
    /// allowed localized formatting path (SPEC §8 rule 2). Arguments must be
    /// C types matching the entry's `%@` / `%d` / `%ld` / `%f` specifiers.
    static func format(_ key: String, _ fallback: String, table: String = "Localizable", arguments: [CVarArg]) -> String {
        let template = string(key, table: table, fallback: fallback)
        return String(format: template, locale: effectiveLocale, arguments: arguments)
    }

    /// Encode one Swift string as a complete JSON string literal. Template
    /// generators use this while retaining a deliberately hand-authored key
    /// order. U+2028/U+2029 are escaped for compatibility with every JSON
    /// consumer, in addition to JSON's required quote/control escapes.
    static func jsonStringLiteral(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0C: result += "\\f"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x00...0x1F, 0x2028, 0x2029:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }

    /// Pluralized lookup through the Apple-standard `Localizable.stringsdict`
    /// table.
    ///
    /// Why this parses the stringsdict instead of using the 15.4-only
    /// `Bundle.localizedString(forKey:value:table:localizations:)`: the
    /// deployment floor is macOS 15.0, and an empirical probe on this machine
    /// (macOS 26.5.2) showed `String(format:locale:arguments:)` cannot consume
    /// the `%#@count@` ICU template that a stringsdict lookup returns — it
    /// renders `(null)`. Parsing the selected locale's stringsdict with
    /// PropertyListSerialization, picking the variant, then formatting with
    /// the *explicit* effective locale is complete for the only two
    /// supported UI locales and is directly testable across process locales:
    /// - English: `one` only for integer count 1, `other` otherwise;
    /// - zh-Hant-TW: always `other` (invariant form).
    /// Requested-locale and English lookups follow the same fallback chain as
    /// `string(_:table:fallback:)`.
    static func plural(_ key: String, _ count: Int, table: String = "Localizable", fallback: String) -> String {
        plural(key, count: count, table: table, fallback: fallback, arguments: [count])
    }

    /// Plural selection with an explicit formatting argument list. Use this
    /// when the grammatical count is not the only placeholder, or is not the
    /// first placeholder in the selected variant.
    static func plural(
        _ key: String,
        count: Int,
        table: String = "Localizable",
        fallback: String,
        arguments: [CVarArg]
    ) -> String {
        let base = effectiveBaseBundle()
        if launchTag != "en" {
            if let variant = pluralVariant(key, count: count, table: table, tag: launchTag, in: base) {
                return String(format: variant, locale: effectiveLocale, arguments: arguments)
            }
        }
        if let variant = pluralVariant(key, count: count, table: table, tag: "en", in: base) {
            return String(format: variant, locale: effectiveLocale, arguments: arguments)
        }
        if ProcessInfo.processInfo.environment["HUSHTYPE_L10N_ASSERT"] != nil {
            assertionFailure("L10n: missing plural key \(key)")
        }
        log.error("L10n missing plural key \(key, privacy: .public) tag \(launchTag, privacy: .public); using English fallback")
        return String(format: fallback, locale: effectiveLocale, arguments: arguments)
    }

    /// Load `<tag>.lproj/<table>.stringsdict` and return the formatted
    /// variant's raw template (before `String(format:)`), or nil when the
    /// locale bundle, table, or key is missing/malformed (SPEC §5.4 step 2).
    static func pluralVariant(_ key: String, count: Int, table: String, tag: String, in base: Bundle) -> String? {
        let lprojURL = base.bundleURL.appendingPathComponent("\(tag).lproj")
        guard let lproj = Bundle(path: lprojURL.path) else {
            return nil
        }
        let dictURL = lproj.bundleURL
            .appendingPathComponent("\(table).stringsdict")
        guard let data = FileManager.default.contents(atPath: dictURL.path),
              let top = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let entries = top as? [String: Any],
              let node = entries[key] as? [String: Any],
              let countNode = node["count"] as? [String: Any] else {
            return nil
        }
        let wantOne = (tag == "en") && (count == 1)
        let variantKey = wantOne && countNode["one"] != nil ? "one" : "other"
        guard let template = countNode[variantKey] as? String else { return nil }
        return template
    }

    // MARK: Low-level lookup

    /// Strategy-isolated exact lookup for one tag (SPEC §5.4):
    /// - macOS 15.4+: `Bundle.localizedString(forKey:value:table:localizations:)`
    ///   with the effective `Locale.Language` passed explicitly;
    /// - macOS 15.0–15.3: locate the exact `<tag>.lproj`, construct
    ///   `Bundle(path:)`, and call `localizedString(forKey:value:table:)`.
    /// Returns nil (never the key) only when the bundle is not constructed;
    /// a malformed/missing key surfaces as the key itself and callers apply
    /// the returned-key test.
    private static func exactLookup(_ key: String, table: String, tag: String, in base: Bundle) -> String? {
        if forceLegacyLookupForTests {
            return legacyLookup(key, table: table, tag: tag, in: base)
        }
        if #available(macOS 15.4, *) {
            return newLookup(key, table: table, tag: tag, in: base)
        }
        return legacyLookup(key, table: table, tag: tag, in: base)
    }

    @available(macOS 15.4, *)
    private static func newLookup(_ key: String, table: String, tag: String, in base: Bundle) -> String? {
        // value: nil — the developer fallback must not hide "missing".
        let language = Locale.Language(identifier: tag)
        return base.localizedString(forKey: key, value: nil, table: table, localizations: [language])
    }

    private static func legacyLookup(_ key: String, table: String, tag: String, in base: Bundle) -> String? {
        let lprojURL = base.bundleURL.appendingPathComponent("\(tag).lproj")
        guard let lproj = Bundle(path: lprojURL.path) else {
            return nil
        }
        return lproj.localizedString(forKey: key, value: nil, table: table)
    }

    private static let log = Logger(subsystem: "com.felix.hushtype", category: "l10n")
}
