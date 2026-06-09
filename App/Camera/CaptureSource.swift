import Foundation
import RawloomCore

/// Where a burst of raw frames comes from. The pipeline only consumes `[RawFrame]`, so the same
/// processing runs on device (AVFoundation ZSL raw burst) and in the Simulator/previews (synthetic).
/// See `docs/ARCHITECTURE.md` → "Capture is an abstraction".
protocol CaptureSource: AnyObject {
    /// Whether this source can actually capture on the current hardware.
    var isAvailable: Bool { get }

    /// Begin previewing (start the session / spin up the generator). Safe to call repeatedly.
    func start() async

    /// Stop previewing and release resources.
    func stop()

    /// Capture (or assemble, for ZSL) a burst for the given mode.
    func captureBurst(mode: CaptureMode) async throws -> [RawFrame]
}

enum CaptureError: Error, LocalizedError {
    case noCamera
    case rawUnsupported
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No camera is available on this device."
        case .rawUnsupported: return "This camera does not support raw capture."
        case .captureFailed(let m): return "Capture failed: \(m)"
        }
    }
}

/// Picks the right capture source for the current environment: the real camera on device, the
/// synthetic source in the Simulator (which has no camera).
enum CaptureSourceFactory {
    static func make() -> CaptureSource {
        #if targetEnvironment(simulator)
        return SyntheticCaptureSource()
        #else
        let camera = AVFoundationCaptureSource()
        return camera.isAvailable ? camera : SyntheticCaptureSource()
        #endif
    }
}
