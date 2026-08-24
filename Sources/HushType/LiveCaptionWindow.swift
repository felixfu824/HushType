import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "liveCaptionUI")

/// Single source of truth for the user-positioned caption panel frame.
///
/// The tuning JSON deliberately does not participate in live panel geometry:
/// dragging/resizing the actual window is authoritative. Keeping the key and
/// normalization policy here also prevents Settings and the manager from
/// growing their own, subtly different notions of the panel size.
enum LiveCaptionPanelFrameStore {
    static let frameKey = "hushtype.liveCaption.panelFrame.v3"
    static let legacyFrameKeys = [
        "hushtype.liveCaption.panelFrame",
        "hushtype.liveCaption.panelFrame.v2",
    ]

    static let defaultSize = NSSize(width: 1350, height: 160)
    static let minimumSize = NSSize(width: 500, height: 90)
    static let maximumSize = NSSize(width: 1600, height: 500)
    private static let screenInset: CGFloat = 20
    private static let bottomOffset: CGFloat = 80

    static func load(defaults: UserDefaults = .standard) -> NSRect? {
        purgeLegacyKeys(defaults: defaults)
        guard let value = defaults.string(forKey: frameKey), !value.isEmpty else {
            return nil
        }
        let rect = NSRectFromString(value)
        guard rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    static func save(_ frame: NSRect, defaults: UserDefaults = .standard) {
        defaults.set(NSStringFromRect(frame), forKey: frameKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: frameKey)
        purgeLegacyKeys(defaults: defaults)
    }

    static func purgeLegacyKeys(defaults: UserDefaults = .standard) {
        for key in legacyFrameKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    /// Clamp a restored frame to the connected displays. A frame that still
    /// intersects a display keeps its relative location (clamped fully into
    /// that display). A frame from a disconnected display snaps bottom-centre
    /// on the preferred display instead of becoming unreachable.
    static func normalizedFrame(
        _ candidate: NSRect?,
        visibleScreens: [NSRect],
        preferredScreen: NSRect?
    ) -> NSRect? {
        guard !visibleScreens.isEmpty else { return nil }
        let preferred = preferredScreen ?? visibleScreens[0]
        let intersecting: NSRect?
        if let candidate,
           let best = visibleScreens.max(by: {
               intersectionArea($0, candidate) < intersectionArea($1, candidate)
           }),
           intersectionArea(best, candidate) > 0 {
            intersecting = best
        } else {
            intersecting = nil
        }
        let screen = intersecting ?? preferred

        let requestedSize = candidate?.size ?? defaultSize
        let usableWidth = max(1, screen.width - screenInset * 2)
        let usableHeight = max(1, screen.height - screenInset * 2)
        let lowerWidth = min(minimumSize.width, usableWidth)
        let lowerHeight = min(minimumSize.height, usableHeight)
        let size = NSSize(
            width: min(max(requestedSize.width, lowerWidth), min(maximumSize.width, usableWidth)),
            height: min(max(requestedSize.height, lowerHeight), min(maximumSize.height, usableHeight))
        )

        let origin: NSPoint
        if let candidate, intersecting != nil {
            origin = NSPoint(
                x: min(max(candidate.minX, screen.minX + screenInset), screen.maxX - screenInset - size.width),
                y: min(max(candidate.minY, screen.minY + screenInset), screen.maxY - screenInset - size.height)
            )
        } else {
            origin = NSPoint(
                x: screen.midX - size.width / 2,
                y: min(screen.minY + bottomOffset, screen.maxY - screenInset - size.height)
            )
        }
        return NSRect(origin: origin, size: size)
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

/// Bottom-pinned translucent panel that hosts the live caption stream.
///
/// Window properties match the §9.b spec — `.screenSaver` level + the
/// fullscreen-aware collection behavior so captions appear over Zoom/Keynote
/// full-screen Spaces, draggable from anywhere, resizable, never main.
final class LiveCaptionWindow: NSPanel, NSWindowDelegate {

    private let viewModel: LiveCaptionViewModel
    private let onStop: () -> Void

    private var saveFrameWork: DispatchWorkItem?

    init(viewModel: LiveCaptionViewModel, onStop: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onStop = onStop

        super.init(
            contentRect: NSRect(origin: .zero, size: LiveCaptionPanelFrameStore.defaultSize),
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

        minSize = LiveCaptionPanelFrameStore.minimumSize
        maxSize = LiveCaptionPanelFrameStore.maximumSize

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
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let frame = LiveCaptionPanelFrameStore.normalizedFrame(
            LiveCaptionPanelFrameStore.load(),
            visibleScreens: screens,
            preferredScreen: NSScreen.main?.visibleFrame
        ) else { return }
        setFrame(frame, display: false)
        LiveCaptionPanelFrameStore.save(frame)
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
        saveFrameNow()
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

    func windowDidResize(_ notification: Notification) {
        scheduleFrameSave()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrameNow()
    }

    func windowWillClose(_ notification: Notification) {
        saveFrameNow()
    }

    /// Restore the built-in geometry immediately. This is safe while hidden;
    /// the next show reads the same persisted default frame.
    func resetSizeAndPosition() {
        LiveCaptionPanelFrameStore.clear()
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let frame = LiveCaptionPanelFrameStore.normalizedFrame(
            nil,
            visibleScreens: screens,
            preferredScreen: NSScreen.main?.visibleFrame
        ) else { return }
        setFrame(frame, display: isVisible, animate: isVisible)
        LiveCaptionPanelFrameStore.save(frame)
    }

    private func scheduleFrameSave() {
        saveFrameWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            LiveCaptionPanelFrameStore.save(self.frame)
        }
        saveFrameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func saveFrameNow() {
        saveFrameWork?.cancel()
        saveFrameWork = nil
        LiveCaptionPanelFrameStore.save(frame)
    }
}
