import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by the Settings view-model when the user flips the engine
    /// picker. AppDelegate observes and calls `LiveCaptionManager.switchEngine`
    /// if a session is currently active. Otherwise the change is purely
    /// preferential and the next start() picks up the new engine.
    static let hushtypeLiveCaptionEngineChanged = Notification.Name("hushtype.liveCaptionEngineChanged")
}

/// View-model mirror of the cloud-relevant AppConfig fields. Holds in-memory
/// state during the Settings session and writes back to AppConfig on every
/// edit so the next Live Caption start picks up the values. `engine` is
/// session-only on `AppConfig` (resets to `.local` per app launch), so we
/// store it here too and keep both in sync.
@MainActor
final class LiveCaptionEngineSettingsModel: ObservableObject {
    @Published var engine: AppConfig.LiveCaptionEngine {
        didSet {
            AppConfig.shared.liveCaptionEngine = engine
            // Notify AppDelegate so it can swap the engine mid-session if
            // Live Caption is currently active. If not active, the next
            // start() picks up the new value naturally.
            NotificationCenter.default.post(
                name: .hushtypeLiveCaptionEngineChanged,
                object: nil,
                userInfo: ["engine": engine.rawValue]
            )
        }
    }
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
        self.engine = AppConfig.shared.liveCaptionEngine
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
            sectionEngine
            Divider().padding(.vertical, 12)
            sectionCloudOptions
                .disabled(model.engine != .cloudTranslate)
                .opacity(model.engine != .cloudTranslate ? 0.55 : 1.0)
            Divider().padding(.vertical, 12)
            sectionGuardrails
                .disabled(model.engine != .cloudTranslate)
                .opacity(model.engine != .cloudTranslate ? 0.55 : 1.0)
            Divider().padding(.vertical, 12)
            sectionAPIKey
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, alignment: .topLeading)
        .onAppear { model.refreshDerived() }
    }

    // MARK: - Sections

    private var sectionEngine: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live Caption Engine", systemImage: "captions.bubble")
                .font(.headline)
            Picker("", selection: Binding(
                get: { model.engine },
                set: { newValue in
                    if newValue == .cloudTranslate && model.engine != .cloudTranslate {
                        // Show pre-session disclosure the first time.
                        let accepted = CloudOnboardingAlert.presentIfNeeded()
                        if accepted {
                            model.engine = .cloudTranslate
                        } else {
                            // User cancelled — revert by no-op (binding will
                            // re-read .local on next pass).
                            model.objectWillChange.send()
                        }
                    } else {
                        model.engine = newValue
                    }
                }
            )) {
                Text("Local (Qwen3) — private, free")
                    .tag(AppConfig.LiveCaptionEngine.local)
                Text("Cloud Translate (OpenAI) — ~$2/hour")
                    .tag(AppConfig.LiveCaptionEngine.cloudTranslate)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Cloud resets to Local on every app launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sectionCloudOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Cloud Translate options", systemImage: "globe")
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
