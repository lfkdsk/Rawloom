import Foundation
import simd

/// Per-frame metadata that travels with a raw mosaic through the pipeline and into the DNG.
public struct RawImageMetadata: Sendable {
    /// Sensor CFA pattern of `samples` as captured (before RGGB canonicalisation).
    public var cfa: CFAPattern
    /// Per-Bayer-position black level in raw code units, order `[R, Gr, Gb, B]`.
    public var blackLevel: SIMD4<Float>
    /// Saturation level in raw code units (e.g. 16383 for a 14-bit sensor).
    public var whiteLevel: Float
    /// ISO (sensor sensitivity) the frame was shot at.
    public var iso: Double
    /// Exposure duration in seconds.
    public var exposureDuration: Double
    /// Capture timestamp in seconds (monotonic). Used for reference selection tie-breaks.
    public var timestamp: Double
    /// As-shot white-balance gains.
    public var whiteBalance: WhiteBalanceGains
    /// Camera-native-RGB → linear-sRGB matrix (CCM). Identity if unknown.
    public var colorMatrix: ColorMatrix
    /// Optional lens-shading correction map.
    public var lensShading: LensShadingMap?
    /// Sensor noise model at this ISO. Derived from `iso` if not supplied.
    public var noise: NoiseModel

    public init(
        cfa: CFAPattern,
        blackLevel: SIMD4<Float>,
        whiteLevel: Float,
        iso: Double,
        exposureDuration: Double,
        timestamp: Double,
        whiteBalance: WhiteBalanceGains = .neutral,
        colorMatrix: ColorMatrix = .identity,
        lensShading: LensShadingMap? = nil,
        noise: NoiseModel? = nil
    ) {
        self.cfa = cfa
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.iso = iso
        self.exposureDuration = exposureDuration
        self.timestamp = timestamp
        self.whiteBalance = whiteBalance
        self.colorMatrix = colorMatrix
        self.lensShading = lensShading
        self.noise = noise ?? NoiseModel.estimated(iso: iso)
    }
}

/// A single raw Bayer frame: one channel of mosaiced samples plus metadata.
///
/// `samples` is row-major, `width * height` 16-bit codes (sensors are ≤16-bit; we store 16). The
/// pipeline normalises to linear `[0,1]` floats on upload using `blackLevel`/`whiteLevel`.
public struct RawFrame: Sendable {
    public let width: Int
    public let height: Int
    public var samples: [UInt16]
    public var metadata: RawImageMetadata

    public init(width: Int, height: Int, samples: [UInt16], metadata: RawImageMetadata) {
        precondition(samples.count == width * height, "samples must be width*height")
        precondition(width % 2 == 0 && height % 2 == 0, "Bayer dimensions must be even")
        self.width = width
        self.height = height
        self.samples = samples
        self.metadata = metadata
    }

    /// Normalised linear value at `(x, y)` after black/white-level correction, clamped to `[0,1]`.
    @inlinable
    public func normalized(x: Int, y: Int) -> Float {
        let raw = Float(samples[y * width + x])
        // Use the average black level; per-position black is applied exactly on the GPU.
        let black = (metadata.blackLevel.x + metadata.blackLevel.y
                     + metadata.blackLevel.z + metadata.blackLevel.w) / 4
        let denom = max(metadata.whiteLevel - black, 1)
        return min(max((raw - black) / denom, 0), 1)
    }

    /// Mean normalised brightness over a subsample — a cheap exposure proxy used to derive the
    /// "memorised gain" that compensates the capture under-exposure during finishing.
    public func meanBrightness(sampleStride: Int = 4) -> Double {
        var acc = 0.0
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                acc += Double(normalized(x: x, y: y))
                count += 1
                x += sampleStride
            }
            y += sampleStride
        }
        return count > 0 ? acc / Double(count) : 0
    }

    /// A sharpness score (mean gradient magnitude of the green channel), used to pick the reference
    /// frame on the CPU when no GPU is available. See ``ReferenceSelector``.
    public func greenSharpness() -> Double {
        // Sample the two green sites of each 2×2 cell. For RGGB those are (1,0) and (0,1).
        var acc = 0.0
        var count = 0
        let step = 2
        var y = 2
        while y < height - 2 {
            var x = 2
            while x < width - 2 {
                let c = Float(samples[y * width + x])
                let gx = Float(samples[y * width + (x + step)]) - c
                let gy = Float(samples[(y + step) * width + x]) - c
                acc += Double(abs(gx) + abs(gy))
                count += 1
                x += step
            }
            y += step
        }
        return count > 0 ? acc / Double(count) : 0
    }
}
