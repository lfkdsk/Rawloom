import Foundation
import Metal

/// A grayscale Gaussian/box pyramid of one frame, finest (`levels[0]`) → coarsest.
/// `levels[0]` is the half-resolution grayscale of the Bayer mosaic (see `bayer_to_gray`).
public struct GrayPyramid {
    /// Pyramid levels, index 0 = finest (half Bayer resolution).
    public let levels: [MTLTexture]
    /// Downsample factor used to derive each level from the previous one (`factors[0] == 1`).
    public let factors: [Int]
}

/// Builds the grayscale alignment pyramid from a normalised Bayer image. See `docs/PIPELINE.md` §3.1.
public enum PyramidBuilder {
    /// Default per-level downsample factors *between* levels (HDR+: 2, 4, 4 over 4 levels).
    public static let defaultFactors = [2, 4, 4]

    public static func build(
        normalizedBayer bayer: MTLTexture,
        factors: [Int] = defaultFactors,
        context: MetalContext,
        in commandBuffer: MTLCommandBuffer
    ) throws -> GrayPyramid {
        // Level 0: half-resolution grayscale.
        let gray = try context.makeFloat(width: bayer.width / 2, height: bayer.height / 2)
        try context.run("bayer_to_gray",
                        gridWidth: gray.width, gridHeight: gray.height,
                        in: commandBuffer) { enc in
            enc.setTexture(bayer, index: 0)
            enc.setTexture(gray, index: 1)
        }

        var levels = [gray]
        var usedFactors = [1]
        for f in factors {
            precondition(f == 2 || f == 4, "downsample factors must be 2 or 4 (powers of two)")
            var current = levels[levels.count - 1]
            var steps = f == 4 ? 2 : 1
            while steps > 0 {
                let next = try context.makeFloat(width: max(current.width / 2, 1),
                                                 height: max(current.height / 2, 1))
                try context.run("downsample_half",
                                gridWidth: next.width, gridHeight: next.height,
                                in: commandBuffer) { enc in
                    enc.setTexture(current, index: 0)
                    enc.setTexture(next, index: 1)
                }
                current = next
                steps -= 1
            }
            levels.append(current)
            usedFactors.append(f)
        }
        return GrayPyramid(levels: levels, factors: usedFactors)
    }
}
