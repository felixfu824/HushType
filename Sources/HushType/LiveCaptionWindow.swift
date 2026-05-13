import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "liveCaptionUI")

/// Bottom-pinned translucent panel that hosts the live caption stream.
///
/// Window properties match the §9.b spec — `.screenSaver` level + the
/// fullscreen-aware collection behavior so captions appear over Zoom/Keynote
/// full-screen Spaces, draggable from anywhere, resizable, never main.
final class LiveCaptionWindow: NSPanel, NSWindowDelegate {

    private let viewModel: LiveCaptionViewModel
    private let onStop: () -> Void

    /// Loaded from `LiveCaptionTuning.panelDefault*` once per panel creation
    /// so the JSON file can override the bundled default.
    private let defaultSize: NSSize
    private static let panelFrameKey = "hushtype.liveCaption.panelFrame"

    private var saveFrameWork: DispatchWorkItem?

    init(viewModel: LiveCaptionViewModel, tuning: LiveCaptionTuning, onStop: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onStop = onStop
        self.defaultSize = NSSize(
            width: tuning.panelDefaultWidth,
            height: tuning.panelDefaultHeight
        )

        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(
                width: tuning.panelDefaultWidth,
                height: tuning.panelDefaultHeight
            )),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // SwiftUI view draws its own
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        hidesOnDeactivate = false
        isFloatingPanel = true
        isMovableByWindowBackground = true
        ignoresMouseEvents = false

        minSize = NSSize(width: 500, height: 90)
        maxSize = NSSize(width: 1600, height: 500)

        let hostingView = NSHostingView(
            rootView: LiveCaptionView(model: viewModel, onStop: onStop)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView = hostingView

        delegate = self
    }

    // Need key for Esc handling, but never main (don't steal focus).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Restore persisted frame if present and still on a connected screen,
    /// otherwise position bottom-center of the main screen using the same
    /// formula as `FloatingOverlayWindow.show()`.
    private func positionForShow() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Self.panelFrameKey), !saved.isEmpty {
            let restored = NSRectFromString(saved)
            // Reject saved frames smaller than the current minSize so a width
            // change in this build doesn't strand the user on a too-narrow
            // pre-existing frame.
            let fitsBounds = restored.size.width >= minSize.width
                && restored.size.height >= minSize.height
            if restored.size.width > 0 && restored.size.height > 0
                && fitsBounds && isOnAnyScreen(restored) {
                setFrame(restored, display: false)
                return
            } else {
                log.warning("LiveCaption: stored panel frame off-screen or below minSize, snapping back to default")
            }
        }

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = defaultSize
        let x = visible.midX - size.width / 2
        let y = visible.minY + 80
        setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: false)
    }

    private func isOnAnyScreen(_ rect: NSRect) -> Bool {
        for screen in NSScreen.screens {
            if screen.visibleFrame.intersects(rect) {
                return true
            }
        }
        return false
    }

    /// Fade-in show.
    func show() {
        positionForShow()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    /// Fade-out hide.
    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        scheduleFrameSave()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleFrameSave()
    }

    private func scheduleFrameSave() {
        saveFrameWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let frameString = NSStringFromRect(self.frame)
            UserDefaults.standard.set(frameString, forKey: Self.panelFrameKey)
        }
        saveFrameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
