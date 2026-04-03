import Foundation

enum AppGroup {
    static let id = "group.com.felix.hushtype"

    static var userDefaults: UserDefaults {
        UserDefaults(suiteName: id)!
    }

    /// Shared file container — more reliable than UserDefaults for cross-process IPC
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// Write a command file that the other process can read
    static func writeCommand(_ command: String) {
        guard let dir = containerURL else {
            // Fallback: use UserDefaults anyway
            userDefaults.set(command, forKey: recordCommand)
            userDefaults.set(Date().timeIntervalSince1970, forKey: recordCommandTimestamp)
            return
        }
        let file = dir.appendingPathComponent("ipc_command.txt")
        let payload = "\(command)|\(Date().timeIntervalSince1970)"
        try? payload.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Read and clear the command file
    static func readCommand() -> (command: String, timestamp: Double)? {
        guard let dir = containerURL else {
            // Fallback: use UserDefaults
            let ts = userDefaults.double(forKey: recordCommandTimestamp)
            let cmd = userDefaults.string(forKey: recordCommand)
            guard let cmd, ts > 0 else { return nil }
            return (cmd, ts)
        }
        let file = dir.appendingPathComponent("ipc_command.txt")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let parts = content.split(separator: "|")
        guard parts.count == 2, let ts = Double(parts[1]) else { return nil }
        return (String(parts[0]), ts)
    }

    static func clearCommand() {
        if let dir = containerURL {
            let file = dir.appendingPathComponent("ipc_command.txt")
            try? FileManager.default.removeItem(at: file)
        }
        userDefaults.removeObject(forKey: recordCommand)
    }

    /// Write result to shared file
    static func writeResult(_ text: String) {
        userDefaults.set(text, forKey: transcriptionResult)
        userDefaults.set(Date().timeIntervalSince1970, forKey: transcriptionTimestamp)
        // Also write to file
        if let dir = containerURL {
            let file = dir.appendingPathComponent("ipc_result.txt")
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Read and clear result
    static func readResult() -> String? {
        if let dir = containerURL {
            let file = dir.appendingPathComponent("ipc_result.txt")
            if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty {
                try? FileManager.default.removeItem(at: file)
                return text
            }
        }
        // Fallback
        return userDefaults.string(forKey: transcriptionResult)
    }

    /// Write heartbeat
    static func writeHeartbeat() {
        userDefaults.set(Date().timeIntervalSince1970, forKey: appAliveTimestamp)
        if let dir = containerURL {
            let file = dir.appendingPathComponent("ipc_heartbeat.txt")
            try? "\(Date().timeIntervalSince1970)".write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Check heartbeat
    static func isAppAlive() -> Bool {
        if let dir = containerURL {
            let file = dir.appendingPathComponent("ipc_heartbeat.txt")
            if let content = try? String(contentsOf: file, encoding: .utf8),
               let ts = Double(content) {
                return Date().timeIntervalSince1970 - ts < 5
            }
        }
        // Fallback
        let ts = userDefaults.double(forKey: appAliveTimestamp)
        guard ts > 0 else { return false }
        return Date().timeIntervalSince1970 - ts < 5
    }

    // MARK: - Keys
    static let serverURL = "serverURL"
    static let language = "language"
    static let transcriptionResult = "transcriptionResult"
    static let transcriptionTimestamp = "transcriptionTimestamp"
    static let isRecording = "isRecording"
    static let errorMessage = "errorMessage"
    static let appIsAlive = "appIsAlive"
    static let appAliveTimestamp = "appAliveTimestamp"

    // Polling-based IPC (fallback for Darwin notifications)
    static let recordCommand = "recordCommand"           // "start" or "stop"
    static let recordCommandTimestamp = "recordCommandTimestamp"
}
