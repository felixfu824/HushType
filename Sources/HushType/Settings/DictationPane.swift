import AppKit
import Settings
import SwiftUI

extension Notification.Name {
    static let hushTypeDictationEngineDidChange = Notification.Name(
        "com.felix.hushtype.dictationEngineDidChange"
    )
}

@MainActor
final class DictationSettingsModel: ObservableObject {
    @Published var engine: AppConfig.DictationEngine {
        didSet {
            guard engine != oldValue else { return }
            onSwitchEngine(engine)
        }
    }

    @Published var openAIModel: String {
        didSet { AppConfig.shared.cloudDictationModelOpenAI = openAIModel }
    }

    @Published var geminiModel: String {
        didSet { AppConfig.shared.cloudDictationModelGemini = geminiModel }
    }

    @Published var speechLanguage: String? {
        didSet { AppConfig.shared.language = speechLanguage }
    }

    @Published var numberConversionEnabled: Bool {
        didSet { AppConfig.shared.numberConversionEnabled = numberConversionEnabled }
    }

    @Published var punctuationMode: PunctuationMode {
        didSet { AppConfig.shared.punctuationMode = punctuationMode }
    }

    @Published private(set) var dictionaryStatus = ""

    private let onSwitchEngine: (AppConfig.DictationEngine) -> Void

    init(onSwitchEngine: @escaping (AppConfig.DictationEngine) -> Void) {
        self.onSwitchEngine = onSwitchEngine
        engine = AppConfig.shared.dictationEngine
        openAIModel = AppConfig.shared.cloudDictationModelOpenAI
        geminiModel = AppConfig.shared.cloudDictationModelGemini
        speechLanguage = AppConfig.shared.language
        numberConversionEnabled = AppConfig.shared.numberConversionEnabled
        punctuationMode = AppConfig.shared.punctuationMode
        refreshDictionaryStatus()
    }

    var openAIRate: Double {
        CloudUsageTracker.dictationRate(provider: .openai, model: openAIModel)
    }

    var geminiRate: Double {
        CloudUsageTracker.dictationRate(provider: .gemini, model: geminiModel)
    }

    func refresh() {
        engine = AppConfig.shared.dictationEngine
        openAIModel = AppConfig.shared.cloudDictationModelOpenAI
        geminiModel = AppConfig.shared.cloudDictationModelGemini
        speechLanguage = AppConfig.shared.language
        numberConversionEnabled = AppConfig.shared.numberConversionEnabled
        punctuationMode = AppConfig.shared.punctuationMode
        refreshDictionaryStatus()
    }

    func openDictionary() {
        DictionaryReplacer.createTemplateIfMissing()
        let url = AppConfig.dictionaryFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = L10n.string(
                "alert.file_create.dictionary.title",
                fallback: "Could not open dictionary"
            )
            alert.informativeText = L10n.format(
                "alert.file_create.dictionary.message",
                "Failed to create the dictionary file at:\n%1$@",
                arguments: [url.path]
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
        refreshDictionaryStatus()
    }

    private func refreshDictionaryStatus() {
        if !DictionaryReplacer.fileExists {
            dictionaryStatus = L10n.string(
                "menu.dictionary.no_file",
                fallback: "No dictionary file"
            )
            return
        }
        let count = DictionaryReplacer.entryCount
        dictionaryStatus = L10n.plural(
            "menu.dictionary.entries_loaded",
            count,
            fallback: count == 1 ? "%1$ld entry loaded" : "%1$ld entries loaded"
        )
    }
}

struct DictationPane: View {
    @StateObject private var model: DictationSettingsModel

