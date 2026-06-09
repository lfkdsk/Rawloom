import Foundation
import simd

/// Recovers the per-Bayer-position black-level **pedestal** directly from raw samples, for the case
/// where the sensor's true black level is unavailable (e.g. a capture whose DNG metadata could not be
/// parsed).
///
/// Why this exists — the pink-cast bug:
/// Real sensors sit on a black pedestal (~500 codes on a 14-bit iPhone sensor). That pedestal **must
/// be subtracted before white balance**: white balance multiplies red/blue by gains > 1 (green = 1),
/// so an un-subtracted pedestal becomes `R·gainR`, `G`, `B·gainB` — red and blue lifted above green,
/// i.e. a **magenta / pink cast** (strongest in the shadows). See `App/Camera/DNGMetadata.swift`.
///
/// If metadata is missing, subtracting a *zero* black level leaves the entire pedestal in place — the
/// worst possible default. A low percentile of the darkest samples in each CFA channel recovers the
/// pedestal from almost any real scene (which always contains some near-black texture) and, unlike the
/// raw minimum, is robust to stuck/hot pixels.
public enum BlackLevelEstimator {

    /// Estimate the pedestal per Bayer position, order `[R, Gr, Gb, B]` — matching the layout the
    /// ingest kernel (`RawNormalizeParams`) expects, keyed off the CFA's red position.
    ///
    /// - Parameters:
    ///   - percentile: fraction of the darkest samples to skip as outliers before reading the
    ///     pedestal. `0.005` = the 0.5th percentile.
    ///   - cellStride: sample every `cellStride`-th 2×2 Bayer cell (all four phases are read from each
    ///     sampled cell, so parity coverage is exact regardless of stride).
    public static func estimate(
        samples: [UInt16],
        width: Int,
        height: Int,
        cfa: CFAPattern,
        percentile: Double = 0.005,
        cellStride: Int = 4
    ) -> SIMD4<Float> {
        guard width > 1, height > 1, samples.count == width * height else { return SIMD4(repeating: 0) }
        let red = cfa.redPosition
        let step = max(1, cellStride) * 2

        // Buckets in [R, Gr, Gb, B] order (same classification the ingest shader uses).
        var buckets: [[UInt16]] = [[], [], [], []]
        var cy = 0
        while cy + 1 < height {
            var cx = 0
            while cx + 1 < width {
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let x = cx + dx, y = cy + dy
                    let redRow = (y & 1) == red.y
                    let redCol = (x & 1) == red.x
                    let idx = redRow ? (redCol ? 0 : 1) : (redCol ? 2 : 3)
                    buckets[idx].append(samples[y * width + x])
                }
                cx += step
            }
            cy += step
        }

        func pedestal(_ b: [UInt16]) -> Float {
            guard !b.isEmpty else { return 0 }
            let sorted = b.sorted()
            // Skip the darkest `percentile` fraction as outliers — but always at least a couple of
            // samples, so a handful of stuck-low pixels can't drag the estimate to ~0 even on a small
            // (heavily strided) bucket. On a multi-MP frame the percentile term dominates.
            let skip = max(Int((Double(sorted.count) * percentile).rounded(.down)), 2)
            return Float(sorted[min(sorted.count - 1, skip)])
        }
        return SIMD4(pedestal(buckets[0]), pedestal(buckets[1]),
                     pedestal(buckets[2]), pedestal(buckets[3]))
    }
}
