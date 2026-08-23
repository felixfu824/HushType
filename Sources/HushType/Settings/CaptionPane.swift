import AppKit
import Settings
import SwiftUI

@MainActor
final class CaptionSettingsModel: ObservableObject {
    @Published var targetLanguage: String {
        didSet { AppConfig.shared.cloudTargetLanguage = targetLanguage }
    }

    @Published var showSourceLine: Bool {
        didSet { AppConfig.shared.cloudShowSourceLine = showSourceLine }
    }

    @Published var autoStopMinutes: Int {
        didSet { AppConfig.shared.cloudAutoStopMinutes = autoStopMinutes }
    }

    init() {
        targetLanguage = AppConfig.shared.cloudTargetLanguage
        showSourceLine = AppConfig.shared.cloudShowSourceLine
        autoStopMinutes = AppConfig.shared.cloudAutoStopMinutes
    }

    func refresh() {
        targetLanguage = AppConfig.shared.cloudTargetLanguage
        showSourceLine = AppConfig.shared.cloudShowSourceLine
        autoStopMinutes = AppConfig.shared.cloudAutoStopMinutes
    }
}

struct CaptionPane: View {
    @StateObject private var model = CaptionSettingsModel()

    private static var targetLanguages: [(value: String, label: String)] {[
        ("en", L10n.string("picker.autonym.en", fallback: "English")),
        ("zh-Hant", L10n.string("picker.target.traditional_chinese_autonym", fallback: "繁體中文")),
        ("zh-Hans", L10n.string("picker.target.simplified_chinese_autonym", fallback: "简体中文")),
        ("ja", L10n.string("picker.autonym.ja", fallback: "日本語")),
        ("ko", L10n.string("picker.autonym.ko", fallback: "한국어")),
        ("es", L10n.string("picker.autonym.es", fallback: "Español")),
        ("pt", L10n.string("picker.autonym.pt", fallback: "Português")),
        ("fr", L10n.string("picker.autonym.fr", fallback: "Français")),
        ("de", L10n.string("picker.autonym.de", fallback: "Deutsch")),
        ("ru", L10n.string("picker.autonym.ru", fallback: "Русский")),
        ("hi", L10n.string("picker.autonym.hi", fallback: "हिन्दी")),
        ("id", L10n.string("picker.autonym.id", fallback: "Bahasa Indonesia")),
        ("vi", L10n.string("picker.autonym.vi", fallback: "Tiếng Việt")),
        ("it", L10n.string("picker.autonym.it", fallback: "Italiano")),
    ]}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(
                    "menu.live_translated_caption",
                    fallback: "Live Translated Caption"
                ))
                .font(.headline)
                Text(L10n.string(
                    "settings.caption.cloud_sub",
                    fallback: "OpenAI realtime · ~$2/hour · these three settings apply to translated caption only"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(width: 476, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)

            settingsRow(L10n.string(
                "settings.translated_caption.target",
                fallback: "Target language:"
            )) {
                Picker("", selection: $model.targetLanguage) {
                    ForEach(Self.targetLanguages, id: \.value) { language in
                        Text(language.label).tag(language.value)
                    }
                }
                .labelsHidden()
            }

            settingsRow("") {
                Toggle(L10n.string(
                    "settings.translated_caption.show_source",
                    fallback: "Show source text above translation"
                ), isOn: $model.showSourceLine)
            }

            settingsRow(L10n.string(
                "settings.cost_guardrails.auto_stop",
                fallback: "Auto-stop session after:"
            )) {
                Stepper(value: Binding(
                    get: { model.autoStopMinutes },
                    set: { model.autoStopMinutes = max(5, min(480, $0)) }
                ), in: 5...480, step: 5) {
                    Text(L10n.plural(
                        "settings.duration.minutes",
                        count: model.autoStopMinutes,
                        fallback: "%1$d min",
                        arguments: [Int32(model.autoStopMinutes)]
                    ))
                    .monospacedDigit()
                }
            }

            settingsRow("") {
                Text(L10n.string(
                    "settings.caption.note",
                    fallback: "Audio streams Mac → OpenAI directly; HushType is never in the middle. Spend counts against the daily cap on the Cloud tab."
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
    }

    static func makeSettingsPane() -> AppSettings.Pane<CaptionPane> {
        let title = L10n.string("settings.tab.caption", fallback: "Caption")
        return AppSettings.Pane(
            identifier: .caption,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "captions.bubble",
                accessibilityDescription: title
            )!
        ) {
            CaptionPane()
        }
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
