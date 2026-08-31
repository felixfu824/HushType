import AppKit
import ScreenCaptureKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "systemAudioPicker")

/// Value-only representation of a capturable application. Keeping catalog
/// cleanup separate from ScreenCaptureKit and AppKit makes duplicate handling
/// and the user-facing order deterministic and directly testable.
struct SystemAudioPickerCandidate: Equatable, Sendable {
    let bundleID: String
    let name: String
}

struct SystemAudioPickerGroups: Equatable, Sendable {
    let common: [SystemAudioPickerCandidate]
    let other: [SystemAudioPickerCandidate]

    var isEmpty: Bool { common.isEmpty && other.isEmpty }
}

enum SystemAudioPickerCatalog {
    /// Deliberately small: these are common audio sources, not endorsements or
    /// placeholders. An entry is shown only when ScreenCaptureKit reports it.
    static let commonBundleIDs = [
        "com.microsoft.edgemac",
        "com.google.Chrome",
        "us.zoom.xos",
    ]

    static func groups(from candidates: [SystemAudioPickerCandidate]) -> SystemAudioPickerGroups {
        var byBundleID: [String: SystemAudioPickerCandidate] = [:]

        for candidate in candidates {
            let bundleID = candidate.bundleID
            let name = normalizedName(candidate.name)
            guard
                !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !name.isEmpty
            else { continue }

            let normalized = SystemAudioPickerCandidate(bundleID: bundleID, name: name)
            if let existing = byBundleID[bundleID] {
                byBundleID[bundleID] = preferred(existing, normalized)
            } else {
                byBundleID[bundleID] = normalized
            }
        }

        let common = commonBundleIDs.compactMap { byBundleID.removeValue(forKey: $0) }
        let other = byBundleID.values.sorted(by: alphabeticalOrder)
        return SystemAudioPickerGroups(common: common, other: other)
    }

    private static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Prefer the most concise label for duplicate ScreenCaptureKit records,
    /// with locale-independent tie breakers so the chosen row never depends
    /// on source enumeration order.
    private static func preferred(
        _ lhs: SystemAudioPickerCandidate,
        _ rhs: SystemAudioPickerCandidate
    ) -> SystemAudioPickerCandidate {
        let lhsKey = (lhs.name.count, sortKey(lhs.name), lhs.name)
        let rhsKey = (rhs.name.count, sortKey(rhs.name), rhs.name)
        return lhsKey <= rhsKey ? lhs : rhs
    }

    private static func alphabeticalOrder(
        _ lhs: SystemAudioPickerCandidate,
        _ rhs: SystemAudioPickerCandidate
    ) -> Bool {
        let lhsName = sortKey(lhs.name)
        let rhsName = sortKey(rhs.name)
        if lhsName != rhsName { return lhsName < rhsName }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.bundleID < rhs.bundleID
    }

    private static func sortKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

/// Picker UI that shows running apps and lets the user choose one to caption.
///
/// Entry point: `SystemAudioPicker.present(completion:)`. Surfaces the picker
/// as a modal sheet-style window using `.hudWindow` material for visual
/// consistency with the rest of Lamitype's overlays. Persists the chosen
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
        panel.title = L10n.string(
            "window.system_audio_picker.title",
            fallback: "Pick App to Caption"
        )
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

