import AVFoundation

/// A zoom preset shown in the lens pill (0.5× / 1× / 2× / 5× …). `displayZoom` is the *absolute* zoom
/// relative to the main wide camera (what the UI shows); it is achieved by selecting `deviceType` and
/// setting `videoZoomFactor` on it (optical lens + any digital crop on top).
struct CameraLens: Identifiable, Equatable {
    let id: String
    let label: String                         // "0.5×", "1×", "2×", "5×"
    let deviceType: AVCaptureDevice.DeviceType
    let videoZoomFactor: CGFloat
    let displayZoom: CGFloat

    static func == (a: CameraLens, b: CameraLens) -> Bool { a.id == b.id }

    /// Conventional label for an absolute zoom: "0.5×", "1×", "2×", "5×".
    static func label(displayZoom z: CGFloat) -> String {
        z < 1 ? String(format: "%.1f×", z) : "\(Int(z.rounded()))×"
    }
}

/// The manual-control ranges + current readings reported by the active camera. Drives the slider
/// extents and the "AUTO" defaults in the pro panel. Synthetic reports `supportsManual = false`.
struct ManualCapabilities {
    var supportsManual = false
    var isoRange: ClosedRange<Float> = 100...3200
    var shutterRange: ClosedRange<Double> = (1.0 / 4000)...(1.0 / 4)   // seconds
    var evRange: ClosedRange<Float> = -3...3
    var kelvinRange: ClosedRange<Float> = 2800...8000
    var currentISO: Float = 100
    var currentShutter: Double = 1.0 / 120
    var currentLensPosition: Float = 0.5
}

/// Flash for the capture.
enum FlashMode: String, CaseIterable { case auto, on, off
    var icon: String {
        switch self { case .auto: return "bolt.badge.a.fill"; case .on: return "bolt.fill"; case .off: return "bolt.slash.fill" }
    }
}

/// Viewfinder framing ratio. Crops the preview + the saved JPEG (the raw DNG stays full-sensor).
enum AspectRatio: String, CaseIterable {
    case full = "Full", r4_3 = "4:3", r3_2 = "3:2", r1_1 = "1:1"
    /// width / height for the portrait-oriented frame, or nil for full sensor.
    var portraitRatio: CGFloat? {
        switch self { case .full: return nil; case .r4_3: return 3.0/4.0; case .r3_2: return 2.0/3.0; case .r1_1: return 1 }
    }
}

/// Which artifacts a capture writes. The burst is always Bayer raw (the merge needs it); this only
/// chooses which output files are saved.
struct OutputFormat: OptionSet, Hashable {
    let rawValue: Int
    static let dng  = OutputFormat(rawValue: 1 << 0)
    static let jpeg = OutputFormat(rawValue: 1 << 1)
    /// Save the JPEG as a hybrid SDR+HDR **Ultra HDR** file (gain map) instead of a plain SDR JPEG.
    /// A modifier on `.jpeg`; ignored when `.jpeg` is absent.
    static let hdr  = OutputFormat(rawValue: 1 << 2)
    static let rawAndJpeg: OutputFormat = [.dng, .jpeg, .hdr]

    /// The three presets the UI cycles through. JPEG-bearing presets default to Ultra HDR.
    static let presets: [OutputFormat] = [[.jpeg, .hdr], .dng, .rawAndJpeg]

    var label: String {
        switch (contains(.dng), contains(.jpeg)) {
        case (true, true):  return "RAW+JPEG"
        case (true, false): return "RAW"
        case (false, true): return "JPEG"
        default:            return "—"
        }
    }
}
