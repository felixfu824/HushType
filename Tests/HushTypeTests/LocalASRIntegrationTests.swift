import AVFoundation
import XCTest
@testable import HushType

/// Opt-in end-to-end smoke test for the shipping local dictation path.
///
/// Run with:
///
///     HUSHTYPE_RUN_ASR_INTEGRATION=1 swift test --disable-sandbox \
///       --filter LocalASRIntegrationTests
///
/// The test deliberately uses only macOS's local speech synthesizer and an
/// already-cached Qwen3-ASR model. It never calls a cloud transcription API,
/// and redirects any unexpected Hugging Face fallback request to loopback.
final class LocalASRIntegrationTests: XCTestCase {
    private let modelID = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    private let phrase = "Hello world. This is a local test."

    func testSynthesizedSpeechThroughLocalQwenAndPostProcessor() async throws {
        guard ProcessInfo.processInfo.environment["HUSHTYPE_RUN_ASR_INTEGRATION"] == "1" else {
            throw XCTSkip("Set HUSHTYPE_RUN_ASR_INTEGRATION=1 to run the local ASR integration test")
        }

        guard cachedModelDirectory() != nil else {
            throw XCTSkip("The complete local Qwen3-ASR cache is unavailable; refusing to download it")
        }

        guard try installMetallibBesideTestExecutable() else {
            throw XCTSkip("mlx.metallib is unavailable; build it locally before running the ASR integration test")
        }

        let audio: [Float]
        do {
            audio = try synthesize16kMono(phrase)
        } catch SynthesisError.noAudio {
            throw XCTSkip("macOS speech synthesis produced no audio (for example, while the login session is locked)")
        }

        XCTAssertGreaterThan(audio.count, 16_000, "The synthesized fixture should contain more than one second of audio")

        // Preserve both an absent preference and a custom model preference.
        let modelPreferenceKey = "hushtype.modelId"
        let savedModelPreference = UserDefaults.standard.object(forKey: modelPreferenceKey)
        AppConfig.shared.modelId = modelID
        defer {
            if let savedModelPreference {
                UserDefaults.standard.set(savedModelPreference, forKey: modelPreferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: modelPreferenceKey)
            }
        }

        // speech-swift validates its local snapshot first. If that validation
        // unexpectedly fails, make the fallback incapable of reaching the Hub.
        let savedHFEndpoint = ProcessInfo.processInfo.environment["HF_ENDPOINT"]
        setenv("HF_ENDPOINT", "http://127.0.0.1:9", 1)
        defer {
            if let savedHFEndpoint {
                setenv("HF_ENDPOINT", savedHFEndpoint, 1)
            } else {
                unsetenv("HF_ENDPOINT")
            }
        }

        let engine = Qwen3TranscriptionEngine()
        try await engine.load()
        defer { engine.unload() }

        // Qwen3TranscriptionEngine.transcribe is the production entry point;
        // it applies DictationPostProcessor before returning this value.
        let output = try await engine.transcribe(audio: audio, language: "en")
        let words = Set(
            output.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let expected = Set(["hello", "world", "local", "test"])
        let matched = words.intersection(expected)

        XCTAssertGreaterThanOrEqual(
            matched.count,
            3,
            "Expected at least three stable fixture words after local ASR + post-processing; output: \(output)"
        )
    }

    // MARK: - Offline cache preflight

    /// Returns a model directory only when it contains the files needed by
    /// Qwen3-ASR and the metadata needed for speech-swift's offline snapshot
    /// validation. This preflight happens before model loading can touch Hub.
    private func cachedModelDirectory() -> URL? {
        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        let base = caches.appendingPathComponent("qwen3-speech", isDirectory: true)
        let components = modelID.split(separator: "/").map(String.init)
        guard components.count == 2 else { return nil }

        let hubStyle = base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(components[0], isDirectory: true)
            .appendingPathComponent(components[1], isDirectory: true)

        let flatName = modelID.replacingOccurrences(of: "/", with: "_")
        let candidates = [hubStyle, base.appendingPathComponent(flatName, isDirectory: true)]

        for directory in candidates where isCompleteOfflineSnapshot(directory) {
            return directory
        }
        return nil
    }

    private func isCompleteOfflineSnapshot(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        let requiredNames = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"]
        let metadataDirectory = directory
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("download", isDirectory: true)

        guard let rootFiles = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        let regularFiles = rootFiles.filter { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
        let names = Set(regularFiles.map(\.lastPathComponent))

        guard requiredNames.allSatisfy(names.contains),
              regularFiles.contains(where: { $0.pathExtension == "safetensors" }) else {
            return false
        }

        // Hub-style snapshots require one metadata sidecar per materialized
        // root file. A legacy flat snapshot has no sidecars, so treat it as
        // unavailable instead of risking speech-swift's online fallback.
        return regularFiles.allSatisfy { file in
            let sidecar = metadataDirectory.appendingPathComponent(file.lastPathComponent + ".metadata")
            return fileManager.fileExists(atPath: sidecar.path)
        }
    }

    /// MLX resolves its shaders beside the running executable. App builds put
    /// the compiled library there during `make install`, but raw `swift test`
    /// does not. Reuse a locally built copy so the test remains offline.
    private func installMetallibBesideTestExecutable() throws -> Bool {
        let fileManager = FileManager.default
        guard let executableDirectory = Bundle(for: Self.self).executableURL?.deletingLastPathComponent() else {
            return false
        }

        let destination = executableDirectory.appendingPathComponent("mlx.metallib")
        if fileManager.fileExists(atPath: destination.path) { return true }

        let repositoryRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates = [
            repositoryRoot.appendingPathComponent(".build/debug/mlx.metallib"),
            repositoryRoot.appendingPathComponent(".build/release/mlx.metallib"),
            URL(fileURLWithPath: "/Applications/HushType.app/Contents/MacOS/mlx.metallib"),
        ]

        guard let source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return false
        }
        try fileManager.copyItem(at: source, to: destination)
        return true
    }

    // MARK: - Local audio fixture

    private enum SynthesisError: Error {
        case processFailed(Int32)
        case noAudio
        case conversionFailed(String)
    }

    private func synthesize16kMono(_ text: String) throws -> [Float] {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hushtype-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let audioURL = temporaryDirectory.appendingPathComponent("fixture.aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "-r", "165", "-o", audioURL.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SynthesisError.processFailed(process.terminationStatus)
        }

        let inputFile = try AVAudioFile(forReading: audioURL)
        guard inputFile.length > 0 else { throw SynthesisError.noAudio }

        let inputFormat = inputFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SynthesisError.conversionFailed("Could not create a 16 kHz mono converter")
        }

        let inputCapacity = AVAudioFrameCount(inputFile.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
            throw SynthesisError.conversionFailed("Could not allocate the source audio buffer")
        }
        try inputFile.read(into: inputBuffer)

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 256
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw SynthesisError.conversionFailed("Could not allocate the converted audio buffer")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil,
              outputBuffer.frameLength > 0,
              let channel = outputBuffer.floatChannelData?[0] else {
            throw SynthesisError.conversionFailed(conversionError?.localizedDescription ?? "No converted samples")
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }
}
