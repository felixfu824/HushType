import AppKit
import ScreenCaptureKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "systemAudioPicker")

/// Picker UI that shows running apps and lets the user choose one to caption.
///
/// Entry point: `SystemAudioPicker.present(completion:)`. Surfaces the picker
/// as a modal sheet-style window using `.hudWindow` material for visual
/// consistency with the rest of HushType's overlays. Persists the chosen
/// `bundleID` to `live_caption.json` via
/// `LiveCaptionTuning.setSystemAudioBundleID(_:)` and reports it via
/// `completion`. If the user cancels, `completion` receives `nil`.
@MainActor
enum SystemAudioPicker {
    private static var window: NSWindow?

    static func present(completion: @escaping (String?) -> Void) {
        // If a picker is already showing, bring it forward and abort.
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = SystemAudioPickerView(
            onPick: { bundleID in
                LiveCaptionTuning.setSystemAudioBundleID(bundleID)
                dismiss()
                completion(bundleID)
            },
            onCancel: {
                dismiss()
                completion(nil)
            }
        )

        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pick App to Caption"
        panel.contentViewController = hosting
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }

    private static func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - View

private struct AppEntry: Identifiable, Hashable {
    let id: String         // bundleID
    let name: String
    let icon: NSImage?
}

private struct SystemAudioPickerView: View {
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @State private var apps: [AppEntry] = []
    @State private var selection: String?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick app to caption")
                .font(.title3.weight(.semibold))

            Text("Choose which app's audio Live Caption should listen to. Only audio is captured — never screen contents.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ZStack {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading running apps…")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    Text(loadError)
                        .foregroundColor(.red)
                        .font(.callout)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if apps.isEmpty {
                    Text("No running apps found.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Hit-target rules of thumb:
                    //   * Single-tap MUST drive List selection, so we cannot put a
                    //     plain `.onTapGesture` on the row (it swallows the click).
                    //   * `.simultaneousGesture(TapGesture(count:2))` runs alongside
                    //     SwiftUI's selection logic, so double-click activation
                    //     ("Pick this app immediately") still works.
                    //   * `frame(maxWidth: .infinity, alignment: .leading)` then
                    //     `contentShape(Rectangle())` makes the whole row width
                    //     clickable, not just where the icon/text happen to land.
                    //   * `padding(.vertical, 4)` gives a taller hit zone so fast
                    //     trackpad strokes don't miss between rows.
                    List(apps, selection: $selection) { app in
                        HStack(spacing: 10) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "app.fill")
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.secondary)
                            }
                            Text(app.name)
                            Spacer()
                            Text(app.id)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(app.id)
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded { onPick(app.id) }
                        )
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Pick") {
                    if let selection {
                        onPick(selection)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 480)
        .task { await loadApps() }
    }

    private func loadApps() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let workspace = NSWorkspace.shared
            let entries: [AppEntry] = content.applications
                .compactMap { app -> AppEntry? in
                    guard
                        let bundleID = app.bundleIdentifier as String?,
                        !bundleID.isEmpty,
                        !app.applicationName.isEmpty
                    else { return nil }
                    let icon: NSImage? = workspace.urlForApplication(withBundleIdentifier: bundleID)
                        .map { workspace.icon(forFile: $0.path) }
                    return AppEntry(id: bundleID, name: app.applicationName, icon: icon)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            await MainActor.run {
                self.apps = entries
                self.isLoading = false
            }
        } catch {
            log.error("Failed to load shareable content: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                self.loadError = "Couldn't load running apps:\n\(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}
