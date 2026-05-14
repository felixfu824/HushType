import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "hotkey")

final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fires on Right ⌘ + Shift + / (i.e., the "?" key). Single keyDown
    /// event — caller should treat it as a toggle (start if off, stop if
    /// running). Suppressed from propagation so it doesn't open the Help
    /// menu in the focused app.
    var onLiveCaptionToggle: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRightOptionDown = false
    private var otherKeyPressedDuringHold = false

    private static let rightOptionKeyCode: Int64 = 61 // kVK_RightOption
    /// kVK_ANSI_Slash — physical "/" key. With Shift held, this is "?".
    private static let slashKeyCode: Int64 = 44
    /// Device-dependent bit for Right Command on macOS CGEventFlags.
    /// The published `CGEventFlags.maskCommand` only encodes "some cmd is
    /// pressed"; left vs right lives in the lower byte of the raw value.
    /// 0x10 = right cmd; 0x08 = left cmd.
    private static let rightCommandFlagBit: UInt64 = 0x10
    private static let leftCommandFlagBit: UInt64 = 0x08

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            log.error("Failed to create CGEvent tap. Accessibility permission required.")
            promptAccessibilityPermission()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        log.info("Hotkey manager started — listening for Right Option key")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        log.info("Hotkey manager stopped")
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it was disabled by the system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Live Caption toggle: Right ⌘ + Shift + / (= "?"). Single discrete
        // keyDown event. We require the Right command bit specifically and
        // forbid the Left command bit so users who comment-toggle with
        // left-⌘+/ in an editor aren't disrupted, and global "?" Help menu
        // shortcuts on left-⌘ also continue to work.
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.slashKeyCode {
                let flagsRaw = event.flags.rawValue
                let rightCmd = (flagsRaw & Self.rightCommandFlagBit) != 0
                let leftCmd = (flagsRaw & Self.leftCommandFlagBit) != 0
                let shift = event.flags.contains(.maskShift)
                if rightCmd && !leftCmd && shift {
                    log.debug("Live Caption hotkey (Right ⌘ + Shift + /)")
                    onLiveCaptionToggle?()
                    return nil // suppress — don't open Help menu in focused app
                }
            }
        }

        // Track if other keys are pressed during Right Option hold
        if type == .keyDown && isRightOptionDown {
            otherKeyPressedDuringHold = true
            return Unmanaged.passUnretained(event) // pass through
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.rightOptionKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let optionPressed = flags.contains(.maskAlternate)

        if optionPressed && !isRightOptionDown {
            // Right Option pressed
            isRightOptionDown = true
            otherKeyPressedDuringHold = false
            log.debug("Right Option pressed")
            onPress?()
            return nil // suppress
        } else if !optionPressed && isRightOptionDown {
            // Right Option released
            isRightOptionDown = false
            log.debug("Right Option released (otherKeys: \(self.otherKeyPressedDuringHold))")
            if !otherKeyPressedDuringHold {
                onRelease?()
            }
            return nil // suppress
        }

        return Unmanaged.passUnretained(event)
    }

    private func promptAccessibilityPermission() {
        // Last-resort fallback. In the normal flow, OnboardingManager.runIfNeeded()
        // catches missing-permission cases at launch BEFORE we ever call
        // CGEvent.tapCreate, so this code path should rarely fire. Reaching it
        // means the user revoked Accessibility while HushType was running, or
        // the kernel returned the cached "denied" state from a pre-grant call.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Lost"
            alert.informativeText = "HushType lost Accessibility permission and the global hotkey is no longer working.\n\nRe-enable HushType in System Settings → Privacy & Security → Accessibility, then quit and relaunch HushType."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Quit")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            } else {
                NSApp.terminate(nil)
            }
        }
    }
}
