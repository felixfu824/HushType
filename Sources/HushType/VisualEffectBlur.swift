import SwiftUI
import AppKit

/// Translucent background wrapper shared by the floating pill, the translation
/// card, and the live caption panel. Promoted from `private` inside
/// `FloatingOverlayView.swift` so all hud-style surfaces draw against the same
/// material without duplication.
struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
