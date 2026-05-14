import SwiftUI
import AppKit

/// Header state — drives the left-side content of the panel header.
enum LiveCaptionHeaderState: Equatable {
    case loadingVAD       // "Loading VAD model…"
    case live              // "● Live"
    case gatedFlash        // "Stop Live Caption to dictate" (orange, 2s)
    case reconnecting(attempt: Int, max: Int)   // cloud transport reconnect
    case autoStopped                            // 5s flash after auto-stop
}

/// SwiftUI body of the live caption panel. Owned/hosted by
/// `LiveCaptionWindow`. State is driven through a small observable model so
/// the manager can `await MainActor.run { … }` from off-actor contexts.
final class LiveCaptionViewModel: ObservableObject {
    @Published var headerState: LiveCaptionHeaderState = .live
    /// Rolling buffer (max 50 segments — §9.b "Buffer size").
    @Published var segments: [SegmentEntry] = []

    /// Small grey line above the target caption — only meaningful for the
    /// cloud translate engine. Nil = hidden. Set/cleared by the manager from
    /// `BackendEvent.sourceDelta` / `.segmentComplete`.
    @Published var currentSourceLine: String? = nil
    /// Main caption font; the in-progress translated line. Nil = hidden.
    /// When non-nil, the existing `isCurrent` highlight on `segments.last` is
    /// suppressed — the highlight applies to this region instead.
    @Published var currentTargetLine: String? = nil

    /// "MM:SS · $X.XX" chip shown in the panel header when cloud engine is
    /// active. Nil = hide chip (local engine, or cloud session not yet
    /// emitting audio).
    @Published var cloudCostChip: String? = nil

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
        HStack(spacing: 8) {
            headerLeft
                .animation(.easeInOut(duration: 0.18), value: model.headerState)
            Spacer()
            if let chip = model.cloudCostChip {
                Text(chip)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cloud Live Caption session cost")
            }
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
                // Header text reflects which product is running. Cloud
                // sessions translate audio into a target language; local
                // sessions just transcribe — same UI panel, different
                // products with different cost/privacy profiles, so the
                // header label distinguishes them at a glance.
                Text(AppConfig.shared.liveCaptionEngine == .cloudTranslate
                     ? "Live · Translated"
                     : "Live")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
        case .gatedFlash:
            Text("Stop Live Caption to dictate")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
        case .reconnecting(let attempt, let max):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("Reconnecting (\(attempt)/\(max))…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
            }
        case .autoStopped:
            Text("Auto-stopped")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
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
        let hasCurrentLine = (model.currentSourceLine != nil) || (model.currentTargetLine != nil)

        if model.segments.isEmpty && !hasCurrentLine {
            HStack {
                Spacer()
                Text("Listening…")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                scrollback
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if hasCurrentLine {
                    dualLineRegion
                        .padding(.top, 6)
                }
            }
        }
    }

    /// Rolling segment history. The current/last segment gets the white
    /// highlight only when the dual-line region is NOT showing — when cloud
    /// is feeding live deltas into `currentTargetLine`, that region owns the
    /// highlight instead.
    private var scrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    // ForEach identity is the entry UUID — stable across appends.
                    // Do NOT also attach .id("current") on the last view; switching
                    // a Text's .id between "current" and its UUID on each append
                    // confuses SwiftUI's diff and causes the white-styled position
                    // to render stale content. The scroll anchor below is a
                    // separate invisible view so identity stays clean.
                    ForEach(Array(model.segments.enumerated()), id: \.element.id) { (index, entry) in
                        let dualLineActive = (model.currentTargetLine != nil) || (model.currentSourceLine != nil)
                        let isCurrent = !dualLineActive && (index == model.segments.count - 1)
                        Text(entry.text)
                            .font(.system(size: isCurrent ? 17 : 13, weight: .regular))
                            .lineSpacing(1)
                            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("liveCaptionScrollAnchor")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.segments.count) { _, _ in
                // Only re-anchor on segment count change — not on per-delta
                // edits of currentTargetLine — so the live deltas don't
                // re-scroll 60+ times per second.
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("liveCaptionScrollAnchor", anchor: .bottom)
                }
            }
        }
    }

    /// Pinned dual-line region below the scrollback: source line on top
    /// (small grey, "SOURCE" chip), translated line below (main caption
    /// font, "TRANSLATED" chip). Both share a single left accent rule so the
    /// user reads them as one translation pair rather than two unrelated
    /// lines. Collapses when both are nil.
    private var dualLineRegion: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.55))
                .frame(width: 2)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                if let source = model.currentSourceLine, !source.isEmpty {
                    dualLineRow(
                        roleLabel: "SOURCE",
                        text: source,
                        fontSize: 12,
                        color: .secondary
                    )
                }
                if let target = model.currentTargetLine, !target.isEmpty {
                    dualLineRow(
                        roleLabel: "TRANSLATED",
                        text: target,
                        fontSize: 17,
                        color: .primary
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One line of the dual-line region. Fixed-width pill chip on the left
    /// (so SOURCE / TRANSLATED stack vertically aligned), then the caption.
    /// The chip is intentionally bold + capsule-shaped so the role is
    /// readable at panel viewing distance — the previous SF Symbol glyphs
    /// at 10pt tertiary opacity were near-invisible.
    @ViewBuilder
    private func dualLineRow(roleLabel: String, text: String, fontSize: CGFloat, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(roleLabel)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.14), in: Capsule())
                .frame(width: 92, alignment: .leading)
                .accessibilityLabel(roleLabel == "SOURCE" ? "Source language" : "Translated")
            Text(text)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(color)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
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
