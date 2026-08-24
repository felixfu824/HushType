import AppKit
import Settings
import SwiftUI

extension Notification.Name {
    static let iosServerStatusDidChange = Notification.Name(
        "com.felix.hushtype.iosServerStatusDidChange"
    )
}

struct IOSServerPane: View {
    static let runningUserInfoKey = "isRunning"

    private let onToggle: () -> Void
    private let isRunningProvider: () -> Bool
    @State private var isRunning: Bool

    init(onToggle: @escaping () -> Void, isRunning: @escaping () -> Bool) {
        self.onToggle = onToggle
        isRunningProvider = isRunning
        _isRunning = State(initialValue: isRunning())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsGrid.rowSpacing) {
            SettingsSectionHeader(
                title: L10n.string(
                    "settings.ios.title",
                    fallback: "iOS Server · Untested"
                ),
                subtitle: L10n.string(
                    "settings.ios.subtitle",
                    fallback: "An experimental companion feature that has not been maintained or tested recently."
                )
            )

            SettingsRow(L10n.string("settings.ios.status", fallback: "Status:")) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isRunning ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                    Text(isRunning
                        ? L10n.string("settings.ios.status.running", fallback: "Running on port 8000")
                        : L10n.string("settings.ios.status.stopped", fallback: "Stopped"))
                }
            }

            SettingsRow {
                Button(isRunning
                    ? L10n.string("settings.ios.stop", fallback: "Stop iOS Server")
                    : L10n.string("settings.ios.start", fallback: "Start iOS server (untested)")) {
                    onToggle()
                }
                .buttonStyle(.borderedProminent)
            }

            SettingsDivider()

            SettingsRow {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.string(
                        "settings.ios.local_model_note",
                        fallback: "The iOS companion sends audio to this Mac for local transcription, so it still uses the local speech-to-text model even when Mac dictation is set to Cloud."
                    ))
                    Text(L10n.string(
                        "settings.ios.port_note",
                        fallback: "The server listens on port 8000 and requires the companion setup and Python dependencies documented in the README."
                    ))
                    Text(L10n.string(
                        "settings.ios.caption_conflict_note",
                        fallback: "Live Caption and the iOS Server cannot run at the same time because they share GPU memory."
                    ))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPaneLayout()
        .onAppear {
            isRunning = isRunningProvider()
        }
        .onReceive(NotificationCenter.default.publisher(for: .iosServerStatusDidChange)) { note in
            if let running = note.userInfo?[Self.runningUserInfoKey] as? Bool {
                isRunning = running
            } else {
                isRunning = isRunningProvider()
            }
        }
    }

    static func makeSettingsPane(
        onToggle: @escaping () -> Void,
        isRunning: @escaping () -> Bool
    ) -> AppSettings.Pane<IOSServerPane> {
        let title = L10n.string("settings.tab.ios", fallback: "iOS")
        return AppSettings.Pane(
            identifier: .ios,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "iphone",
                accessibilityDescription: title
            )!
        ) {
            IOSServerPane(onToggle: onToggle, isRunning: isRunning)
        }
    }
}
