import SwiftUI
import AppKit

/// View-model mirror of the cloud-relevant AppConfig fields. Holds in-memory
/// state during the Settings session and writes back to AppConfig on every
/// edit so the next Live Translated Caption start picks up the values.
///
/// Previously this also owned the local-vs-cloud engine picker; that was
/// removed when the product split landed (engine is now implied by which
/// menu the user invoked — Live Caption vs Live Translated Caption).
@MainActor
final class LiveCaptionEngineSettingsModel: ObservableObject {
    @Published var targetLanguage: String {
        didSet { AppConfig.shared.cloudTargetLanguage = targetLanguage }
    }
    @Published var showSourceLine: Bool {
        didSet { AppConfig.shared.cloudShowSourceLine = showSourceLine }
    }
    @Published var autoStopMinutes: Int {
        didSet { AppConfig.shared.cloudAutoStopMinutes = autoStopMinutes }
    }
    @Published var dailyCapDollars: Double {
        didSet { AppConfig.shared.cloudDailyCapDollars = dailyCapDollars }
    }

    @Published var keyStatusLine: String = ""
    @Published var todayUsageLine: String = ""

    init() {
        self.targetLanguage = AppConfig.shared.cloudTargetLanguage
        self.showSourceLine = AppConfig.shared.cloudShowSourceLine
        self.autoStopMinutes = AppConfig.shared.cloudAutoStopMinutes
        self.dailyCapDollars = AppConfig.shared.cloudDailyCapDollars
        refreshDerived()
    }

    /// Re-read derived display fields (key status, today's usage). Called on
    /// view appear and after Reset counter.
    func refreshDerived() {
        let status = OpenAIKeyStore.load()
        switch status {
        case .ok:
            keyStatusLine = "✓ Key loaded"
        case .empty:
            keyStatusLine = "Key empty — cloud features disabled"
        case .unusualFormat:
            keyStatusLine = "Key format unusual (does not start with sk-) — passing through anyway"
        }
        // Today's usage is async; kick off a refresh and update when it lands.
        Task { [weak self] in
            let snap = await CloudUsageTracker.shared.snapshot()
            await MainActor.run {
                self?.todayUsageLine = String(
                    format: "Today's usage: %@ (%d min)",
                    CloudUsageTracker.formatDollars(snap.dayDollars),
                    Int(snap.sessionSeconds / 60.0)
                )
            }
        }
    }

    func resetCounter() {
        Task { [weak self] in
            await CloudUsageTracker.shared.resetDailyCounter()
            await MainActor.run { self?.refreshDerived() }
        }
    }

    func resetToDefaults() {
        autoStopMinutes = 60
        dailyCapDollars = 5.0
    }
}

struct LiveCaptionEngineSettingsView: View {
    @StateObject private var model = LiveCaptionEngineSettingsModel()

    private static let targetLanguages: [(value: String, label: String)] = [
        ("en", "English"),
        ("zh-Hant", "繁體中文"),
        ("zh-Hans", "简体中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("es", "Español"),
        ("pt", "Português"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("ru", "Русский"),
        ("hi", "हिन्दी"),
        ("id", "Bahasa Indonesia"),
        ("vi", "Tiếng Việt"),
        ("it", "Italiano"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            Divider().padding(.vertical, 12)
            sectionCloudOptions
            Divider().padding(.vertical, 12)
            sectionGuardrails
            Divider().padding(.vertical, 12)
            sectionAPIKey
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, alignment: .topLeading)
        .onAppear { model.refreshDerived() }
    }

    // MARK: - Sections

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Live Translated Caption", systemImage: "globe")
                .font(.headline)
            Text("Real-time cloud translation via OpenAI's realtime translate endpoint. Audio streams Mac → OpenAI directly; HushType is never in the middle. Costs ~$2/hour against your own OpenAI API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionCloudOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Translation options", systemImage: "captions.bubble")
                .font(.headline)

            HStack {
                Text("Target language:")
                Picker("", selection: $model.targetLanguage) {
                    ForEach(Self.targetLanguages, id: \.value) { lang in
                        Text(lang.label).tag(lang.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            Toggle("Show source text above translation", isOn: $model.showSourceLine)
        }
    }

    private var sectionGuardrails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Cost guardrails", systemImage: "dollarsign.circle")
                .font(.headline)

            HStack {
                Text("Auto-stop session after:")
                Stepper(value: Binding(
                    get: { model.autoStopMinutes },
                    set: { model.autoStopMinutes = max(5, min(480, $0)) }
                ), in: 5...480, step: 5) {
                    Text("\(model.autoStopMinutes) min")
                        .frame(minWidth: 60, alignment: .trailing)
                        .monospacedDigit()
                }
            }

            HStack {
                Text("Warn me when daily spend hits:")
                Stepper(value: Binding(
                    get: { model.dailyCapDollars },
                    set: { model.dailyCapDollars = max(0.5, min(100.0, $0)) }
                ), in: 0.5...100.0, step: 0.5) {
                    Text(CloudUsageTracker.formatDollars(model.dailyCapDollars))
                        .frame(minWidth: 60, alignment: .trailing)
                        .monospacedDigit()
                }
            }

            HStack {
                Text(model.todayUsageLine.isEmpty ? "Today's usage: —" : model.todayUsageLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset counter") { model.resetCounter() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Reset to defaults") { model.resetToDefaults() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var sectionAPIKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("API key", systemImage: "key.fill")
                .font(.headline)

            Text(OpenAIKeyStore.displayPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button("Open file in TextEdit") {
                    OpenAIKeyStore.openInDefaultEditor()
                    // After the user edits, refresh status when they return
                    // to settings.
                    model.refreshDerived()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }

            Text(model.keyStatusLine.isEmpty ? "Status: —" : "Status: \(model.keyStatusLine)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
