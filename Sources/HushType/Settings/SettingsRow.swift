import SwiftUI

/// Project-owned settings grid. The Settings package handles the window and
/// intrinsic pane sizing; HushType owns the approved 170 / 6 / 300 point row.
struct SettingsRow<Content: View>: View {
    private let label: String
    private let content: Content

    init(_ label: String = "", @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .frame(width: 170, alignment: .trailing)
            content
                .frame(width: 300, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 476, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
