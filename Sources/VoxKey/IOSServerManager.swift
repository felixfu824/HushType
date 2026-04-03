import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "ios-server")

/// Manages the iOS server (ios_server.py) as a child process.
/// The server proxies mlx-audio with OpenCC s2twp conversion for iPhone clients.
final class IOSServerManager {
    private var process: Process?
    private(set) var isRunning = false
    private(set) var port: Int = 8000

    var onStatusChanged: ((Bool) -> Void)?

    /// Find ios_server.py by checking multiple locations
    private var scriptPath: String? {
        let candidates: [String] = [
            // In app bundle Resources
            Bundle.main.bundlePath + "/Contents/Resources/ios_server.py",
            // Next to the executable
            (Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent + "/ios_server.py" } ?? ""),
            // Project scripts directory (relative to bundle)
            (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/scripts/ios_server.py",
            // Bundle.main.path (standard API)
            Bundle.main.path(forResource: "ios_server", ofType: "py") ?? "",
        ]

        for path in candidates where !path.isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    func start(port: Int = 8000) {
        guard !isRunning else {
            log.info("Server already running on port \(self.port)")
            return
        }

        guard let script = scriptPath else {
            log.error("ios_server.py not found! Checked app bundle and project directory.")
            return
        }

        self.port = port
        log.info("Starting iOS server: \(script) on port \(port)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", script, "--port", "\(port)"]
        proc.currentDirectoryURL = URL(fileURLWithPath: (script as NSString).deletingLastPathComponent)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for l in line.split(separator: "\n") {
                log.info("[ios_server] \(l)")
            }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.onStatusChanged?(false)
                log.info("iOS server terminated (exit code \(proc.terminationStatus))")
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            onStatusChanged?(true)
            log.info("iOS server started (PID \(proc.processIdentifier))")
        } catch {
            log.error("Failed to start iOS server: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            isRunning = false
            return
        }

        let pid = proc.processIdentifier
        log.info("Stopping iOS server (PID \(pid))...")

        // Kill the entire process group (parent + all children including mlx-audio backend)
        // Negative PID = kill the process group
        kill(-pid, SIGTERM)

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            // Force kill if still alive
            if proc.isRunning {
                kill(-pid, SIGKILL)
            }
        }

        process = nil
        isRunning = false
        onStatusChanged?(false)
        log.info("iOS server stopped")
    }

    deinit {
        stop()
    }
}
