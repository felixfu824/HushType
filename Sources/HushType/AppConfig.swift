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
    }

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

    private init() {}
}
