import AVFoundation
import XCTest
@testable import HushType

/// A deliberately opt-in, single-request smoke test for the production cloud
/// dictation engines. It never runs as part of the normal test suite.
final class CloudDictationIntegrationTests: XCTestCase {
    private enum Provider: String {
        case gemini
        case openai

        var displayName: String {
            switch self {
            case .gemini: return "Gemini"
            case .openai: return "OpenAI"
            }
        }
    }

    func testShortestViableCloudDictation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LAMITYPE_RUN_CLOUD_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LAMITYPE_RUN_CLOUD_INTEGRATION=1 to allow one paid cloud request.")
        }

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        AppSupportPaths.configure(
            root: appSupport.appendingPathComponent("Lamitype", isDirectory: true)
        )

        let provider = try selectedProvider(environment: environment)
        guard hasConfiguredKey(for: provider) else {
            throw XCTSkip("No configured \(provider.displayName) key; no request was made.")
        }

        // Generate the payload before constructing/calling the engine. A local
        // speech-synthesis problem must never consume a cloud request.
        let audio = try Self.makeOneSecondHelloAudio()
        XCTAssertEqual(audio.count, 16_000)

        let engine: any TranscriptionEngine
        let model: String
        switch provider {
        case .gemini:
            engine = GeminiTranscribeEngine()
            model = AppConfig.shared.cloudDictationModelGemini
        case .openai:
            engine = OpenAITranscribeEngine()
            model = AppConfig.shared.cloudDictationModelOpenAI
        }

        // This is intentionally the only cloud call in the test. The printed
        // diagnostics contain provider/model/duration only, never credentials.
        print(
            "[CloudDictationIntegration] starting provider=\(provider.displayName) "
                + "model=\(model) audio_seconds=1.00 requests=1 "
                + "estimated_cost_usd=<0.001"
        )
        let startedAt = ContinuousClock.now
        let transcript = try await engine.transcribe(audio: audio, language: "english")
        let elapsed = startedAt.duration(to: .now)
        let normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        print(
            "[CloudDictationIntegration] completed provider=\(provider.displayName) "
                + "elapsed=\(elapsed)"
        )

        XCTAssertFalse(normalized.isEmpty, "Cloud transcription should not be empty.")
        XCTAssertLessThan(normalized.count, 80, "One spoken word should yield a short transcript.")
        XCTAssertTrue(
            normalized.contains("hello"),
            "Expected the synthesized word ‘hello’ in the transcript; got: \(transcript)"
        )
    }

    private func selectedProvider(environment: [String: String]) throws -> Provider {
        if let explicit = environment["LAMITYPE_CLOUD_INTEGRATION_PROVIDER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !explicit.isEmpty {
            guard let provider = Provider(rawValue: explicit) else {
                throw XCTSkip(
                    "LAMITYPE_CLOUD_INTEGRATION_PROVIDER must be ‘gemini’ or ‘openai’; no request was made."
                )
            }
            return provider
        }

        // Without an explicit provider, only honor an installed-app preference
        // that is already set to Gemini. This avoids silently choosing a paid
        // provider (and avoids ever exercising Live Translated Caption).
        let configured = UserDefaults(suiteName: "com.felix.hushtype")?
            .string(forKey: "hushtype.dictationEngine")
        guard configured == Provider.gemini.rawValue else {
            throw XCTSkip(
                "Installed Lamitype dictation is not set to Gemini. Set it there, or explicitly set LAMITYPE_CLOUD_INTEGRATION_PROVIDER; no request was made."
            )
        }
        return .gemini
    }

    private func hasConfiguredKey(for provider: Provider) -> Bool {
        switch provider {
        case .gemini:
            switch GeminiKeyStore.load() {
            case .ok, .unusualFormat: return true
            case .empty: return false
            }
        case .openai:
            switch OpenAIKeyStore.load() {
            case .ok, .unusualFormat: return true
            case .empty: return false
            }
        }
    }

    private static func makeOneSecondHelloAudio() throws -> [Float] {
        // AVSpeechSynthesizer.write can wait forever in a headless XCTest
        // process because its callback delivery depends on an app run loop.
        // macOS's local `say` executable provides the same on-device voices
        // but exits deterministically after writing an audio file.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamitype-cloud-smoke-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "--data-format=LEF32@16000",
            "-o", outputURL.path,
            "hello",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw XCTSkip("Local speech synthesis could not start; no request was made.")
        }
        guard process.terminationStatus == 0 else {
            throw XCTSkip("Local speech synthesis failed; no request was made.")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: outputURL)
        } catch {
            throw XCTSkip("Local synthesized audio could not be read; no request was made.")
        }
        let frameCapacity = AVAudioFrameCount(file.length)
        guard frameCapacity > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCapacity
              ) else {
            throw XCTSkip("Local speech synthesis produced no audio; no request was made.")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw XCTSkip("Local synthesized audio could not be decoded; no request was made.")
        }
        guard let channels = buffer.floatChannelData else {
            throw XCTSkip("Local speech was not Float32 PCM; no request was made.")
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else {
            throw XCTSkip("Local speech synthesis produced no samples; no request was made.")
        }
        var mono = [Float]()
        mono.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += channels[channel][frame]
            }
            mono.append(sample / Float(channelCount))
        }

        let resampled = linearResample(
            mono,
            from: buffer.format.sampleRate,
            to: 16_000
        )
        return Array(resampled.prefix(16_000))
            + Array(repeating: 0, count: max(0, 16_000 - resampled.count))
    }

    private static func linearResample(
        _ input: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) -> [Float] {
        guard !input.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        let outputCount = max(1, Int((Double(input.count) * targetRate / sourceRate).rounded()))
        let scale = sourceRate / targetRate

        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) * scale
            let lower = min(Int(sourcePosition), input.count - 1)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            return input[lower] + ((input[upper] - input[lower]) * fraction)
        }
    }
}
