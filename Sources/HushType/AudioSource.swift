import Foundation

/// Abstract source of 16kHz mono Float32 PCM samples.
///
/// `LiveCaptionManager` holds an `any AudioSource` — never a concrete type —
/// so v0.6+ can drop in a system-audio adapter (ScreenCaptureKit) without
/// reshaping the manager. The protocol is intentionally tiny: start, stop,
/// and two callbacks.
protocol AudioSource: AnyObject {
    /// Fires per audio buffer on the IO thread that produced it.
    var onSamples: (([Float]) -> Void)? { get set }

    /// Fires when the underlying engine surfaces a mid-session error.
    var onError: ((Error) -> Void)? { get set }

    func start() throws
    func stop()
}

/// `AudioSource` adapter that wraps an `AudioCaptureService` and forwards
/// `start()` / `stop()` to its continuous-capture methods. The adapter does
/// not own the service — the service is supplied at init time so the host
/// (`AppDelegate`) can decide whether to share an instance with the dictation
/// path or use a fresh one.
final class MicAudioSource: AudioSource {
    private let service: AudioCaptureService

    var onSamples: (([Float]) -> Void)? {
        didSet { service.onSamples = onSamples }
    }
    var onError: ((Error) -> Void)? {
        didSet { service.onError = onError }
    }

    init(service: AudioCaptureService) {
        self.service = service
    }

    func start() throws {
        service.onSamples = onSamples
        service.onError = onError
        try service.startContinuousCapture()
    }

    func stop() {
        service.stopContinuousCapture()
        service.onSamples = nil
    }
}