    init(onSwitchEngine: @escaping (AppConfig.DictationEngine) -> Void) {
        _model = StateObject(
            wrappedValue: DictationSettingsModel(onSwitchEngine: onSwitchEngine)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsGrid.rowSpacing) {
            SettingsRow(L10n.string("settings.dictation.engine_label", fallback: "Engine:")) {
                Picker("", selection: $model.engine) {
                    engineChoice(
                        title: L10n.string("menu.engine.local_qwen", fallback: "Local (Qwen3-ASR)"),
                        detail: L10n.string(
                            "settings.engine.local.detail",
                            fallback: "Private · Free · ~2.1 GB RAM (1 GB cache cap)"
                        )
                    )
                    .tag(AppConfig.DictationEngine.local)

                    engineChoice(
                        title: L10n.string("menu.engine.openai_cloud", fallback: "OpenAI Cloud"),
                        detail: L10n.format(
                            "settings.engine.cloud.detail",
                            "%1$@ · No model RAM",
                            arguments: [rateText(model.openAIRate)]
                        )
                    )
                    .tag(AppConfig.DictationEngine.openai)

                    engineChoice(
                        title: L10n.string("menu.engine.gemini_cloud", fallback: "Gemini Cloud"),
                        detail: L10n.format(
                            "settings.engine.gemini.detail",
                            "%1$@ · No model RAM",
                            arguments: [rateText(model.geminiRate)]
                        )
                    )
                    .tag(AppConfig.DictationEngine.gemini)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
            .padding(.bottom, 8)

            SettingsRow(L10n.string("settings.engine.openai_model", fallback: "OpenAI model:")) {
                Picker("", selection: $model.openAIModel) {
                    Text(L10n.string(
                        "settings.model.recommended",
                        fallback: "gpt-4o-mini-transcribe (recommended)"
                    )).tag("gpt-4o-mini-transcribe")
                    Text(L10n.string(
                        "settings.model.gpt_transcribe",
                        fallback: "gpt-transcribe"
                    )).tag("gpt-transcribe")
                }
                .labelsHidden()
                .disabled(model.engine != .openai)
            }

            SettingsRow(L10n.string("settings.engine.gemini_model", fallback: "Gemini model:")) {
                Picker("", selection: $model.geminiModel) {
                    Text(L10n.string(
                        "settings.model.quality",
                        fallback: "gemini-3.7-flash (quality)"
                    )).tag("gemini-3.7-flash")
                    Text(L10n.string(
                        "settings.model.budget",
                        fallback: "gemini-3.5-flash-lite (budget)"
                    )).tag("gemini-3.5-flash-lite")
                }
                .labelsHidden()
                .disabled(model.engine != .gemini)
            }
            .padding(.bottom, 8)

            SettingsRow {
                Text(L10n.string(
                    "settings.engine.cloud_unloads_local",
                    fallback: "Cloud dictation sends audio directly to the selected provider using your key. The local speech model stays unloaded."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()

            SettingsRow(L10n.string(
                "menu.speech_to_text_language",
                fallback: "Speech-to-Text Language:"
            )) {
                Picker("", selection: $model.speechLanguage) {
                    Text(L10n.string("menu.choice.auto", fallback: "Auto"))
                        .tag(nil as String?)
                    Text(L10n.string("picker.autonym.en", fallback: "English"))
                        .tag("english" as String?)
                    Text(L10n.string("picker.autonym.zh", fallback: "中文"))
                        .tag("chinese" as String?)
                    Text(L10n.string("picker.autonym.ja", fallback: "日本語"))
                        .tag("japanese" as String?)
                }
                .labelsHidden()
            }

            SettingsRow(L10n.string(
                "menu.number_conversion",
                fallback: "Number Conversion:"
            )) {
                Toggle(L10n.string(
                    "menu.number_conversion.subtitle",
                    fallback: "Chinese numerals → Arabic digits"
                ), isOn: $model.numberConversionEnabled)
            }

            SettingsRow(L10n.string(
                "menu.punctuation_cleanup",
                fallback: "Punctuation Cleanup:"
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $model.punctuationMode) {
                        Text(L10n.string(
                            "menu.punctuation.soft",
                            fallback: "Soft: trim inline commas"
                        )).tag(PunctuationMode.soft)
                        Text(L10n.string(
                            "menu.punctuation.hard",
                            fallback: "Hard: trim all marks"
                        )).tag(PunctuationMode.hard)
                        Text(L10n.string(
                            "menu.punctuation.off",
                            fallback: "Off: keep model output"
                        )).tag(PunctuationMode.off)
                    }
                    .labelsHidden()
                    Text(L10n.string(
                        "settings.dictation.punctuation.note",
                        fallback: "Trims the over-eager Chinese punctuation the model inserts on pauses. Chinese text only."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsDivider()

            SettingsRow(L10n.string(
                "settings.dictation.dictionary",
                fallback: "Customized Dictionary:"
            )) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppConfig.dictionaryFileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button(L10n.string(
                        "common.button.open_in_textedit",
                        fallback: "Open file in TextEdit"
                    )) {
                        model.openDictionary()
                    }
                    .buttonStyle(.bordered)
                    Text(model.dictionaryStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.string(
                        "settings.dictation.dictionary.note",
                        fallback: "One replacement per line. Applied after transcription, on every dictation engine including cloud."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsPaneLayout()
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hushTypeDictationEngineDidChange)) { _ in
            model.refresh()
        }
    }

    static func makeSettingsPane(
        onSwitchEngine: @escaping (AppConfig.DictationEngine) -> Void
    ) -> AppSettings.Pane<DictationPane> {
        let title = L10n.string("settings.tab.dictation", fallback: "Dictation")
        return AppSettings.Pane(
            identifier: .dictation,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "mic",
                accessibilityDescription: title
            )!
        ) {
            DictationPane(onSwitchEngine: onSwitchEngine)
        }
    }

    private func engineChoice(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rateText(_ rate: Double) -> String {
        L10n.format("format.usd_rate_per_minute", "$%1$.3f/min", arguments: [rate])
    }

}
