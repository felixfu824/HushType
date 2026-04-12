import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "translationCard")

/// Subclass that routes Esc to dismiss.
private class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Floating panel that shows translation results in a centered card.
///
/// Dismisses on Esc key press or click outside the panel.
final class TranslationCardWindow {

    private var panel: KeyPanel?
    private var globalClickMonitor: Any?

    /// Show the translation card centered on the main screen.
    func show(sourceLanguage: String, sourceText: String, translatedText: String) {
        dismiss()

        let panel = KeyPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.onEscape = { [weak self] in self?.dismiss() }

        let cardView = TranslationCardView(
            sourceLanguage: sourceLanguage,
            sourceText: sourceText,
            translatedText: translatedText
        )
        let hostingView = NSHostingView(rootView: cardView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hostingView

        // Let SwiftUI determine the size, then center on screen.
        let fittingSize = hostingView.fittingSize
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.midX - fittingSize.width / 2
            let y = visible.midY - fittingSize.height / 2
            panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: fittingSize), display: true)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        self.panel = panel

        // Dismiss on click outside the panel.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.dismiss()
        }

        log.info("Translation card shown")
    }

    /// Fade out and dismiss the card.
    func dismiss() {
        guard let panel = panel else { return }

        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.contentView = nil
            self?.panel = nil
        })

        log.info("Translation card dismissed")
    }
}
