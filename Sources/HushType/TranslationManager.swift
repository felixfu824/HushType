import SwiftUI
import Translation
import NaturalLanguage
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "translation")

/// Typed errors for translation failures, mapped to specific UI alerts.
enum TranslationError: LocalizedError {
    case unsupportedLanguage(String)
    case languagePackMissing(String, String)
    case translationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let lang):
            return "Language '\(lang)' is not supported by Apple Translation Framework."
        case .languagePackMissing(let source, let target):
            return "Language pack for \(source) → \(target) is not installed."
        case .translationFailed(let detail):
            return "Translation failed: \(detail)"
        }
    }
}

/// Manages text translation using Apple's Translation framework.
///
/// Uses `NLLanguageRecognizer` to detect the source language, then routes
/// through a hidden SwiftUI bridge window to invoke `TranslationSession`.
///
/// Language routing:
///   - Chinese input → translate to English
///   - Everything else → translate to zh-Hant-TW (繁體中文)
///
/// The bridge window must be visible (not off-screen) for `.translationTask`
/// to fire reliably. It is cleaned up immediately after the result arrives.
final class TranslationManager {

    /// Hidden NSWindow that hosts the SwiftUI `TranslationBridge`.
    /// Kept as a strong reference so the view hierarchy stays alive until
    /// the translation completes.
    var bridgeWindow: NSWindow?

    // MARK: - Public API

    /// Human-readable names for common NLLanguage codes.
    private static let languageNames: [String: String] = [
        "zh-Hans": "Chinese", "zh-Hant": "Chinese",
        "en": "English", "ja": "Japanese", "ko": "Korean",
        "fr": "French", "de": "German", "es": "Spanish",
        "pt": "Portuguese", "it": "Italian", "ru": "Russian",
        "ar": "Arabic", "th": "Thai", "vi": "Vietnamese",
        "id": "Indonesian", "tr": "Turkish", "pl": "Polish",
        "nl": "Dutch", "uk": "Ukrainian",
    ]

    /// Translate `text`, auto-detecting source language.
    ///
    /// - Parameters:
    ///   - text: The string to translate.
    ///   - completion: Called on the main thread with either
    ///     `(translated: String, direction: String)` or an `Error`.
    func translate(
        text: String,
        completion: @escaping (Result<(translated: String, direction: String), Error>) -> Void
    ) {
        // --- Language detection ---
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage

        guard let detected else {
            completion(.failure(TranslationError.unsupportedLanguage("unknown")))
            return
        }

        let sourceIdentifier = detected.rawValue  // BCP 47: "en", "th", "ja", etc.
        let sourceLanguage = Locale.Language(identifier: sourceIdentifier)
        let targetLanguage: Locale.Language
        let sourceName = Self.languageNames[sourceIdentifier] ?? sourceIdentifier
        let targetName: String

        if detected == .simplifiedChinese || detected == .traditionalChinese {
            targetLanguage = Locale.Language(identifier: "en")
            targetName = "English"
        } else {
            targetLanguage = Locale.Language(identifier: "zh-Hant-TW")
            targetName = "繁體中文"
        }

        let directionLabel = "\(sourceName) → \(targetName)"
        print("[Translation] Detected: \(sourceIdentifier) → \(directionLabel)")
        fflush(stdout)

        // --- Check language availability ---
        Task {
            let availability = LanguageAvailability()
            let status = await availability.status(from: sourceLanguage, to: targetLanguage)

            await MainActor.run {
                switch status {
                case .installed:
                    // Good to go — proceed with translation
                    self.performTranslation(
                        text: text,
                        source: sourceLanguage,
                        target: targetLanguage,
                        directionLabel: directionLabel,
                        completion: completion
                    )
                case .supported:
                    // Language pack not downloaded yet
                    completion(.failure(TranslationError.languagePackMissing(sourceName, targetName)))
                case .unsupported:
                    completion(.failure(TranslationError.unsupportedLanguage(sourceName)))
                @unknown default:
                    completion(.failure(TranslationError.unsupportedLanguage(sourceName)))
                }
            }
        }

    }

    // MARK: - Private

    private func performTranslation(
        text: String,
        source: Locale.Language,
        target: Locale.Language,
        directionLabel: String,
        completion: @escaping (Result<(translated: String, direction: String), Error>) -> Void
    ) {
        let bridge = TranslationBridge(
            sourceText: text,
            sourceLanguage: source,
            targetLanguage: target
        ) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let translated):
                    print("[Translation] Success: \(translated.prefix(80))…")
                    fflush(stdout)
                    completion(.success((translated: translated, direction: directionLabel)))
                case .failure(let error):
                    print("[Translation] Error: \(error.localizedDescription)")
                    fflush(stdout)
                    completion(.failure(error))
                }

                // Tear down the bridge window
                self?.bridgeWindow?.orderOut(nil)
                self?.bridgeWindow = nil
            }
        }

        let hostingView = NSHostingView(rootView: bridge)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.alphaValue = 0  // invisible but still "visible" to the system

        self.bridgeWindow = window

        // orderFront triggers onAppear → translationTask
        window.orderFront(nil)
        log.debug("Bridge window shown, awaiting translation")
    }
}

// MARK: - SwiftUI Bridge

/// A 1×1 invisible SwiftUI view whose sole purpose is to host a
/// `.translationTask` modifier. Apple's Translation framework requires a
/// SwiftUI view hierarchy to drive the session.
private struct TranslationBridge: View {
    let sourceText: String
    let sourceLanguage: Locale.Language
    let targetLanguage: Locale.Language
    let onResult: (Result<String, Error>) -> Void

    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                do {
                    // Ensure language pack is available before translating
                    try await session.prepareTranslation()
                    let response = try await session.translate(sourceText)
                    onResult(.success(response.targetText))
                } catch {
                    log.error("TranslationSession failed: \(error.localizedDescription)")
                    onResult(.failure(error))
                }
            }
            .onAppear {
                // IMPORTANT: source must NOT be nil — nil causes
                // TranslationSession.TranslationError.unableToIdentifyLanguage
                configuration = .init(
                    source: sourceLanguage,
                    target: targetLanguage
                )
                log.debug("Configuration set: \(String(describing: sourceLanguage)) → \(String(describing: targetLanguage))")
            }
    }
}
