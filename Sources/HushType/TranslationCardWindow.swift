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

/// Hosting view that notifies on mouse enter / exit so the translation card
/// can pause its auto-dismiss countdown while the user is hovering to read.
private final class HoverTrackingHostingView<V: View>: NSHostingView<V> {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}

/// Floating panel that shows translation results in a centered card.
///
/// Dismisses on Esc key press or click outside the panel.
final class TranslationCardWindow {

    /// Auto-dismiss the card after this many seconds of no hover interaction.
    /// Countdown pauses while the pointer is inside the card (read-mode),
    /// restarts from zero when the pointer leaves.
    private static let autoDismissSeconds: TimeInterval = 10

    private var panel: KeyPanel?
    private var globalClickMonitor: Any?
    private var autoDismissTimer: Timer?

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
        let hostingView = HoverTrackingHostingView(rootView: cardView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.onMouseEntered = { [weak self] in self?.cancelAutoDismiss() }
        hostingView.onMouseExited = { [weak self] in self?.scheduleAutoDismiss() }
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

        // Start the auto-dismiss countdown. If the pointer is already inside
        // the card, the HoverTrackingHostingView will fire mouseEntered
        // momentarily and cancel this timer.
        scheduleAutoDismiss()

        log.info("Translation card shown")
    }

    // MARK: - Auto-dismiss

    private func scheduleAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoDismissSeconds,
            repeats: false
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    /// Fade out and dismiss the card.
    func dismiss() {
        guard let panel = panel else { return }

        cancelAutoDismiss()

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
