import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "hotkey")

final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRightOptionDown = false
    private var otherKeyPressedDuringHold = false

    private static let rightOptionKeyCode: Int64 = 61 // kVK_RightOption

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
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "HushType needs Accessibility access to listen for the Right Option key.\n\nGo to System Settings → Privacy & Security → Accessibility and add HushType."
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
