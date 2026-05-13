import SwiftUI
import AppKit

/// Header state — drives the left-side content of the panel header.
enum LiveCaptionHeaderState: Equatable {
    case loadingVAD       // "Loading VAD model…"
    case live              // "● Live"
    case gatedFlash        // "Stop Live Caption to dictate" (orange, 2s)
}

/// SwiftUI body of the live caption panel. Owned/hosted by
/// `LiveCaptionWindow`. State is driven through a small observable model so
/// the manager can `await MainActor.run { … }` from off-actor contexts.
final class LiveCaptionViewModel: ObservableObject {
    @Published var headerState: LiveCaptionHeaderState = .live
    /// Rolling buffer (max 50 segments — §9.b "Buffer size").
    @Published var segments: [SegmentEntry] = []

    struct SegmentEntry: Identifiable, Equatable {
        let id: UUID = UUID()
        let text: String
    }
}

struct LiveCaptionView: View {
    @ObservedObject var model: LiveCaptionViewModel
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 8)

            Divider().opacity(0.2)

            body_
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(VisualEffectBlur(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        .onExitCommand { onStop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            headerLeft
                .animation(.easeInOut(duration: 0.18), value: model.headerState)
            Spacer()
            stopButton
        }
    }

    @ViewBuilder
    private var headerLeft: some View {
        switch model.headerState {
        case .loadingVAD:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("Loading VAD model…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
        case .live:
            HStack(spacing: 8) {
                LivePulseDot()
                Text("Live")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
        case .gatedFlash:
            Text("Stop Live Caption to dictate")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop live caption")
        .help("Stop live caption (Esc)")
    }

    // MARK: - Body

    @ViewBuilder
    private var body_: some View {
        if model.segments.isEmpty {
            HStack {
                Spacer()
                Text("Listening…")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.segments.enumerated()), id: \.element.id) { (index, entry) in
                            let isCurrent = (index == model.segments.count - 1)
                            Text(entry.text)
                                .font(.system(size: isCurrent ? 17 : 13, weight: .regular))
                                .lineSpacing(1)
                                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(isCurrent ? "current" : entry.id.uuidString)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.segments.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("current", anchor: .bottom)
                    }
                }
            }
        }
    }
}

/// 8pt red dot with a manual 1.4s ease-in-out opacity pulse between 1.0 and
/// 0.5 — mirrors the §9.b "● Live" indicator spec. Plain SwiftUI animation
/// rather than `.symbolEffect(.pulse)` because the indicator is not an SF
/// Symbol (it's a filled `Circle`), and a hand-rolled pulse is more reliable
/// inside an NSHostingView.
struct LivePulseDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.5 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}
