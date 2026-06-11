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

    // MARK: Lens & zoom (real camera only; synthetic returns empty / no-ops)

    /// The selectable physical lenses, widest-first. Empty when there's nothing to switch.
    var lenses: [CameraLens] { get }
    /// `id` of the active lens.
    var selectedLensID: String? { get }
    /// Switch the active physical lens (reconfigures the session input).
    func select(lensID: String) async
    /// Current digital zoom factor on the active lens.
    var zoomFactor: CGFloat { get }
    /// Maximum (capped) digital zoom on the active lens.
    var maxZoomFactor: CGFloat { get }
    /// Set the digital zoom factor (clamped to the lens's range).
    func setZoom(_ factor: CGFloat)

    // MARK: Manual controls (real camera only; synthetic no-ops)

    /// Ranges + current readings for the manual sliders.
    var manualCapabilities: ManualCapabilities { get }
    /// Tap-to-focus & meter at a normalised (0…1) point in the viewfinder.
    func focusAndExpose(at point: CGPoint)
    /// Lock/unlock auto-exposure & auto-focus at their current values.
    func setExposureFocusLocked(_ locked: Bool)
    /// Exposure compensation (EV) while staying in auto-exposure.
    func setExposureBias(_ ev: Float)
    /// Fully manual exposure (locks ISO + shutter).
    func setManualExposure(iso: Float, shutter: Double)
    func resetAutoExposure()
    /// Manual white balance by colour temperature (Kelvin).
    func setManualWhiteBalance(kelvin: Float)
    func resetAutoWhiteBalance()
    /// Manual focus by lens position (0 = near … 1 = far).
    func setManualFocus(_ lensPosition: Float)
    func resetAutoFocus()

    /// Live 64-bin luma histogram (values normalised to the tallest bin), delivered on the main queue
    /// from the preview stream. Set to `nil` to stop sampling. Synthetic never calls it.
    var onHistogram: (([Float]) -> Void)? { get set }

    // MARK: Apple ProRAW (single-shot; bypasses the multi-frame merge)

    /// Whether the active camera supports Apple ProRAW.
    var proRAWSupported: Bool { get }
    /// Capture one Apple ProRAW frame and return its DNG bytes (no burst, no merge).
    func captureProRAW() async throws -> Data

    /// Flash mode applied to captures.
    var flashMode: FlashMode { get set }
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
