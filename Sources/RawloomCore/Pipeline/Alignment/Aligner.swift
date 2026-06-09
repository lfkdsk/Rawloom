import Foundation
import Metal
import simd

// MARK: - Parameter mirrors (scalar-only ⇒ identical Swift/Metal layout)

struct AlignParams {
    var levelWidth: UInt32
    var levelHeight: UInt32
    var tileSize: UInt32
    var tilesX: UInt32
    var tilesY: UInt32
    var searchRadius: Int32
    var lambda: Float
    var useL1: UInt32
    var hasPrior: UInt32
    var subpixel: UInt32
}

struct UpsampleParams {
    var outTilesX: UInt32
    var outTilesY: UInt32
    var inTilesX: UInt32
    var inTilesY: UInt32
    var scale: Float
}

struct WarpParams {
    var width: UInt32
    var height: UInt32
    var tileSize: UInt32
    var tilesX: UInt32
    var tilesY: UInt32
}

/// A per-tile motion-vector field. `tileSize` and the vectors are in the coordinate space of the
/// image the field was computed on (grayscale = half Bayer resolution).
public struct AlignmentField {
    public let texture: MTLTexture // rg32Float, (tilesX × tilesY)
    public let tilesX: Int
    public let tilesY: Int
    public let tileSize: Int
}

/// Coarse-to-fine tile block-matching aligner. See `docs/PIPELINE.md` §3.2.
public struct Aligner {
    public let context: MetalContext
    public init(context: MetalContext) { self.context = context }

    /// Align an alternate pyramid to a reference pyramid, returning the finest-level (grayscale) field.
    public func align(
        reference: GrayPyramid,
        alternate: GrayPyramid,
        config: PipelineConfiguration,
        in commandBuffer: MTLCommandBuffer
    ) throws -> AlignmentField {
        let n = reference.levels.count
        precondition(alternate.levels.count == n, "pyramids must have equal depth")

        var priorField: MTLTexture?
        var priorTilesX = 0, priorTilesY = 0
        var result: AlignmentField?

        for level in stride(from: n - 1, through: 0, by: -1) {
            let ref = reference.levels[level]
            let alt = alternate.levels[level]
            let lw = ref.width, lh = ref.height
            let isFinest = (level == 0)
            let isCoarsest = (level == n - 1)
            // 8 px tiles at the coarsest level, 16 (config) at finer levels — HDR+.
            let tileSize = isCoarsest ? min(8, max(2, lw)) : config.tileSize
            let tilesX = max(1, (lw + tileSize - 1) / tileSize)
            let tilesY = max(1, (lh + tileSize - 1) / tileSize)

            // Prior guess upsampled to this level's tile grid.
            let prior = try context.makeField(tilesX: tilesX, tilesY: tilesY)
            var hasPrior: UInt32 = 0
            if let pf = priorField {
                hasPrior = 1
                var up = UpsampleParams(
                    outTilesX: UInt32(tilesX), outTilesY: UInt32(tilesY),
                    inTilesX: UInt32(priorTilesX), inTilesY: UInt32(priorTilesY),
                    scale: Float(reference.factors[level + 1])
                )
                try context.run("upsample_field", gridWidth: tilesX, gridHeight: tilesY,
                                in: commandBuffer) { enc in
                    enc.setTexture(pf, index: 0)
                    enc.setTexture(prior, index: 1)
                    enc.setBytes(&up, length: MemoryLayout<UpsampleParams>.stride, index: 0)
                }
            }

            let outField = try context.makeField(tilesX: tilesX, tilesY: tilesY)
            var params = AlignParams(
                levelWidth: UInt32(lw), levelHeight: UInt32(lh),
                tileSize: UInt32(tileSize), tilesX: UInt32(tilesX), tilesY: UInt32(tilesY),
                searchRadius: Int32(config.searchRadius),
                lambda: config.motionRegularization,
                useL1: isFinest ? 1 : 0,           // L1 only at the finest level
                hasPrior: hasPrior,
                subpixel: isFinest ? 0 : 1          // no sub-pixel at the finest level
            )
            try context.run("align_level", gridWidth: tilesX, gridHeight: tilesY,
                            in: commandBuffer) { enc in
                enc.setTexture(ref, index: 0)
                enc.setTexture(alt, index: 1)
                enc.setTexture(prior, index: 2)
                enc.setTexture(outField, index: 3)
                enc.setBytes(&params, length: MemoryLayout<AlignParams>.stride, index: 0)
            }

            priorField = outField
            priorTilesX = tilesX
            priorTilesY = tilesY
            if isFinest {
                result = AlignmentField(texture: outField, tilesX: tilesX, tilesY: tilesY, tileSize: tileSize)
            }
        }
        return result!
    }

    /// Warp a single-channel image into the reference frame using a per-tile field.
    public func warpGray(
        _ image: MTLTexture,
        field: AlignmentField,
        in commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let out = try context.makeFloat(width: image.width, height: image.height)
        var params = WarpParams(
            width: UInt32(image.width), height: UInt32(image.height),
            tileSize: UInt32(field.tileSize), tilesX: UInt32(field.tilesX), tilesY: UInt32(field.tilesY)
        )
        try context.run("warp_gray", gridWidth: image.width, gridHeight: image.height,
                        in: commandBuffer) { enc in
            enc.setTexture(image, index: 0)
            enc.setTexture(field.texture, index: 1)
            enc.setTexture(out, index: 2)
            enc.setBytes(&params, length: MemoryLayout<WarpParams>.stride, index: 0)
        }
        return out
    }

    /// Convenience: ingest two raw frames, build their grayscale pyramids, and align. Returns the
    /// field plus the finest grayscale of each (handy for the merge and for tests).
    public func alignFrames(
        reference: RawFrame,
        alternate: RawFrame,
        config: PipelineConfiguration,
        in commandBuffer: MTLCommandBuffer
    ) throws -> (field: AlignmentField, referenceGray: MTLTexture, alternateGray: MTLTexture) {
        let refBayer = try RawIngest.normalize(reference, context: context, in: commandBuffer)
        let altBayer = try RawIngest.normalize(alternate, context: context, in: commandBuffer)
        let refPyr = try PyramidBuilder.build(normalizedBayer: refBayer, context: context, in: commandBuffer)
        let altPyr = try PyramidBuilder.build(normalizedBayer: altBayer, context: context, in: commandBuffer)
        let field = try align(reference: refPyr, alternate: altPyr, config: config, in: commandBuffer)
        return (field, refPyr.levels[0], altPyr.levels[0])
    }
}
