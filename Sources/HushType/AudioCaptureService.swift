import AVFoundation
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "audio")

final class AudioCaptureService {
    private let audioEngine = AVAudioEngine()
    private var samples: [Float] = []
    private let samplesLock = NSLock()
    private var isRecording = false

    /// Called on each audio buffer with the current RMS level (0.0–1.0).
    var onRMSLevel: ((Float) -> Void)?

    func startRecording() {
        guard !isRecording else { return }

        samplesLock.lock()
        samples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        let targetSampleRate: Double = 16000
        let targetChannels: AVAudioChannelCount = 1

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            log.error("Failed to create target audio format")
            return
        }

        let needsConversion = nativeFormat.sampleRate != targetSampleRate
            || nativeFormat.channelCount != targetChannels

        let converter: AVAudioConverter?
        if needsConversion {
            converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
            if converter == nil {
                log.warning("Could not create audio converter, recording in native format")
            }
        } else {
            converter = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let pcmBuffer: AVAudioPCMBuffer
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetSampleRate / nativeFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCapacity
                ) else { return }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard status != .error, error == nil else {
                    log.error("Audio conversion error: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                pcmBuffer = convertedBuffer
            } else {
                pcmBuffer = buffer
            }

            guard let channelData = pcmBuffer.floatChannelData?[0] else { return }
            let frameCount = Int(pcmBuffer.frameLength)

            // Calculate RMS
            var rms: Float = 0
            for i in 0..<frameCount {
                rms += channelData[i] * channelData[i]
            }
            rms = sqrt(rms / max(Float(frameCount), 1))
            self.onRMSLevel?(rms)

            // Accumulate samples
            let newSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
            self.samplesLock.lock()
            self.samples.append(contentsOf: newSamples)
            self.samplesLock.unlock()
        }

        do {
            try audioEngine.start()
            isRecording = true
            log.info("Recording started (native: \(nativeFormat.sampleRate)Hz → 16000Hz)")
        } catch {
            log.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    func stopRecording() -> [Float] {
        guard isRecording else { return [] }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false

        samplesLock.lock()
        let result = samples
        samples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        let duration = Double(result.count) / 16000.0
        log.info("Recording stopped: \(result.count) samples (\(String(format: "%.1f", duration))s)")
        return result
    }
}
