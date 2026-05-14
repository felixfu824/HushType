import AppKit
import SwiftUI

/// HushType's first persistent Settings window — a non-modal floating
/// `NSWindow` hosting `LiveCaptionEngineSettingsView`. Menu-bar apps have no
/// parent window to attach a sheet to, so this is a window (not a sheet).
///
/// Retained as a `static var` on `StatusBarController` so the same instance
/// survives close-and-reopen. Autosave name pins the user's chosen position
/// between sessions.
@MainActor
final class LiveCaptionEngineSettingsWindowController: NSWindowController, NSWindowDelegate {

    /// Lazy singleton — created on first menu click.
    static let shared: LiveCaptionEngineSettingsWindowController = {
        let controller = LiveCaptionEngineSettingsWindowController()
        return controller
    }()

    private init() {
        let hosting = NSHostingController(rootView: LiveCaptionEngineSettingsView())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Live Caption Settings"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("hushtype.settings.liveCaptionEngine")
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Bring the window to front, activating the app if necessary so the
    /// window can take focus from any frontmost menu-bar invocation.
    func presentAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
