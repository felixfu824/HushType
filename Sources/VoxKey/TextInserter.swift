import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "insertion")

struct TextInserter {
    static func insert(_ text: String) {
        guard !text.isEmpty else {
            print("[TextInserter] Empty text, skipping")
            return
        }

        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let savedChangeCount = pasteboard.changeCount
        let savedString = pasteboard.string(forType: .string)
        print("[TextInserter] Saved clipboard: '\(savedString?.prefix(30) ?? "nil")'")

        // Set transcription text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Verify clipboard was set
        let verify = pasteboard.string(forType: .string)
        print("[TextInserter] Clipboard now: '\(verify ?? "nil")'")

        // Handle CJK input method
        var previousInputSourceID: String?
        if InputSourceManager.isCJKInputSourceActive() {
            previousInputSourceID = InputSourceManager.switchToASCII()
            print("[TextInserter] CJK IM detected, switched to ASCII")
            usleep(100_000) // 100ms
        }

        // Simulate Cmd+V
        simulatePaste()
        print("[TextInserter] Cmd+V sent")

        // Wait longer for paste to complete
        usleep(500_000) // 500ms

        // Restore input source
        if let previousID = previousInputSourceID {
            InputSourceManager.restore(inputSourceID: previousID)
            print("[TextInserter] Restored input source")
        }

        // Restore clipboard after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            pasteboard.clearContents()
            if let saved = savedString {
                pasteboard.setString(saved, forType: .string)
            }
            print("[TextInserter] Clipboard restored")
        }

        print("[TextInserter] Insert complete")
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // kVK_ANSI_V = 0x09
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            print("[TextInserter] ERROR: Failed to create CGEvent")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms between key down and up
        keyUp.post(tap: .cghidEventTap)
    }
}
