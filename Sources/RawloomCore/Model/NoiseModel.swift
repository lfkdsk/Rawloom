import Foundation

/// Signal-dependent sensor noise model used by the robust merge (`docs/PIPELINE.md` §4.2).
///
/// For a raw sample with linear mean level `μ ∈ [0,1]`, the per-sample noise *variance* is modelled
/// as an affine function of the signal:
///
/// ```
/// σ²(μ) = a·μ + b
/// ```
///
/// where `a` captures **shot noise** (Poisson; scales with the analog gain / ISO) and `b` captures
/// **read noise** (a fixed floor). This is the standard heteroscedastic CMOS model used throughout
/// HDR+ (Hasinoff 2016) and is what lets the merge denoise *harder* in the shadows (where σ is large
/// relative to signal) while trusting detail in the highlights.
///
/// In production the coefficients come from a per-ISO factory calibration of the specific sensor;
/// here we expose them directly and provide a reasonable ISO-driven default so the pipeline is fully
/// functional without calibration files.
public struct NoiseModel: Sendable, Codable, Equatable {
    /// Shot-noise slope (∝ analog gain).
    public var a: Float
    /// Read-noise floor (variance at μ = 0).
    public var b: Float

    public init(a: Float, b: Float) {
        self.a = a
        self.b = b
    }

    /// Noise variance at a given linear signal level.
    @inlinable
    public func variance(at mean: Float) -> Float {
        max(a * mean + b, 1e-8)
    }

    /// Noise standard deviation at a given linear signal level.
    @inlinable
    public func standardDeviation(at mean: Float) -> Float {
        variance(at: mean).squareRoot()
    }

    /// A plausible model derived from ISO when no factory calibration is available.
    ///
    /// Shot-noise variance grows ~linearly with gain (ISO/100); read-noise variance grows ~with the
    /// square of gain at high ISO (amplified read path). Tuned to be sane for a modern phone sensor
    /// where signal is normalised to `[0,1]`.
    public static func estimated(iso: Double, baseISO: Double = 100) -> NoiseModel {
        let gain = Float(max(iso, baseISO) / baseISO)
        let a = 3.0e-5 * gain
        let b = 8.0e-7 * gain * gain
        return NoiseModel(a: a, b: b)
    }
}
