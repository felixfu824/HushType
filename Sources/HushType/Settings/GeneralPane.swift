import AppKit
import Settings
import SwiftUI

@MainActor
final class GeneralSettingsModel: NSObject, ObservableObject {
    @Published private(set) var selectedLanguage: InterfaceLanguage
    @Published private(set) var appliedNextLaunchVisible: Bool
    @Published var floatingIndicatorEnabled: Bool {
        didSet { AppConfig.shared.floatingOverlayEnabled = floatingIndicatorEnabled }
    }

    private let launchInterfaceLanguage: InterfaceLanguage

    override init() {
        let launchPreference = L10n.launchPreference
        let persistedLanguage = AppConfig.shared.interfaceLanguage
        launchInterfaceLanguage = launchPreference
        selectedLanguage = persistedLanguage
        appliedNextLaunchVisible = Self.shouldShowAppliedNextLaunch(
            persisted: persistedLanguage,
            launch: launchPreference
        )
        floatingIndicatorEnabled = AppConfig.shared.floatingOverlayEnabled
        super.init()
    }

    func selectInterfaceLanguage(_ language: InterfaceLanguage) {
        let sender = NSMenuItem()
        sender.representedObject = language.rawValue
        interfaceLanguageSelected(sender)
    }

    @objc private func interfaceLanguageSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selected = InterfaceLanguage(rawValue: rawValue),
              selected != AppConfig.shared.interfaceLanguage else {
            return
        }

        AppConfig.shared.interfaceLanguage = selected
        selectedLanguage = selected
        appliedNextLaunchVisible = Self.shouldShowAppliedNextLaunch(
            persisted: selected,
            launch: launchInterfaceLanguage
        )
        Self.makeLanguageSavedAlert().runModal()
    }

    static func makeLanguageSavedAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.string("alert.language_saved.title", fallback: "Language Saved")
        alert.informativeText = L10n.string(
            "alert.language_saved.message",
            fallback: "It will be used the next time you open HushType. Finish any active work before quitting."
        )
        alert.alertStyle = .informational
        alert.icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        return alert
    }

    static func shouldShowAppliedNextLaunch(
        persisted: InterfaceLanguage,
        launch: InterfaceLanguage
    ) -> Bool {
        persisted != launch
    }
}

struct GeneralPane: View {
    @StateObject private var model = GeneralSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsGrid.rowSpacing) {
            SettingsRow(L10n.string(
                "settings.general.language",
                fallback: "Interface Language:"
            )) {
                Picker("", selection: Binding(
                    get: { model.selectedLanguage },
                    set: { model.selectInterfaceLanguage($0) }
                )) {
                    Text(followSystemLabel).tag(InterfaceLanguage.system)
                    Text(L10n.string(
                        "menu.interface_language.english",
                        fallback: "English"
                    )).tag(InterfaceLanguage.english)
                    Text(L10n.string(
                        "menu.interface_language.traditional_chinese_taiwan",
                        fallback: "繁體中文（台灣）"
                    )).tag(InterfaceLanguage.traditionalChineseTaiwan)
                }
                .labelsHidden()
                .help(L10n.string(
                    "menu.interface_language.applied_next_launch.accessibility",
                    fallback: "Language applies the next time you open HushType"
                ))
            }

            SettingsRow {
                Text(L10n.string(
                    "menu.interface_language.applied_next_launch",
                    fallback: "Applied Next Launch"
                ))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.14)))
                .opacity(model.appliedNextLaunchVisible ? 1 : 0)
                .accessibilityHidden(!model.appliedNextLaunchVisible)
            }

            SettingsRow {
                Text(L10n.string(
                    "settings.general.language.note",
                    fallback: "Applied next launch. Menu bar, settings and the caption panel all follow this."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()

            SettingsRow(L10n.string(
                "settings.general.indicator",
                fallback: "Indicator:"
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.string(
                        "menu.floating_indicator",
                        fallback: "Show floating indicator"
                    ), isOn: $model.floatingIndicatorEnabled)
                    Text(L10n.string(
                        "settings.general.indicator.note",
                        fallback: "The small \"Listening / Transcribing\" pill near the bottom of the screen."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsPaneLayout()
    }

    static func makeSettingsPane() -> AppSettings.Pane<GeneralPane> {
        let title = L10n.string("settings.tab.general", fallback: "General")
        return AppSettings.Pane(
            identifier: .general,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "gearshape",
                accessibilityDescription: title
            )!
        ) {
            GeneralPane()
        }
    }

    private var followSystemLabel: String {
        let systemTag = InterfaceLocale.effectiveTag(
            preferences: InterfaceLocale.processPreferredTags
        )
        let systemLanguageNames = [
            "en": "English",
            "zh-Hant-TW": "繁體中文（台灣）",
        ]
        guard let effectiveName = systemLanguageNames[systemTag] else {
            return L10n.string(
                "menu.interface_language.follow_system",
                fallback: "Follow System"
            )
        }
        return L10n.format(
            "settings.general.language.value",
            "Follow System (%1$@)",
            arguments: [effectiveName]
        )
    }
}
