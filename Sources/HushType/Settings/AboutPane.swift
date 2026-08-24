import AppKit
import Settings
import SwiftUI

struct AboutPane: View {
    let onCheckForUpdates: () -> Void

    static let coauthors = [
        "Claude (Anthropic)",
        "Codex (OpenAI)",
        "Pi (Qwen 3.8 27B)",
    ]

    private static let repositoryURL = URL(string: "https://github.com/felixfu824/HushType")!

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsGrid.rowSpacing) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("HushType")
                        .font(.title2.bold())
                    Text(versionAndBuild)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(productDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: SettingsGrid.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)

            SettingsDivider()

            SettingsRow(L10n.string(
                "settings.about.author",
                fallback: "Author:"
            )) {
                Text("Felix Fu")
            }

            SettingsRow(L10n.string(
                "settings.about.coauthors",
                fallback: "Co-authors:"
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Self.coauthors, id: \.self) { coauthor in
                        Text(coauthor)
                    }
                }
            }

            SettingsRow(L10n.string(
                "settings.about.license",
                fallback: "License:"
            )) {
                Text("MIT")
            }

            SettingsRow(L10n.string(
                "settings.about.repository",
                fallback: "Repository:"
            )) {
                Link("github.com/felixfu824/HushType", destination: Self.repositoryURL)
            }

            SettingsDivider()

            SettingsRow {
                Button(L10n.string(
                    "about.check_updates",
                    fallback: "Check for Updates"
                )) {
                    onCheckForUpdates()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .settingsPaneLayout()
    }

    static func makeSettingsPane(
        onCheckForUpdates: @escaping () -> Void
    ) -> AppSettings.Pane<AboutPane> {
        let title = L10n.string("settings.tab.about", fallback: "About")
        return AppSettings.Pane(
            identifier: .about,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "info.circle",
                accessibilityDescription: title
            )!
        ) {
            AboutPane(onCheckForUpdates: onCheckForUpdates)
        }
    }

    private var versionAndBuild: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        return L10n.format(
            "settings.about.version_build",
            "Version %1$@ (Build %2$@)",
            arguments: [version, build]
        )
    }

    private var productDescription: String {
        L10n.string(
            "about.body",
            fallback: "Local voice-to-text for macOS and iOS.\nMultilingual (EN/ZH/JP) with Traditional Chinese output."
        )
    }
}
