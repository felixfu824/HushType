import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: BackgroundAudioManager
    @State private var serverURL: String = ""
    @State private var isTestingConnection = false
    @State private var connectionStatus: String?

    private let defaults = AppGroup.userDefaults

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("VoxKey")
                    .font(.largeTitle.bold())
                    .padding(.top, 20)

                // Server Setup
                VStack(alignment: .leading, spacing: 10) {
                    Text("Server Address")
                        .font(.headline)

                    TextField("http://100.75.151.28:8000", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .disableAutocorrection(true)
                        .onChange(of: serverURL) { _, newValue in
                            defaults.set(newValue, forKey: AppGroup.serverURL)
                        }

                    HStack {
                        Button("Test Connection") {
                            testConnection()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTestingConnection)

                        if isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.8)
                        }

                        if let status = connectionStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundColor(status.contains("✓") ? .green : .red)
                        }
                    }
                }
                .padding()
                .background(.regularMaterial)
                .cornerRadius(12)

                // Listening Session (like Typeless)
                VStack(spacing: 16) {
                    if manager.isListening {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.red)

                        Text("Listening")
                            .font(.title2.bold())
                            .foregroundColor(.red)

                        // Countdown timer
                        Text(formatTime(manager.sessionTimeRemaining))
                            .font(.system(size: 32, weight: .light, design: .monospaced))
                            .foregroundColor(.secondary)

                        Text("Switch to any app and use the VoxKey keyboard.\nAuto-stops when timer expires.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        if !manager.lastResult.isEmpty {
                            Text(manager.lastResult)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(.regularMaterial)
                                .cornerRadius(8)
                        }

                        Button("Stop Listening") {
                            manager.stopListeningSession()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: 56))
                            .foregroundColor(statusColor)

                        Text(statusText)
                            .font(.title2)

                        if !manager.lastResult.isEmpty {
                            Text(manager.lastResult)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(.regularMaterial)
                                .cornerRadius(8)
                        }

                        Button(action: { manager.startListeningSession() }) {
                            Label("Start Listening", systemImage: "mic.fill")
                                .font(.title3)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }
                .padding(.vertical, 8)

                // Manual test button (direct record in main app)
                Button(action: toggleRecording) {
                    Label(
                        manager.state == .recording ? "Stop" : "Test Record",
                        systemImage: manager.state == .recording ? "stop.fill" : "waveform"
                    )
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(!manager.isListening)

                Spacer(minLength: 40)

                Text("Keyboard Setup: Settings → General → Keyboard → Keyboards → Add → VoxKey")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
        }
        .onAppear {
            let saved = defaults.string(forKey: AppGroup.serverURL)
            serverURL = saved ?? "http://100.75.151.28:8000"
            if saved == nil {
                defaults.set(serverURL, forKey: AppGroup.serverURL)
            }
        }
    }

    var statusIcon: String {
        switch manager.state {
        case .idle: return "mic.fill"
        case .recording: return "record.circle"
        case .transcribing: return "ellipsis.circle"
        case .done: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    var statusColor: Color {
        switch manager.state {
        case .idle: return .primary
        case .recording: return .red
        case .transcribing: return .orange
        case .done: return .green
        case .error: return .red
        }
    }

    var statusText: String {
        switch manager.state {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .done: return "Done"
        case .error: return manager.errorMessage ?? "Error"
        }
    }

    func toggleRecording() {
        if manager.state == .recording {
            IPC.post(IPC.stopRecording)
        } else if manager.state == .idle {
            IPC.post(IPC.startRecording)
        }
    }

    func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    func testConnection() {
        isTestingConnection = true
        connectionStatus = nil

        Task {
            do {
                let ok = try await manager.transcriber.testConnection()
                connectionStatus = ok ? "✓ Connected" : "✗ Server error"
            } catch {
                connectionStatus = "✗ \(error.localizedDescription)"
            }
            isTestingConnection = false
        }
    }
}
