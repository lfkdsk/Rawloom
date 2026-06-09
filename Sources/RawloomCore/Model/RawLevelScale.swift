import Foundation

/// Reconciles the black/white levels read from a capture's DNG with the actual scale of the pixel
/// buffer the pipeline ingests.
///
/// Why this exists — the purple-cast bug:
/// Apple can report `BlackLevel`/`WhiteLevel` at the sensor's *native* bit depth (e.g. 12-bit:
/// `black 528`, `white 4095`) while the captured `pixelBuffer` delivers the same data at a *wider*
/// container depth (14-bit: the values run to ~16383 — roughly `native × 4`). Subtracting the
/// un-scaled black then removes only a fraction of the true pedestal, and the per-channel white-balance
/// gains amplify the large residual into a uniform **magenta/purple cast** across the whole tonal
/// range (not just the shadows). Detecting the power-of-two factor and scaling the levels up to the
/// buffer fixes both the cast and the exposure (the residual pedestal otherwise makes the frame read
/// far brighter than it is, suppressing the auto-brighten gain).
public enum RawLevelScale {

    /// The factor by which to multiply the DNG black/white levels to match the pixel buffer.
    ///
    /// Returns `1` (no change) unless the buffer's data clearly exceeds the DNG white level — the
    /// signature of a bit-depth mismatch. The factor comes from the container/native depth ratio, so
    /// it is exact (e.g. 16384/4096 = 4) rather than estimated from the noisy data maximum.
    ///
    /// - Parameters:
    ///   - dngWhite: the white level parsed from the DNG (sensor-native scale).
    ///   - sampleMax: the maximum raw sample actually present in the pixel buffer.
    ///   - containerMax: the buffer's full-scale value (16383 for `kCVPixelFormatType_14Bayer_*`).
    public static func factor(dngWhite: Float, sampleMax: Int, containerMax: Float = 16383) -> Float {
        // Mismatch only when the DNG white sits well below the container *and* the data overshoots it.
        guard dngWhite > 0,
              dngWhite < containerMax * 0.75,
              Float(sampleMax) > dngWhite * 1.5
        else { return 1 }
        let f = ((containerMax + 1) / (dngWhite + 1)).rounded()
        return max(f, 1)
    }
}
