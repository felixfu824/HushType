import Foundation

/// Abstract source of 16kHz mono Float32 PCM samples.
///
/// `LiveCaptionManager` holds an `any AudioSource` — never a concrete type —
/// so adopters can drop in without reshaping the manager. The protocol is
/// intentionally tiny: start, stop, and two callbacks.
///
/// `start()` is `async throws` because `SystemAudioSource` needs to await
/// `SCShareableContent.current` and `SCStream.startCapture()`. Synchronous
/// adopters (like `MicAudioSource`) implement an immediate-returning `async`
/// function.
protocol AudioSource: AnyObject, Sendable {
    /// Fires per audio buffer on the IO thread that produced it.
    var onSamples: (([Float]) -> Void)? { get set }

    /// Fires when the underlying engine surfaces a mid-session error.
    var onError: ((Error) -> Void)? { get set }

    func start() async throws
    func stop()
}

/// `AudioSource` adapter that wraps an `AudioCaptureService` and forwards
/// `start()` / `stop()` to its continuous-capture methods. The adapter does
/// not own the service — the service is supplied at init time so the host
/// (`AppDelegate`) can decide whether to share an instance with the dictation
/// path or use a fresh one.
final class MicAudioSource: AudioSource, @unchecked Sendable {
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

    func start() async throws {
        service.onSamples = onSamples
        service.onError = onError
        try service.startContinuousCapture()
    }

    func stop() {
        service.stopContinuousCapture()
        service.onSamples = nil
    }
}
