import SwiftUI
import AppKit

// MARK: - State

/// Visible state of the floating overlay. The window itself is shown/hidden
/// independently — `.hidden` is here only for clarity, in practice the window
/// is ordered out instead of rendering this case.
enum OverlayState: Equatable {
    case hidden
    case recording(level: Float)  // 0.0–1.0 RMS
    case transcribing
}

/// Observable model so SwiftUI can react to RMS updates.
///
/// Thread-safety: All mutations of `state` MUST happen on the main thread.
/// AppDelegate enforces this by hopping to main before forwarding RMS
/// callbacks (which fire on the CoreAudio IO thread). Not @MainActor-annotated
/// to keep AppDelegate construction synchronous.
final class OverlayStateModel: ObservableObject {
    @Published var state: OverlayState = .hidden
}

// MARK: - Pill view

struct FloatingOverlayView: View {
    @ObservedObject var model: OverlayStateModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 80, alignment: .leading)

            ZStack {
                switch model.state {
                case .recording(let level):
                    AudioBarsView(level: level)
                        .transition(.opacity)
                case .transcribing:
                    // Pulsing ellipsis — each dot fades in/out independently.
                    // More visually distinct from the 5 bars than a tiny
                    // ProgressView spinner, and the symbol effect handles
                    // the animation reliably inside an NSHostingView.
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .symbolEffect(.pulse.byLayer, options: .repeating)
                        .transition(.opacity)
                case .hidden:
                    EmptyView()
                }
            }
            .frame(width: 40, height: 24)
            .animation(.easeInOut(duration: 0.18), value: stateKey)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(VisualEffectBlur(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        .fixedSize()
    }

    private var label: String {
        switch model.state {
        case .recording:    return "Listening"
        case .transcribing: return "Transcribing"
        case .hidden:       return ""
        }
    }

    /// Stable key for animating the ZStack content swap (don't animate on
    /// every RMS level change, only on state-class change).
    private var stateKey: Int {
        switch model.state {
        case .hidden:        return 0
        case .recording:     return 1
        case .transcribing:  return 2
        }
    }
}

// MARK: - Audio bars (5 vertical capsules driven by RMS)

private struct AudioBarsView: View {
    let level: Float

    private let barCount = 5
    private let maxHeight: CGFloat = 22

    /// Per-bar weight — center bars peak slightly taller for a "voice" curve.
    private let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.85, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 3, height: barHeight(index: i))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: maxHeight)
    }

    private func barHeight(index: Int) -> CGFloat {
        // Speech RMS is empirically much smaller than I assumed — typical
        // values are 0.005-0.05 for normal voice. Use a square-root mapping
        // with high boost so soft speech reaches mid-range and normal speech
        // saturates the bars.
        let boosted = min(1.0, CGFloat(level) * 30.0)
        let curved = sqrt(boosted)  // sqrt gives more visual range to soft speech
        let scaled = curved * weights[index]
        return max(3, maxHeight * scaled)
    }
}

