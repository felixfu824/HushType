import Foundation
import os

private let log = Logger(subsystem: "com.felix.hushtype.ios", category: "transcriber")

struct TranscriptionResponse: Codable {
    let text: String
}

/// URLSession delegate that allows insecure HTTP connections (bypasses ATS)
private class InsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Accept any server certificate (for local/Tailscale HTTP connections)
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class RemoteTranscriber {

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: InsecureSessionDelegate(), delegateQueue: nil)
    }()

    var serverURL: URL {
        let urlString = AppGroup.userDefaults.string(forKey: AppGroup.serverURL)
            ?? "http://localhost:8000"
        return URL(string: urlString)!
    }

    /// Test if the server is reachable
    func testConnection() async throws -> Bool {
        var request = URLRequest(url: serverURL)
        request.timeoutInterval = 5

        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            return http.statusCode < 500
        }
        return false
    }

    /// Send audio samples to Mac server and get transcription
    func transcribe(samples: [Float], language: String? = nil) async throws -> String {
        let wavData = WAVEncoder.encode(samples: samples)
        let url = serverURL.appendingPathComponent("v1/audio/transcriptions")

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()

        // file field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.append("\r\n")

        // model field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        // Same weights as macOS HushType's aufklarer/Qwen3-ASR-0.6B-MLX-4bit
        // mlx-community version has preprocessor_config.json needed by mlx-audio server
        body.append("mlx-community/Qwen3-ASR-0.6B-4bit")
        body.append("\r\n")

        // language field (optional)
        if let language {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.append(language)
            body.append("\r\n")
        }

        body.append("--\(boundary)--\r\n")

        let startTime = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await session.upload(for: request, from: body)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            log.error("Server error \(statusCode): \(errorBody)")
            throw TranscriberError.serverError(statusCode, errorBody)
        }

        // mlx-audio returns NDJSON (one JSON object per line)
        let text = parseNDJSON(data)
        log.info("Transcription (\(String(format: "%.2f", elapsed))s): \(text)")
        return text
    }

    private func parseNDJSON(_ data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8) else { return "" }

        let lines = raw.split(separator: "\n").reversed()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let jsonData = trimmed.data(using: .utf8),
               let obj = try? JSONDecoder().decode(TranscriptionResponse.self, from: jsonData) {
                return obj.text
            }
        }

        // Fallback: try parsing the whole thing as a single JSON
        if let obj = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) {
            return obj.text
        }

        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum TranscriberError: LocalizedError {
        case serverError(Int, String)

        var errorDescription: String? {
            switch self {
            case .serverError(let code, let body):
                return "Server error \(code): \(body)"
            }
        }
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
