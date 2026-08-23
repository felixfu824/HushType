import AppKit
import Settings
import SwiftUI

@MainActor
final class CloudSettingsModel: ObservableObject {
    @Published var dailyCap: Double {
        didSet { AppConfig.shared.cloudDailyCapDollars = dailyCap }
    }

    @Published var usageLine = ""
    @Published var openAIKeyStatus = L10n.string(
        "settings.key.status.placeholder",
        fallback: "Status: Not loaded yet"
    )
    @Published var geminiKeyStatus = L10n.string(
        "settings.key.status.placeholder",
        fallback: "Status: Not loaded yet"
    )

    init() {
        dailyCap = AppConfig.shared.cloudDailyCapDollars
    }

    func refreshDerived() {
        dailyCap = AppConfig.shared.cloudDailyCapDollars
        openAIKeyStatus = Self.openAIStatusLine(OpenAIKeyStore.load())
        geminiKeyStatus = Self.geminiStatusLine(GeminiKeyStore.load())
        Task { [weak self] in
            let snapshot = await CloudUsageTracker.shared.snapshot()
            await MainActor.run {
                self?.usageLine = CloudUsageTracker.formatDailyBreakdown(snapshot)
            }
        }
    }

    func resetCounter() {
        Task { [weak self] in
            await CloudUsageTracker.shared.resetDailyCounter()
            await MainActor.run { self?.refreshDerived() }
        }
    }

    func resetCloudCostSettings() {
        AppConfig.shared.cloudAutoStopMinutes = 60
        dailyCap = 5.0
    }

    func openKeyFile(provider: CloudUsageTracker.Provider) {
        switch provider {
        case .openai:
            OpenAIKeyStore.openInDefaultEditor()
        case .gemini:
            GeminiKeyStore.openInDefaultEditor()
        }
    }

    private static func openAIStatusLine(_ status: OpenAIKeyStore.LoadStatus) -> String {
        switch status {
        case .ok:
            L10n.string("settings.key.status.loaded", fallback: "Status: ✓ Key loaded")
        case .empty:
            L10n.string(
                "settings.key.status.openai_empty",
                fallback: "Status: Key empty; OpenAI cloud features disabled"
            )
        case .unusualFormat:
            L10n.string(
                "settings.key.status.unusual",
                fallback: "Status: Key format unusual; passing through anyway"
            )
        }
    }

    private static func geminiStatusLine(_ status: GeminiKeyStore.LoadStatus) -> String {
        switch status {
        case .ok:
            L10n.string("settings.key.status.loaded", fallback: "Status: ✓ Key loaded")
        case .empty:
            L10n.string(
                "settings.key.status.gemini_empty",
                fallback: "Status: Key empty; Gemini cloud dictation disabled"
            )
        case .unusualFormat:
            L10n.string(
                "settings.key.status.unusual",
                fallback: "Status: Key format unusual; passing through anyway"
            )
        }
    }
}

struct CloudPane: View {
    @StateObject private var model = CloudSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsRow(L10n.string("settings.cloud.cap", fallback: "Daily spend cap:")) {
                Stepper(value: Binding(
                    get: { model.dailyCap },
                    set: { model.dailyCap = max(0.5, min(100.0, $0)) }
                ), in: 0.5...100.0, step: 0.5) {
                    Text(CloudUsageTracker.formatDollars(model.dailyCap))
                        .monospacedDigit()
                }
            }

            settingsRow("") {
                VStack(alignment: .leading, spacing: 8) {
                    effectRow(
                        title: L10n.string("settings.tab.dictation", fallback: "Dictation"),
                        detail: L10n.string(
                            "settings.cloud.effect.dictation",
                            fallback: "Stops uploading at the cap. No further cloud requests that day."
                        )
                    )
                    effectRow(
                        title: L10n.string("settings.tab.caption", fallback: "Caption"),
                        detail: L10n.string(
                            "settings.cloud.effect.caption",
                            fallback: "Notifies at the cap. The running session is not interrupted."
                        )
                    )
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            settingsRow("") {
                VStack(alignment: .leading, spacing: 5) {
                    if !model.usageLine.isEmpty {
                        Text(model.usageLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(L10n.string("common.button.reset_counter", fallback: "Reset counter")) {
                        model.resetCounter()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            settingsRow("") {
                VStack(alignment: .leading, spacing: 4) {
                    Button(L10n.string(
                        "settings.reset_defaults",
                        fallback: "Reset cloud cost settings"
                    )) {
                        model.resetCloudCostSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text(L10n.string(
                        "settings.cloud.reset_cost.note",
                        fallback: "Resets translated-caption auto-stop to 60 minutes and the daily spend cap to $5.00. Other settings are unchanged."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
                .frame(width: 476)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)

            keyRow(
                label: L10n.string("settings.cloud.key.openai", fallback: "OpenAI key:"),
                path: OpenAIKeyStore.displayPath,
                status: model.openAIKeyStatus,
                provider: .openai
            )

            keyRow(
                label: L10n.string("settings.cloud.key.gemini", fallback: "Gemini key:"),
                path: GeminiKeyStore.displayPath,
                status: model.geminiKeyStatus,
                provider: .gemini
            )

            settingsRow("") {
                Text(L10n.string(
                    "settings.cloud.key.note",
                    fallback: "Before loading, status shows a placeholder. Loaded and unusual-format status are shared. Empty OpenAI disables OpenAI cloud features; empty Gemini disables Gemini cloud dictation."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 20)
        .frame(width: 720)
        .onAppear { model.refreshDerived() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshDerived()
        }
    }

    static func makeSettingsPane() -> AppSettings.Pane<CloudPane> {
        let title = L10n.string("settings.tab.cloud", fallback: "Cloud")
        return AppSettings.Pane(
            identifier: .cloud,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "dollarsign.circle",
                accessibilityDescription: title
            )!
        ) {
            CloudPane()
        }
    }

    private func effectRow(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .frame(width: 64, alignment: .leading)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keyRow(
        label: String,
        path: String,
        status: String,
        provider: CloudUsageTracker.Provider
    ) -> some View {
        settingsRow(label) {
            VStack(alignment: .leading, spacing: 5) {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button(L10n.string(
                    "common.button.open_in_textedit",
                    fallback: "Open file in TextEdit"
                )) {
                    model.openKeyFile(provider: provider)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
