import AVFoundation
import Foundation
import ScreenCaptureKit
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "systemAudio")

enum SystemAudioError: Error, LocalizedError {
    case appNotRunning(bundleID: String)
    case noDisplay
    case converterSetupFailed
    case streamSetupFailed(Error)

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let id):
            return "App \(id) is not running. Pick a different source."
        case .noDisplay:
            return "No display is available to capture from."
        case .converterSetupFailed:
            return "Could not set up the audio converter for system audio capture."
        case .streamSetupFailed(let err):
            return "Could not start the system audio stream: \(err.localizedDescription)"
        }
    }
}

/// `AudioSource` adopter that captures audio from a single running app via
/// ScreenCaptureKit (`SCStream`). Downmixes and resamples the SCK output
/// (typically 48 kHz stereo Float32) to 16 kHz mono Float32 to match
/// `MicAudioSource` and feed `LiveCaptionWorker` directly.
///
/// Permission: `NSScreenCaptureUsageDescription` in Info.plist. Permission
/// prompt is triggered by the first call to `SCShareableContent.current` in
/// any process; `SystemAudioPermissionFlow` owns the user-facing flow before
/// this source is constructed.
///
/// Threading: SCStream invokes our `SCStreamOutput` callback on the
/// `sampleHandlerQueue` we provide. We do the downmix + resample inline on
/// that queue and emit `onSamples` from there — same lifecycle contract as
/// `MicAudioSource`'s tap callback.
final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onSamples: (([Float]) -> Void)?
    var onError: ((Error) -> Void)?

    private let bundleID: String

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat
    private let sampleQueue = DispatchQueue(label: "hushtype.systemAudio.io", qos: .userInteractive)

    init(bundleID: String) {
        self.bundleID = bundleID
        // 16 kHz mono Float32 non-interleaved — matches MicAudioSource output.
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        super.init()
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw SystemAudioError.streamSetupFailed(error)
        }

        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw SystemAudioError.appNotRunning(bundleID: bundleID)
        }
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            including: [app],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        // Width/height required even for audio-only — keep tiny to minimize
        // any incidental video work.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            log.error("SCStream start failed: \(error.localizedDescription, privacy: .public)")
            throw SystemAudioError.streamSetupFailed(error)
        }

        self.stream = stream
        log.info("System audio capture started for \(self.bundleID, privacy: .public)")
    }

    func stop() {
        let toStop = stream
        stream = nil
        converter = nil
        inputFormat = nil
        Task { [toStop] in
            try? await toStop?.stopCapture()
        }
        log.info("System audio capture stopped")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPtr.pointee

        // Build / reuse converter on first packet (input format may differ from
        // what we requested if the system has its own preferences).
        if converter == nil || inputFormat == nil {
            guard let avFormat = AVAudioFormat(streamDescription: asbdPtr) else {
                onError?(SystemAudioError.converterSetupFailed)
                return
            }
            self.inputFormat = avFormat
            self.converter = AVAudioConverter(from: avFormat, to: targetFormat)
            if self.converter == nil {
                onError?(SystemAudioError.converterSetupFailed)
                return
            }
            log.info("Configured audio converter: \(avFormat.sampleRate, privacy: .public)Hz x\(avFormat.channelCount, privacy: .public)ch → 16000Hz x1ch")
        }

        guard let converter, let inputFormat else { return }

        // Convert CMSampleBuffer → AVAudioPCMBuffer (input format).
        let numFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard numFrames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: numFrames) else {
            return
        }
        inputBuffer.frameLength = numFrames

        // Copy interleaved bytes from CMSampleBuffer into AVAudioPCMBuffer's storage.
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let totalBytes = Int(numFrames) * bytesPerFrame

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // AVAudioPCMBuffer for an interleaved Float32 input keeps audioBufferList[0].mData as
        // the interleaved storage. We copy CMBlockBuffer bytes into that pointer.
        var dest: UnsafeMutableRawPointer?
        let abl = inputBuffer.mutableAudioBufferList
        if inputFormat.isInterleaved {
            dest = UnsafeMutableRawPointer(abl.pointee.mBuffers.mData)
        } else {
            // Non-interleaved float32: there's one mBuffer per channel. SCStream
            // typically delivers interleaved, but defend against the
            // non-interleaved case by writing to channel 0 only.
            dest = UnsafeMutableRawPointer(abl.pointee.mBuffers.mData)
        }
        guard let dest else { return }

        let copyStatus = CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: totalBytes,
            destination: dest
        )
        guard copyStatus == kCMBlockBufferNoErr else { return }

        // Resample / downmix to 16 kHz mono.
        let outFrameCapacity = AVAudioFrameCount(
            Double(numFrames) * 16_000 / inputFormat.sampleRate + 32
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outFrameCapacity
        ) else { return }

        var convertError: NSError?
        var sentInput = false
        let status = converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            if sentInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            sentInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error || convertError != nil {
            log.error("Converter error: \(convertError?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }

        let outCount = Int(outputBuffer.frameLength)
        guard outCount > 0, let outPtr = outputBuffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: outPtr, count: outCount))
        onSamples?(samples)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("SCStream stopped with error: \(error.localizedDescription, privacy: .public)")
        onError?(error)
    }
}
