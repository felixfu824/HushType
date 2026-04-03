import AVFoundation
import os

private let log = Logger(subsystem: "com.felix.voxkey.ios", category: "audio")

final class AudioRecorder: ObservableObject {
    private let audioEngine = AVAudioEngine()
    private var samples: [Float] = []
    private let samplesLock = NSLock()

    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    private var recordingStart: Date?
    private var durationTimer: Timer?

    /// Whether we're actively capturing samples (vs just keeping the engine alive)
    private var isCapturing = false

    func setupSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        log.info("Audio session configured")
    }

    /// Start the audio engine with a mic tap to keep the app alive in background.
    /// This shows the orange mic indicator. Audio data is discarded until startRecording().
    func startListening() {
        guard !audioEngine.isRunning else { return }

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Install a tap that keeps the engine alive. Data is only captured when isCapturing=true.
        installTap(nativeFormat: nativeFormat)

        do {
            try audioEngine.start()
            log.info("Audio engine started (listening mode — orange dot active)")
        } catch {
            log.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    /// Stop the audio engine entirely
    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            isCapturing = false
            isRecording = false
            log.info("Audio engine stopped")
        }
    }

    /// Start capturing audio samples (engine must already be running via startListening)
    func startRecording() {
        guard audioEngine.isRunning else {
            log.error("Cannot record — engine not running. Call startListening() first.")
            return
        }
        guard !isCapturing else { return }

        samplesLock.lock()
        samples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        isCapturing = true
        isRecording = true
        recordingStart = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let start = self?.recordingStart else { return }
            self?.duration = Date().timeIntervalSince(start)
        }
        log.info("Recording started (capturing samples)")
    }

    /// Stop capturing and return the recorded samples
    func stopRecording() -> [Float] {
        guard isCapturing else { return [] }

        isCapturing = false
        isRecording = false
        durationTimer?.invalidate()
        durationTimer = nil

        samplesLock.lock()
        let result = samples
        samples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        let dur = Double(result.count) / 16000.0
        log.info("Stopped capture: \(result.count) samples (\(String(format: "%.1f", dur))s)")

        // Note: engine keeps running (listening mode) — don't stop it here
        return result
    }

    // MARK: - Private

    private func installTap(nativeFormat: AVAudioFormat) {
        let targetSampleRate: Double = 16000
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            log.error("Failed to create target format")
            return
        }

        let converter = AVAudioConverter(from: nativeFormat, to: targetFormat)

        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self, self.isCapturing else { return }  // Skip if not capturing

            let pcmBuffer: AVAudioPCMBuffer
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetSampleRate / nativeFormat.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard error == nil else { return }
                pcmBuffer = converted
            } else {
                pcmBuffer = buffer
            }

            guard let channelData = pcmBuffer.floatChannelData?[0] else { return }
            let frameCount = Int(pcmBuffer.frameLength)
            let newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

            self.samplesLock.lock()
            self.samples.append(contentsOf: newSamples)
            self.samplesLock.unlock()
        }
    }
}
