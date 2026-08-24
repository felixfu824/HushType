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

    private var isRefreshing = false
    private let onResetPanelFrame: () -> Void

    init(onResetPanelFrame: @escaping () -> Void) {
        self.onResetPanelFrame = onResetPanelFrame
        targetLanguage = AppConfig.shared.cloudTargetLanguage
        showSourceLine = AppConfig.shared.cloudShowSourceLine
        autoStopMinutes = AppConfig.shared.cloudAutoStopMinutes
    }

    func refresh() {
        isRefreshing = true
        targetLanguage = AppConfig.shared.cloudTargetLanguage
        showSourceLine = AppConfig.shared.cloudShowSourceLine
        autoStopMinutes = AppConfig.shared.cloudAutoStopMinutes
        isRefreshing = false
    }

    func openAdvancedTuning() {
        LiveCaptionTuning.createTemplateIfMissing()
        let url = LiveCaptionTuning.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = L10n.string(
                "alert.file_create.live_caption.title",
                fallback: "Could not open Live Caption settings"
            )
            alert.informativeText = L10n.format(
                "alert.file_create.live_caption.message",
                "Failed to create the Live Caption settings file at:\n%1$@",
                arguments: [url.path]
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }

    func resetPanelFrame() {
        onResetPanelFrame()
    }
}

struct CaptionPane: View {
    @StateObject private var model: CaptionSettingsModel

    init(onResetPanelFrame: @escaping () -> Void) {
        _model = StateObject(wrappedValue: CaptionSettingsModel(
            onResetPanelFrame: onResetPanelFrame
        ))
    }

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
        VStack(alignment: .leading, spacing: SettingsGrid.rowSpacing) {
            SettingsSectionHeader(
                title: L10n.string(
                    "settings.caption.panel_title",
                    fallback: "Caption Panel"
                ),
                subtitle: L10n.string(
                    "settings.caption.local_sub",
                    fallback: "Shared by both caption modes. Local caption runs on Qwen3: free, nothing leaves the Mac."
                )
            )

            SettingsRow {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string(
                        "settings.caption.panel_size",
                        fallback: "Drag or resize the caption panel; HushType remembers its size and position automatically."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Button(L10n.string(
                        "settings.caption.reset_position",
                        fallback: "Reset Size & Position"
                    )) {
                        model.resetPanelFrame()
                    }
                    .buttonStyle(.bordered)
                }
            }

            SettingsRow(L10n.string(
                "settings.caption.advanced",
                fallback: "Advanced tuning:"
            )) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(LiveCaptionTuning.fileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button(L10n.string(
                        "common.button.open_in_textedit",
                        fallback: "Open file in TextEdit"
                    )) {
                        model.openAdvancedTuning()
                    }
                    .buttonStyle(.bordered)
                    Text(L10n.string(
                        "settings.caption.advanced.note",
                        fallback: "VAD thresholds, maxTokens and the MLX cache cap stay in the file, out of the UI."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsDivider()

            SettingsSectionHeader(
                title: L10n.string(
                    "menu.live_translated_caption",
                    fallback: "Live Translated Caption"
                ),
                subtitle: L10n.string(
                    "settings.caption.cloud_sub",
                    fallback: "OpenAI realtime · ~$2/hour · these three settings apply to translated caption only"
                )
            )

            SettingsRow(L10n.string(
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

            SettingsRow {
                Toggle(L10n.string(
                    "settings.translated_caption.show_source",
                    fallback: "Show source text above translation"
                ), isOn: $model.showSourceLine)
            }

            SettingsRow(L10n.string(
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
            .padding(.bottom, 8)

            SettingsRow {
                Text(L10n.string(
                    "settings.caption.note",
                    fallback: "Audio streams Mac → OpenAI directly; HushType is never in the middle. Spend counts against the daily cap on the Cloud tab."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPaneLayout()
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    static func makeSettingsPane(
        onResetPanelFrame: @escaping () -> Void
    ) -> AppSettings.Pane<CaptionPane> {
        let title = L10n.string("settings.tab.caption", fallback: "Caption")
        return AppSettings.Pane(
            identifier: .caption,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "captions.bubble",
                accessibilityDescription: title
            )!
        ) {
            CaptionPane(onResetPanelFrame: onResetPanelFrame)
        }
    }

}
