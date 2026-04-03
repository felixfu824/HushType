import Foundation

enum IPC {
    // Keyboard → Main App
    static let startRecording = "com.felix.voxkey.startRecording" as CFString
    static let stopRecording  = "com.felix.voxkey.stopRecording" as CFString

    // Main App → Keyboard
    static let resultReady    = "com.felix.voxkey.resultReady" as CFString
    static let recordingStarted = "com.felix.voxkey.recordingStarted" as CFString
    static let errorOccurred  = "com.felix.voxkey.errorOccurred" as CFString

    static func post(_ name: CFString) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name), nil, nil, true)
    }

    static func observe(_ name: CFString, callback: @escaping () -> Void) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        let box = CallbackBox(callback: callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            ptr,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { box.callback() }
            },
            name,
            nil,
            .deliverImmediately
        )
    }
}

private class CallbackBox {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
}
