import SwiftUI

enum SettingsGrid {
    static let paneWidth: CGFloat = 720
    static let labelWidth: CGFloat = 170
    static let gutter: CGFloat = 6
    static let controlWidth: CGFloat = 300
    static let contentWidth = labelWidth + gutter + controlWidth
    static let rowSpacing: CGFloat = 6
    static let sectionSpacing: CGFloat = 8
    static let dividerMargin: CGFloat = 18
    static let paneSidePadding: CGFloat = 20
    static let dividerWidth = paneWidth - (paneSidePadding * 2)
    static let paneTopPadding: CGFloat = 14
    static let paneBottomPadding: CGFloat = 20
}

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
        HStack(alignment: .firstTextBaseline, spacing: SettingsGrid.gutter) {
            Text(label)
                .frame(width: SettingsGrid.labelWidth, alignment: .trailing)
            content
                .frame(width: SettingsGrid.controlWidth, alignment: .leading)
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
        .frame(width: SettingsGrid.contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, SettingsGrid.sectionSpacing - SettingsGrid.rowSpacing)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .frame(width: SettingsGrid.dividerWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(
                .vertical,
                SettingsGrid.dividerMargin - SettingsGrid.rowSpacing
            )
    }
}

extension View {
    func settingsPaneLayout() -> some View {
        padding(.top, SettingsGrid.paneTopPadding)
            .padding(.bottom, SettingsGrid.paneBottomPadding)
            .frame(width: SettingsGrid.paneWidth)
    }
}
