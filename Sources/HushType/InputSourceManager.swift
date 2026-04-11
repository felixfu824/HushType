import Carbon
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "inputsource")

struct InputSourceManager {
    /// Returns the current input source ID string.
    static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }

    /// Returns true if the current input source is a CJK input method.
    static func isCJKInputSourceActive() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return false
        }
        guard let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            return false
        }
        let sourceType = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String

        // CJK input methods are of type "TISTypeKeyboardInputMode"
        if sourceType == kTISTypeKeyboardInputMode as String {
            return true
        }

        // Also check by source ID for common CJK keyboards
        if let sourceID = currentInputSourceID() {
            let cjkPrefixes = [
                "com.apple.inputmethod.TCIM",     // Traditional Chinese
                "com.apple.inputmethod.SCIM",     // Simplified Chinese
                "com.apple.inputmethod.Japanese",  // Japanese
                "com.apple.inputmethod.Korean",    // Korean
            ]
            return cjkPrefixes.contains(where: { sourceID.hasPrefix($0) })
        }

        return false
    }

    /// Switches to the ASCII-capable input source (typically ABC or US keyboard).
    /// Returns the previous input source ID for restoration.
    @discardableResult
    static func switchToASCII() -> String? {
        let previousID = currentInputSourceID()

        let criteria: [String: Any] = [
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
            kTISPropertyInputSourceIsASCIICapable as String: true,
        ]
        guard let sourceList = TISCreateInputSourceList(criteria as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource],
            let asciiSource = sourceList.first else {
            log.warning("No ASCII input source found")
            return previousID
        }

        let status = TISSelectInputSource(asciiSource)
        if status != noErr {
            log.error("Failed to switch to ASCII input source: \(status)")
        } else {
            log.debug("Switched to ASCII input source")
        }

        return previousID
    }

    /// Restores a previously saved input source by ID.
    static func restore(inputSourceID: String) {
        let criteria: [String: Any] = [
            kTISPropertyInputSourceID as String: inputSourceID,
        ]
        guard let sourceList = TISCreateInputSourceList(criteria as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource],
            let source = sourceList.first else {
            log.warning("Could not find input source to restore: \(inputSourceID)")
            return
        }

        let status = TISSelectInputSource(source)
        if status != noErr {
            log.error("Failed to restore input source \(inputSourceID): \(status)")
        } else {
            log.debug("Restored input source: \(inputSourceID)")
        }
    }
}
