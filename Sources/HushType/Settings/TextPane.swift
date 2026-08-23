import AppKit
import Settings
import SwiftUI

struct TextPane: View {
    @ObservedObject private var model: TextSettingsModel

    init() {
        self.model = .shared
    }

    init(model: TextSettingsModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(
                title: L10n.string("settings.text.polish_title", fallback: "Text Polish"),
                subtitle: L10n.string(
                    "settings.text.polish_sub",
                    fallback: "Apple Foundation Models · on-device"
                )
            )

            SettingsRow {
                Toggle(
                    L10n.string(
                        "settings.text.polish.cb",
                        fallback: "Proofread selection on double-tap Right ⌥"
                    ),
                    isOn: Binding(
                        get: { model.polishEnabled },
                        set: { model.requestPolishEnabled($0) }
                    )
                )
                .disabled(model.isValidatingPolish || (!model.polishAvailable && !model.polishEnabled))
            }

            SettingsRow(L10n.string("settings.text.instructions", fallback: "Polish instructions:")) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(L10n.string("common.button.open_in_textedit", fallback: "Open in TextEdit")) {
                        model.editPolishInstructions()
                    }
                    Text(L10n.string(
                        "settings.text.instructions.note",
                        fallback: "Plain-text instructions sent with every proofread request."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().padding(.vertical, 10)

            SettingsSectionHeader(
                title: L10n.string("menu.text_translation", fallback: "Text Translation"),
                subtitle: L10n.string(
                    "settings.text.translation_sub",
                    fallback: "Apple Translation Framework · on-device"
                )
            )

            SettingsRow {
                Toggle(
                    L10n.string(
                        "settings.text.translation.cb",
                        fallback: "Translate selection on tap Right ⌥"
                    ),
                    isOn: Binding(
                        get: { model.translationEnabled },
                        set: { model.setTranslationEnabled($0) }
                    )
                )
            }

            SettingsRow(L10n.string("settings.text.translate_to", fallback: "Translate to:")) {
                Picker(
                    "",
                    selection: Binding(
                        get: { model.translationTarget },
                        set: { model.setTranslationTarget($0) }
                    )
                ) {
                    ForEach(Self.translationTargets, id: \.value) { choice in
                        Text(choice.title).tag(choice.value)
                    }
                }
                .labelsHidden()
                .disabled(!model.translationEnabled)
            }

            SettingsRow {
                Text(L10n.string(
                    "settings.text.note",
                    fallback: "Auto picks the opposite of the detected language. Both features share the Right ⌥ key: one tap translates, two taps proofread."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 20)
        .frame(width: 720)
        .onAppear { model.refreshFromConfig() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFromConfig(polishAvailability: TextPolisher.isAvailableCached)
        }
    }

    static func makeSettingsPane() -> AppSettings.Pane<TextPane> {
        let title = L10n.string("settings.tab.text", fallback: "Text")
        return AppSettings.Pane(
            identifier: .text,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "textformat",
                accessibilityDescription: title
            )!
        ) {
            TextPane(model: .shared)
        }
    }

    private static var translationTargets: [(title: String, value: String?)] {
        [
            (L10n.string("menu.choice.auto", fallback: "Auto"), nil),
            (L10n.string("picker.autonym.en", fallback: "English"), "en"),
            ("繁體中文", "zh-Hant-TW"),
            (L10n.string("picker.autonym.ja", fallback: "日本語"), "ja"),
            (L10n.string("picker.autonym.ko", fallback: "한국어"), "ko"),
            (L10n.string("picker.autonym.fr", fallback: "Français"), "fr"),
            (L10n.string("picker.autonym.de", fallback: "Deutsch"), "de"),
            (L10n.string("picker.autonym.es", fallback: "Español"), "es"),
        ]
    }

}