    @State private var commonApps: [AppEntry] = []
    @State private var otherApps: [AppEntry] = []
    @State private var selection: String?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("picker.system_audio.heading", fallback: "Pick app to caption"))
                .font(.title3.weight(.semibold))

            Text(L10n.string(
                "picker.system_audio.description",
                fallback: "Choose which app's audio Live Caption should listen to. Only audio is captured; never screen contents."
            ))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ZStack {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.string(
                            "picker.system_audio.loading",
                            fallback: "Loading running apps…"
                        ))
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
                } else if commonApps.isEmpty && otherApps.isEmpty {
                    Text(L10n.string(
                        "picker.system_audio.empty",
                        fallback: "No running apps found."
                    ))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Custom scroll + Button rows, NOT SwiftUI List(selection:).
                    // The List-based approach was tried twice; on macOS the
                    // NSCollectionView-backed implementation dispatches hit
                    // testing such that clicks on Text content didn't propagate
                    // to row selection — the only clickable zone was the
                    // Spacer gap between the app name and the bundle ID
                    // (Felix's red circle, 2026-05-14). `.contentShape`,
                    // `.frame(maxWidth: .infinity)`, and `simultaneousGesture`
                    // each tried as fixes did not help. A plain Button with
                    // `.plain` style is the macOS-native pattern for a full-
                    // row click target, and gives us free keyboard/focus
                    // handling on top.
                    appListView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Button(L10n.string("common.button.cancel", fallback: "Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("picker.system_audio.pick", fallback: "Pick")) {
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

    // MARK: - Row list

    @ViewBuilder
    private var appListView: some View {
        ScrollView {
            // A regular VStack is intentional. The app catalog is short, and
            // LazyVStack has produced large phantom gaps when ScreenCaptureKit
            // returns duplicate identities or rows change during realization.
            VStack(alignment: .leading, spacing: 0) {
                if !commonApps.isEmpty {
                    sectionHeader(L10n.string(
                        "picker.system_audio.common_running",
                        fallback: "Common running apps"
                    ))
                    ForEach(Array(commonApps.enumerated()), id: \.element.id) { index, app in
                        appRow(app, alternateBackground: !index.isMultiple(of: 2))
                    }
                }

                if !otherApps.isEmpty {
                    sectionHeader(L10n.string(
                        "picker.system_audio.other_running",
                        fallback: "All other running apps"
                    ))
                    ForEach(Array(otherApps.enumerated()), id: \.element.id) { index, app in
                        appRow(app, alternateBackground: !index.isMultiple(of: 2))
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
    }

    /// Whole row is a `.plain`-styled Button so single-click anywhere on the
    /// row selects, and macOS handles focus/keyboard semantics natively.
    /// Double-click activates (picks immediately) via a tap-count gesture
    /// attached after the Button — it doesn't fight single-click selection
    /// the way it did inside a `List(selection:)` row.
    @ViewBuilder
    private func appRow(_ app: AppEntry, alternateBackground: Bool) -> some View {
        let isSelected = (selection == app.id)
        Button {
            selection = app.id
        } label: {
            HStack(spacing: 10) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app.fill")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(isSelected ? Color.white : .secondary)
                }
                Text(app.name)
                    .foregroundStyle(isSelected ? Color.white : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 16)
                Text(app.id)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? Color.accentColor
                    : (alternateBackground
                        ? Color(NSColor.alternatingContentBackgroundColors.last ?? .clear)
                        : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onPick(app.id) }
        )
    }

    private func loadApps() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let workspace = NSWorkspace.shared
            let candidates = content.applications.compactMap { app -> SystemAudioPickerCandidate? in
                guard let bundleID = app.bundleIdentifier as String? else { return nil }
                return SystemAudioPickerCandidate(bundleID: bundleID, name: app.applicationName)
            }
            let groups = SystemAudioPickerCatalog.groups(from: candidates)

            func makeEntry(_ candidate: SystemAudioPickerCandidate) -> AppEntry {
                let icon = workspace.urlForApplication(withBundleIdentifier: candidate.bundleID)
                    .map { workspace.icon(forFile: $0.path) }
                return AppEntry(id: candidate.bundleID, name: candidate.name, icon: icon)
            }

            let commonEntries = groups.common.map(makeEntry)
            let otherEntries = groups.other.map(makeEntry)
            let storedBundleID = LiveCaptionTuning.load().systemAudioBundleID

            await MainActor.run {
                self.commonApps = commonEntries
                self.otherApps = otherEntries
                if (commonEntries + otherEntries).contains(where: { $0.id == storedBundleID }) {
                    self.selection = storedBundleID
                }
                self.isLoading = false
            }
        } catch {
            log.error("Failed to load shareable content: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                self.loadError = L10n.format(
                    "picker.system_audio.load_failed",
                    "Couldn't load running apps:\n%1$@",
                    arguments: [error.localizedDescription]
                )
                self.isLoading = false
            }
        }
    }
}
