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

    private let onSwitchEngine: (AppConfig.DictationEngine) -> Void

    init(onSwitchEngine: @escaping (AppConfig.DictationEngine) -> Void) {
        self.onSwitchEngine = onSwitchEngine
        engine = AppConfig.shared.dictationEngine
        openAIModel = AppConfig.shared.cloudDictationModelOpenAI
        geminiModel = AppConfig.shared.cloudDictationModelGemini
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
        VStack(alignment: .leading, spacing: 8) {
            settingsRow(L10n.string("settings.dictation.engine_label", fallback: "Engine:")) {
                Picker("", selection: $model.engine) {
                    engineChoice(
                        title: L10n.string("menu.engine.local_qwen", fallback: "Local (Qwen3-ASR)"),
                        detail: L10n.string(
                            "settings.engine.local.detail",
                            fallback: "Private · Free · ~2.1 GB RAM when loaded (1 GB cache cap)"
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

            settingsRow(L10n.string("settings.engine.openai_model", fallback: "OpenAI model:")) {
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

            settingsRow(L10n.string("settings.engine.gemini_model", fallback: "Gemini model:")) {
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

            settingsRow("") {
                Text(L10n.string(
                    "settings.engine.cloud_unloads_local",
                    fallback: "While a cloud engine is selected the speech model stays unloaded. The iOS companion server always uses the local model."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 20)
        .frame(width: 720)
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

    private func settingsRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .frame(width: 170, alignment: .trailing)
            content()
                .frame(width: 300, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
