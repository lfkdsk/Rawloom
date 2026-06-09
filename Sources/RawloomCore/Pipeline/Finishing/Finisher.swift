import Foundation
import Metal

struct DemosaicParams {
    var width: UInt32
    var height: UInt32
    var redX: UInt32
    var redY: UInt32
}

struct FinishParams {
    var width: UInt32
    var height: UInt32
    var wbR: Float, wbG: Float, wbB: Float
    var m0: Float, m1: Float, m2: Float, m3: Float, m4: Float, m5: Float, m6: Float, m7: Float, m8: Float
    var exposure: Float
    var toneStrength: Float
    var localContrast: Float
    var saturation: Float
}

/// Finishing: merged Bayer → display image (demosaic → WB → CCM → local/global tone → sRGB).
/// See `docs/PIPELINE.md` §6.
public struct Finisher {
    public let context: MetalContext
    public init(context: MetalContext) { self.context = context }

    /// - Parameter exposure: gain that compensates the capture under-exposure (the "memorised gain").
    /// - Returns: the finished SDR `display` (`.rgba32Float`, sRGB-encoded `[0,1]`) and the pre-tone-map
    ///   `hdr` rendition (`.rgba32Float`, linear sRGB-primary; highlights exceed 1) — the companion the
    ///   Ultra HDR gain map is built from (`docs/PIPELINE.md` §7).
    public func finish(
        mergedBayer: MTLTexture,
        cfa: CFAPattern,
        whiteBalance: WhiteBalanceGains,
        colorMatrix: ColorMatrix,
        config: PipelineConfiguration,
        exposure: Float,
        in commandBuffer: MTLCommandBuffer
    ) throws -> (display: MTLTexture, hdr: MTLTexture) {
        let w = mergedBayer.width, h = mergedBayer.height
        let red = cfa.redPosition

        // 1. demosaic → linear camera RGB
        let camRGB = try context.makeRGBA(width: w, height: h)
        var dparams = DemosaicParams(width: UInt32(w), height: UInt32(h),
                                     redX: UInt32(red.x), redY: UInt32(red.y))
        try context.run("demosaic_bilinear", gridWidth: w, gridHeight: h, in: commandBuffer) { enc in
            enc.setTexture(mergedBayer, index: 0)
            enc.setTexture(camRGB, index: 1)
            enc.setBytes(&dparams, length: MemoryLayout<DemosaicParams>.stride, index: 0)
        }

        var fparams = FinishParams(
            width: UInt32(w), height: UInt32(h),
            wbR: whiteBalance.red, wbG: whiteBalance.green, wbB: whiteBalance.blue,
            m0: colorMatrix.m[0], m1: colorMatrix.m[1], m2: colorMatrix.m[2],
            m3: colorMatrix.m[3], m4: colorMatrix.m[4], m5: colorMatrix.m[5],
            m6: colorMatrix.m[6], m7: colorMatrix.m[7], m8: colorMatrix.m[8],
            exposure: exposure,
            toneStrength: config.localToneStrength,
            localContrast: 1.0 + 0.5 * config.localToneStrength,
            saturation: config.saturation
        )

        // 2. WB + exposure + CCM → linear sRGB-primary RGB
        let linear = try context.makeRGBA(width: w, height: h)
        try context.run("finish_linearize", gridWidth: w, gridHeight: h, in: commandBuffer) { enc in
            enc.setTexture(camRGB, index: 0)
            enc.setTexture(linear, index: 1)
            enc.setBytes(&fparams, length: MemoryLayout<FinishParams>.stride, index: 0)
        }

        // 3–4. luma → blurred luma (tone-map base layer)
        let luma = try context.makeFloat(width: w, height: h)
        try context.run("extract_luma", gridWidth: w, gridHeight: h, in: commandBuffer) { enc in
            enc.setTexture(linear, index: 0)
            enc.setTexture(luma, index: 1)
        }
        let blurLuma = try context.makeFloat(width: w, height: h)
        try context.run("gaussian_blur5", gridWidth: w, gridHeight: h, in: commandBuffer) { enc in
            enc.setTexture(luma, index: 0)
            enc.setTexture(blurLuma, index: 1)
        }

        // 5. local + global tone, saturation, sRGB → display
        let display = try context.makeRGBA(width: w, height: h)
        try context.run("tone_finish", gridWidth: w, gridHeight: h, in: commandBuffer) { enc in
            enc.setTexture(linear, index: 0)
            enc.setTexture(luma, index: 1)
            enc.setTexture(blurLuma, index: 2)
            enc.setTexture(display, index: 3)
            enc.setBytes(&fparams, length: MemoryLayout<FinishParams>.stride, index: 0)
        }
        // `linear` is the WB+CCM+exposure rendition *before* tone mapping — highlights still exceed 1, so
        // it is the HDR companion to the tone-mapped SDR `display`.
        return (display, linear)
    }
}
