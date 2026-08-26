import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "config")

final class AppConfig {
    static let shared = AppConfig()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let language = "hushtype.language"
        static let modelId = "hushtype.modelId"
        static let chineseConversionEnabled = "hushtype.chineseConversionEnabled"
        static let floatingOverlayEnabled = "hushtype.floatingOverlayEnabled"
        static let onboardingCompleted = "hushtype.onboardingCompleted"
        static let numberConversionEnabled = "hushtype.numberConversionEnabled"
        static let textPolishEnabled = "hushtype.textPolishEnabled"
        static let textTranslationEnabled = "hushtype.textTranslationEnabled"
        static let translateTargetLanguage = "hushtype.translateTargetLanguage"
        static let cloudTargetLanguage = "hushtype.cloudTargetLanguage"
        static let cloudShowSourceLine = "hushtype.cloudShowSourceLine"
        static let cloudAutoStopMinutes = "hushtype.cloudAutoStopMinutes"
        static let cloudDailyCapDollars = "hushtype.cloudDailyCapDollars"
        static let cloudOnboardingShown = "hushtype.cloudOnboardingShown"
        static let lastStartedCaptionMode = "hushtype.lastStartedCaptionMode"
        static let lastStartedCaptionUsesMicSource = "hushtype.lastStartedCaptionUsesMicSource"
        static let punctuationMode = "hushtype.punctuationMode"
        static let dictationEngine = "hushtype.dictationEngine"
        static let cloudDictationModelOpenAI = "hushtype.cloudDictationModelOpenAI"
        static let cloudDictationModelGemini = "hushtype.cloudDictationModelGemini"
        static let interfaceLanguage = "hushtype.interfaceLanguage"
    }

    /// Dictation deliberately persists its engine choice across launches so
    /// cloud users can keep the local Qwen model out of memory. Unlike Live
    /// Caption, recording still requires an explicit hotkey hold each time.
    enum DictationEngine: String, Equatable, Sendable {
        case local
        case openai
        case gemini
    }

    var dictationEngine: DictationEngine {
        get {
            guard let raw = defaults.string(forKey: Keys.dictationEngine),
                  let engine = DictationEngine(rawValue: raw) else {
                return .local
            }
            return engine
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.dictationEngine)
            log.info("Dictation engine set to: \(newValue.rawValue, privacy: .public)")
        }
    }

    var cloudDictationModelOpenAI: String {
        get { defaults.string(forKey: Keys.cloudDictationModelOpenAI) ?? "gpt-4o-mini-transcribe" }
        set { defaults.set(newValue, forKey: Keys.cloudDictationModelOpenAI) }
    }

    var cloudDictationModelGemini: String {
        get { defaults.string(forKey: Keys.cloudDictationModelGemini) ?? "gemini-3.5-flash-lite" }
        set { defaults.set(newValue, forKey: Keys.cloudDictationModelGemini) }
    }

    /// Interface (UI) language — deliberately separate from `language`
    /// (speech-recognition language), `translateTargetLanguage`, and
    /// `cloudTargetLanguage` (SPEC §4.4). Persisted as
    /// `hushtype.interfaceLanguage`; a new key, so no migration is needed.
    /// Corrupt/unknown raw values resolve to `.system` (SPEC §5.3/§5.6) and
    /// are normalized only by the next explicit user choice.
    var interfaceLanguageRaw: String? {
        get { defaults.string(forKey: Keys.interfaceLanguage) }
        set {
            defaults.set(newValue, forKey: Keys.interfaceLanguage)
            log.info("Interface language set to: \(newValue ?? "system", privacy: .public)")
        }
    }

    var interfaceLanguage: InterfaceLanguage {
        get { InterfaceLanguage(rawValue: interfaceLanguageRaw ?? InterfaceLanguage.system.rawValue) ?? .system }
        set { interfaceLanguageRaw = newValue.rawValue }
    }

    /// Engine for Live Caption — local Qwen3 ASR vs. OpenAI cloud translate.
    /// SESSION-ONLY: not persisted across launches. Every app boot resets to
    /// `.local` so a fresh launch can't silently start spending money on
    /// cloud. Same rationale as `liveCaptionEnabled` (see §13.4 of the
    /// cloud-translate spec). User must explicitly flip in Settings each
    /// session.
    enum LiveCaptionEngine: String, Equatable, Sendable {
        case local
        case cloudTranslate
    }
    var liveCaptionEngine: LiveCaptionEngine = .local

    /// Language for transcription. nil = auto-detect.
    var language: String? {
        get { defaults.string(forKey: Keys.language) }
        set {
            defaults.set(newValue, forKey: Keys.language)
            log.info("Language set to: \(newValue ?? "auto", privacy: .public)")
        }
    }

    /// HuggingFace model ID for Qwen3-ASR.
    var modelId: String {
        get { defaults.string(forKey: Keys.modelId) ?? "aufklarer/Qwen3-ASR-0.6B-MLX-4bit" }
        set { defaults.set(newValue, forKey: Keys.modelId) }
    }

    /// Whether to convert Simplified Chinese output to Traditional Chinese.
    var chineseConversionEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.chineseConversionEnabled) == nil {
                return true // Default: enabled
            }
            return defaults.bool(forKey: Keys.chineseConversionEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.chineseConversionEnabled) }
    }

    /// Whether to show the floating "Listening / Transcribing" overlay
    /// near the bottom of the screen during dictation.
    var floatingOverlayEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.floatingOverlayEnabled) == nil {
                return true // Default: enabled
            }
            return defaults.bool(forKey: Keys.floatingOverlayEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.floatingOverlayEnabled)
            log.info("Floating overlay enabled: \(newValue, privacy: .public)")
        }
    }

    /// Whether the user has seen the welcome onboarding modal at least once.
    /// Used to decide between showing the friendly "welcome" message vs the
    /// shorter "permission needed" guidance on subsequent launches.
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Keys.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Keys.onboardingCompleted) }
    }

    /// Whether to run deterministic ITN (inverse text normalization) over each
    /// transcription to convert Chinese numerals to Arabic digits in context.
    /// Runs after OpenCC in the pipeline. On by default;
    /// reversible from the Number Conversion menu toggle.
    var numberConversionEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.numberConversionEnabled) == nil {
                return true // Default: enabled
            }
            return defaults.bool(forKey: Keys.numberConversionEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.numberConversionEnabled)
            log.info("Number conversion enabled: \(newValue, privacy: .public)")
        }
    }

    /// How aggressively to strip the model's over-aggressive Chinese inline
    /// punctuation (the 「，、」 it inserts on speech pauses). Applies to
    /// dictation and local live-caption, CHINESE text only (gated by
    /// `ScriptDetector`). `.soft` (default) drops the noisy inline marks but
    /// keeps sentence enders 。！？; `.hard` drops all punctuation; `.off`
    /// disables the pass. Persisted; falls back to `.soft` on an unknown value.
    var punctuationMode: PunctuationMode {
        get {
            guard let raw = defaults.string(forKey: Keys.punctuationMode),
                  let mode = PunctuationMode(rawValue: raw) else {
                return .soft
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.punctuationMode)
            log.info("Punctuation mode set to: \(newValue.rawValue, privacy: .public)")
        }
    }

    /// Whether double-tap Right ⌥ and the Services entry can proofread selected
    /// text with Apple Foundation Models. On by default; runtime availability
    /// is cached separately so unsupported systems retain immediate single-tap
    /// translation behavior.
    var textPolishEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.textPolishEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.textPolishEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.textPolishEnabled)
            log.info("Text polish enabled: \(newValue, privacy: .public)")
        }
    }

    /// Whether the text-translation hotkey (tap Right ⌥) is active.
    /// Uses Apple Translation Framework (macOS 14+). Off by default.
    var textTranslationEnabled: Bool {
        get { defaults.bool(forKey: Keys.textTranslationEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.textTranslationEnabled)
            log.info("Text translation enabled: \(newValue, privacy: .public)")
        }
    }

    /// Whether live caption mode is currently active. SESSION-ONLY — NOT
    /// persisted to UserDefaults. Always `false` on launch. Live caption is
    /// a privacy-sensitive always-on-mic mode; auto-resuming after relaunch
    /// would surprise the user and violates the explicit-enter/exit mental
    /// model. Flips of this flag MUST go through `LiveCaptionManager.start()`
    /// / `stop()` — never direct mutation — so the manager's `onStateChanged`
    /// callback drives the menu checkmark.
    var liveCaptionEnabled: Bool = false

    /// True only when Live Caption is active AND the source is `.mic`. Used
    /// by `AppDelegate.handleHotkeyPress` (running on the CGEvent tap thread,
    /// outside the main actor) to decide whether to gate dictation — system-
    /// audio Live Caption doesn't compete with the mic, so dictation works
    /// concurrently. Maintained by `LiveCaptionManager` alongside
    /// `liveCaptionEnabled`.
    var liveCaptionUsesMicSource: Bool = false

    /// Target language for translation. nil = auto (smart direction).
    var translateTargetLanguage: String? {
        get { defaults.string(forKey: Keys.translateTargetLanguage) }
        set {
            defaults.set(newValue, forKey: Keys.translateTargetLanguage)
            log.info("Translate target: \(newValue ?? "auto", privacy: .public)")
        }
    }

    // MARK: - Cloud Translate (Live Caption)

    /// Target language for cloud translate. Two-letter ISO except for the two
    /// Chinese variants which downstream code maps to `"zh"` + OpenCC. Default
    /// `"en"`. Persisted.
    var cloudTargetLanguage: String {
        get { defaults.string(forKey: Keys.cloudTargetLanguage) ?? "en" }
        set {
            defaults.set(newValue, forKey: Keys.cloudTargetLanguage)
            log.info("Cloud target language set to: \(newValue, privacy: .public)")
        }
    }

    /// Whether to show the recognized source-language line above the translated
    /// caption line. Default `true` — paid usage benefits from a sanity-check
    /// that the system is translating what the user thinks. Persisted.
    var cloudShowSourceLine: Bool {
        get {
            if defaults.object(forKey: Keys.cloudShowSourceLine) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.cloudShowSourceLine)
        }
        set { defaults.set(newValue, forKey: Keys.cloudShowSourceLine) }
    }

    /// Auto-stop the cloud session after this many minutes. Default 60.
    /// Clamped to 5...480 on set.
    var cloudAutoStopMinutes: Int {
        get {
            if defaults.object(forKey: Keys.cloudAutoStopMinutes) == nil {
                return 60
            }
            return defaults.integer(forKey: Keys.cloudAutoStopMinutes)
        }
        set {
            let clamped = max(5, min(480, newValue))
            defaults.set(clamped, forKey: Keys.cloudAutoStopMinutes)
        }
    }

    /// Daily spend warning threshold in USD. Cloud dictation latches off
    /// before an upload would reach it; Reset counter clears the daily latch.
    /// Default $5. Clamped to 0.5...100.0 on set.
    var cloudDailyCapDollars: Double {
        get {
            if defaults.object(forKey: Keys.cloudDailyCapDollars) == nil {
                return 5.0
            }
            return defaults.double(forKey: Keys.cloudDailyCapDollars)
        }
        set {
            let clamped = max(0.5, min(100.0, newValue))
            defaults.set(clamped, forKey: Keys.cloudDailyCapDollars)
        }
    }

    /// Whether the user has dismissed the one-time pre-session cloud
    /// disclosure modal. Persists once true.
    var cloudOnboardingShown: Bool {
        get { defaults.bool(forKey: Keys.cloudOnboardingShown) }
        set { defaults.set(newValue, forKey: Keys.cloudOnboardingShown) }
    }

    /// Which of the two caption products the user last started. Persisted so
    /// the Right ⌘ + / hotkey can toggle "the same one I had running yesterday"
    /// instead of always defaulting to local. First-use default = `.local` so
    /// nobody accidentally racks up a translation bill via muscle memory on
    /// day one. Set inside `AppDelegate` whenever a start path succeeds.
    enum CaptionMode: String, Equatable, Sendable {
        case local
        case translated
    }
    var lastStartedCaptionMode: CaptionMode {
        get {
            guard let raw = defaults.string(forKey: Keys.lastStartedCaptionMode),
                  let mode = CaptionMode(rawValue: raw) else {
                return .local
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.lastStartedCaptionMode)
        }
    }

    /// What source the user picked the last time they started either caption
    /// product. PERSISTED — and never reset on stop (unlike
    /// `liveCaptionUsesMicSource`, which is a "currently active" flag the
    /// dictation gate relies on). Used by the Right ⌘ + / hotkey handler to
    /// decide whether to re-invoke on mic or system audio. First-use default
    /// = true (mic) so day-one hotkey doesn't pop the system-audio picker.
    var lastStartedCaptionUsesMicSource: Bool {
        get {
            if defaults.object(forKey: Keys.lastStartedCaptionUsesMicSource) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.lastStartedCaptionUsesMicSource)
        }
        set {
            defaults.set(newValue, forKey: Keys.lastStartedCaptionUsesMicSource)
        }
    }

    /// Path to the user-editable customized dictionary file. The dictionary is
    /// applied as the final post-processing step (after OpenCC and ITN)
    /// to fix recurring transcription errors like proper nouns and jargon.
    /// If the file doesn't exist, no replacements happen — there's no separate
    /// enable/disable toggle. Power users edit the file directly in their
    /// default text editor; the menu item triggers `NSWorkspace.shared.open`.
    ///
    /// The extension is `.txt` (not `.tsv`) so macOS opens it in TextEdit,
    /// which edits in place. `.tsv` defaults to Apple Numbers, which wraps the
    /// file as a new Numbers document and saves to a different location —
    /// breaking the file-is-the-UI contract.
    static var dictionaryFileURL: URL {
        AppSupportPaths.dictionaryFileURL
    }

    static func promptOverrideURL(filename: String) -> URL {
        AppSupportPaths.promptOverrideURL(filename: filename)
    }

    /// Path to the OpenAI API key file used by the cloud Live Caption engine.
    /// Plaintext JSON, same security profile as `.env`. Loader rules in
    /// `OpenAIKeyStore`.
    static var openAIKeyFileURL: URL {
        AppSupportPaths.openAIKeyFileURL
    }

    private init() {}
}
