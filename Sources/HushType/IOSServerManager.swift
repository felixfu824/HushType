import Foundation
import AppKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "ios-server")

/// Manages the iOS server (ios_server.py) as a child process.
/// The server proxies mlx-audio with OpenCC s2twp conversion for iPhone clients.
final class IOSServerManager {
    private var process: Process?
    private(set) var isRunning = false
    private(set) var port: Int = 8000
    private var earlyOutput: String = ""
    private var startTime: Date?

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
        // macOS GUI apps have a stripped PATH — /usr/bin/env python3 finds
        // Apple's /usr/bin/python3 instead of the user's installed Python.
        // Check common locations where pip packages are actually installed.
        let pythonCandidates = [
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        let python = pythonCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/env python3"
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script, "--port", "\(port)"]
        proc.currentDirectoryURL = URL(fileURLWithPath: (script as NSString).deletingLastPathComponent)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for l in line.split(separator: "\n") {
                log.info("[ios_server] \(l)")
            }
            // Buffer first 5 seconds of output for error reporting
            if let start = self?.startTime, Date().timeIntervalSince(start) < 5 {
                self?.earlyOutput += line
            }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.onStatusChanged?(false)
                let code = proc.terminationStatus
                log.info("iOS server terminated (exit code \(code))")

                // Show alert if process died within 5 seconds (dependency or config error)
                if let start = self?.startTime, Date().timeIntervalSince(start) < 5, code != 0 {
                    self?.showServerError(code: code, output: self?.earlyOutput ?? "")
                }
            }
        }

        do {
            earlyOutput = ""
            startTime = Date()
            try proc.run()
            process = proc
            isRunning = true
            onStatusChanged?(true)
            log.info("iOS server started (PID \(proc.processIdentifier))")
        } catch {
            log.error("Failed to start iOS server: \(error.localizedDescription)")
            showServerError(code: -1, output: error.localizedDescription)
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

    private func showServerError(code: Int32, output: String) {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = detail.count > 800 ? String(detail.suffix(800)) : detail

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "iOS Server Failed to Start"
        alert.informativeText = """
            The server exited with code \(code). This usually means a missing Python dependency.

            See the README for required packages:
            pip3 install "mlx-audio[stt,server]" httpx webrtcvad-wheels setuptools

            Error output:
            \(truncated)
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    deinit {
        stop()
    }
}
