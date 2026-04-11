import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "converter")

struct ChineseConverter {
    private static let openccPath: String = {
        // Prefer bundled opencc inside the app bundle
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("opencc").path,
           FileManager.default.fileExists(atPath: bundlePath) {
            return bundlePath
        }
        // Fallback to Homebrew
        return "/opt/homebrew/bin/opencc"
    }()

    private static let openccDataDir: String? = {
        if let bundleDir = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("opencc_data").path,
           FileManager.default.fileExists(atPath: bundleDir) {
            return bundleDir
        }
        return nil
    }()

    /// Returns true if the text contains any CJK Unified Ideographs (U+4E00–U+9FFF).
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }

    /// Converts Simplified Chinese to Traditional Chinese (Taiwan phrasing) using OpenCC s2twp.
    /// English text and non-CJK characters pass through untouched.
    /// Falls back to original text if opencc is not installed or fails.
    static func convert(_ text: String) -> String {
        guard AppConfig.shared.chineseConversionEnabled else {
            return text
        }

        guard containsCJK(text) else {
            return text
        }

        guard FileManager.default.fileExists(atPath: openccPath) else {
            log.warning("opencc not found at \(openccPath). Install with: brew install opencc")
            return text
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: openccPath)
        if let dataDir = openccDataDir {
            process.arguments = ["-c", "\(dataDir)/s2twp.json"]
        } else {
            process.arguments = ["-c", "s2twp"]
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            log.error("Failed to launch opencc: \(error.localizedDescription)")
            return text
        }

        guard let inputData = text.data(using: .utf8) else { return text }
        inputPipe.fileHandleForWriting.write(inputData)
        inputPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown"
            log.error("opencc failed (status \(process.terminationStatus)): \(errMsg)")
            return text
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let result = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return text
        }

        log.debug("Converted: \(text) → \(result)")
        return result
    }
}
