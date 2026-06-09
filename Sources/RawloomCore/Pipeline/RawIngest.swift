import Foundation
import Metal

/// Mirror of `RawNormalizeParams` in `RawProcessing.metal`. All fields are 4-byte scalars so the
/// Swift and Metal struct layouts are identical (no alignment padding) and can be passed by `setBytes`.
struct RawNormalizeParams {
    var width: UInt32
    var height: UInt32
    var blackR: Float
    var blackGr: Float
    var blackGb: Float
    var blackB: Float
    var whiteLevel: Float
    var redX: UInt32
    var redY: UInt32
}

/// Stage 0: turn a captured `RawFrame` (raw sensor codes) into a normalised, black-level-corrected
/// linear Bayer image in an `.r32Float` texture — the working representation every later stage reads.
/// See `docs/PIPELINE.md` §0 / §6.1.
public enum RawIngest {
    /// Uploads `frame` and runs `normalize_raw`, returning the normalised full-resolution Bayer texture.
    public static func normalize(
        _ frame: RawFrame,
        context: MetalContext,
        in commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let raw = try context.uploadRaw(frame)
        let out = try context.makeFloat(width: frame.width, height: frame.height)
        let red = frame.metadata.cfa.redPosition
        var params = RawNormalizeParams(
            width: UInt32(frame.width),
            height: UInt32(frame.height),
            blackR: frame.metadata.blackLevel.x,
            blackGr: frame.metadata.blackLevel.y,
            blackGb: frame.metadata.blackLevel.z,
            blackB: frame.metadata.blackLevel.w,
            whiteLevel: frame.metadata.whiteLevel,
            redX: UInt32(red.x),
            redY: UInt32(red.y)
        )
        try context.run("normalize_raw",
                        gridWidth: frame.width, gridHeight: frame.height,
                        in: commandBuffer) { encoder in
            encoder.setTexture(raw, index: 0)
            encoder.setTexture(out, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<RawNormalizeParams>.stride, index: 0)
        }
        return out
    }
}
