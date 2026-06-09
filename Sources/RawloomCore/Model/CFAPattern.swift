import Foundation

/// The colour-filter-array (Bayer) layout of a raw sensor, described by the colour of the four
/// pixels in the top-left 2×2 block, read left-to-right then top-to-bottom.
///
/// Rawloom canonicalises everything to ``rggb`` internally (see ``CFAPattern/permutationToRGGB``)
/// so the alignment/merge kernels only ever reason about one layout. The original pattern is kept
/// in metadata so the DNG we emit carries the *real* sensor pattern.
public enum CFAPattern: String, Sendable, Codable, CaseIterable {
    case rggb
    case bggr
    case grbg
    case gbrg

    /// Colour of each of the four positions in the 2×2 cell, indexed `[row*2 + col]`.
    /// 0 = Red, 1 = Green, 2 = Blue.
    public var cellColors: (SIMD4<Int>) {
        switch self {
        case .rggb: return SIMD4(0, 1, 1, 2) // R G / G B
        case .bggr: return SIMD4(2, 1, 1, 0) // B G / G R
        case .grbg: return SIMD4(1, 0, 2, 1) // G R / B G
        case .gbrg: return SIMD4(1, 2, 0, 1) // G B / R G
        }
    }

    /// The `(dx, dy)` shift, in pixels, that re-phases this pattern onto an `RGGB` grid.
    ///
    /// Cropping/reading the mosaic starting at this offset turns any of the four Bayer phases into
    /// RGGB. (Each component is 0 or 1.) Applied at ingest so the rest of the pipeline is
    /// pattern-agnostic.
    public var permutationToRGGB: (dx: Int, dy: Int) {
        switch self {
        case .rggb: return (0, 0)
        case .grbg: return (1, 0)
        case .gbrg: return (0, 1)
        case .bggr: return (1, 1)
        }
    }

    /// Colour (0 = R, 1 = G, 2 = B) of the sensel at absolute pixel `(x, y)`.
    @inlinable
    public func colorIndex(x: Int, y: Int) -> Int {
        let i = (y & 1) * 2 + (x & 1)
        return cellColors[i]
    }

    /// Position of the red pixel within the 2×2 cell, as `(col, row)`.
    public var redPosition: (x: Int, y: Int) {
        switch self {
        case .rggb: return (0, 0)
        case .bggr: return (1, 1)
        case .grbg: return (1, 0)
        case .gbrg: return (0, 1)
        }
    }
}
