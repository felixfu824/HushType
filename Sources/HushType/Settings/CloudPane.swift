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

    func confirmAndResetCounter() {
        let alert = Self.makeResetCounterAlert()
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        resetCounter()
    }

    static func makeResetCounterAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.cloud.reset_counter.title",
            fallback: "Reset today's usage counter?"
        )
        alert.informativeText = L10n.string(
            "alert.cloud.reset_counter.message",
            fallback: "This resets only Lamitype's estimate of today's cloud usage. It does not change usage or charges reported by OpenAI or Gemini. Cloud uploads will be allowed again today."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        alert.addButton(withTitle: L10n.string(
            "alert.cloud.reset_counter.confirm",
            fallback: "Reset Counter"
        ))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[1].hasDestructiveAction = true
        return alert
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
        VStack(alignment: .leading, spacing: SettingsGrid.rowSpacing) {
            SettingsRow(L10n.string("settings.cloud.cap", fallback: "Daily spend cap:")) {
                Stepper(value: Binding(
                    get: { model.dailyCap },
                    set: { model.dailyCap = max(0.5, min(100.0, $0)) }
                ), in: 0.5...100.0, step: 0.5) {
                    Text(CloudUsageTracker.formatDollars(model.dailyCap))
                        .monospacedDigit()
                }
            }

            SettingsRow {
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
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            SettingsRow {
                VStack(alignment: .leading, spacing: 5) {
                    if !model.usageLine.isEmpty {
                        Text(model.usageLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(L10n.string(
                        "common.button.reset_counter",
                        fallback: "Reset today's counter…"
                    )) {
                        model.confirmAndResetCounter()
                    }
                    .buttonStyle(.bordered)
                }
            }

            SettingsDivider()

            keyRow(
                label: L10n.string("settings.cloud.key.openai", fallback: "OpenAI key:"),
                path: OpenAIKeyStore.displayPath,
                status: model.openAIKeyStatus,
                provider: .openai
            )
            .padding(.bottom, 8)

            keyRow(
                label: L10n.string("settings.cloud.key.gemini", fallback: "Gemini key:"),
                path: GeminiKeyStore.displayPath,
                status: model.geminiKeyStatus,
                provider: .gemini
            )
            .padding(.bottom, 8)

            SettingsRow {
                Text(L10n.string(
                    "settings.cloud.key.note",
                    fallback: "Keys stay in local files and are used only for direct requests to each provider. An empty key disables that provider."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPaneLayout()
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
                .frame(width: 96, alignment: .leading)
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
        SettingsRow(label) {
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
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

}
