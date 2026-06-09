import Foundation
import Metal

struct MergeParams {
    var width: UInt32
    var height: UInt32
    var tileSize: UInt32
    var tilesX: UInt32
    var tilesY: UInt32
    var robustness: Float
    var noiseA: Float
    var noiseB: Float
}

/// The merged, low-noise raw — the output of the burst frontend (`docs/PIPELINE.md` §4) and the basis
/// for both the computed-raw DNG and the finishing pipeline.
public struct MergeResult {
    /// Merged Bayer mosaic, normalised linear `[0,1]`, full resolution (`r32Float`).
    public let mergedBayer: MTLTexture
    /// Merged 4-plane half-resolution image (`rgba32Float`).
    public let mergedPlanes: MTLTexture
    public let width: Int
    public let height: Int
    public let referenceIndex: Int
}

/// Robust multi-frame merge: aligns every alternate to the reference and combines them with the
/// Wiener-style robustness weight, per Bayer plane. See `docs/PIPELINE.md` §4.
public struct Merger {
    public let context: MetalContext
    public init(context: MetalContext) { self.context = context }

    /// Merges the burst, committing **one command buffer per alternate frame**. Only the reference
    /// pyramid/planes, the accumulators, and a single alternate's textures are alive at once, so peak
    /// memory is independent of the burst length — that's what lets Night mode use a long burst without
    /// exhausting memory or tripping the GPU watchdog (the old single-command-buffer path held every
    /// frame's textures at once → OOM). See `docs/PIPELINE.md` §4.
    public func merge(
        frames: [RawFrame],
        referenceIndex: Int,
        config: PipelineConfiguration
    ) throws -> MergeResult {
        precondition(!frames.isEmpty)
        let refFrame = frames[referenceIndex]
        let width = refFrame.width, height = refFrame.height
        let pw = width / 2, ph = height / 2
        let aligner = Aligner(context: context)

        // --- Reference setup (these persist across every alternate) ---
        let setupCB = try context.makeCommandBuffer()
        let refBayer = try RawIngest.normalize(refFrame, context: context, in: setupCB)
        let refPyramid = try PyramidBuilder.build(normalizedBayer: refBayer, context: context, in: setupCB)
        let refPlanes = try extractPlanes(refBayer, in: setupCB)
        // Accumulators seeded with the reference (weight 1). Ping-ponged across alternates.
        var accSrc = try context.makeRGBA(width: pw, height: ph)
        var accDst = try context.makeRGBA(width: pw, height: ph)
        var wSrc = try context.makeRGBA(width: pw, height: ph)
        var wDst = try context.makeRGBA(width: pw, height: ph)
        try context.run("merge_init", gridWidth: pw, gridHeight: ph, in: setupCB) { enc in
            enc.setTexture(refPlanes, index: 0)
            enc.setTexture(accSrc, index: 1)
            enc.setTexture(wSrc, index: 2)
        }
        setupCB.commit()
        setupCB.waitUntilCompleted()

        // --- Accumulate each alternate in its own command buffer; its textures release after commit. ---
        let noise = refFrame.metadata.noise
        for (i, frame) in frames.enumerated() where i != referenceIndex {
            let cb = try context.makeCommandBuffer()
            let altBayer = try RawIngest.normalize(frame, context: context, in: cb)
            let altPyramid = try PyramidBuilder.build(normalizedBayer: altBayer, context: context, in: cb)
            let field = try aligner.align(reference: refPyramid, alternate: altPyramid,
                                          config: config, in: cb)
            let altPlanes = try extractPlanes(altBayer, in: cb)

            var params = MergeParams(
                width: UInt32(pw), height: UInt32(ph),
                tileSize: UInt32(field.tileSize),
                tilesX: UInt32(field.tilesX), tilesY: UInt32(field.tilesY),
                robustness: config.mergeRobustness,
                noiseA: noise.a, noiseB: noise.b
            )
            try context.run("merge_accumulate", gridWidth: pw, gridHeight: ph, in: cb) { enc in
                enc.setTexture(refPlanes, index: 0)
                enc.setTexture(altPlanes, index: 1)
                enc.setTexture(field.texture, index: 2)
                enc.setTexture(accSrc, index: 3)
                enc.setTexture(wSrc, index: 4)
                enc.setTexture(accDst, index: 5)
                enc.setTexture(wDst, index: 6)
                enc.setBytes(&params, length: MemoryLayout<MergeParams>.stride, index: 0)
            }
            cb.commit()
            cb.waitUntilCompleted()
            swap(&accSrc, &accDst)
            swap(&wSrc, &wDst)
        }

        // --- Finalise → merged planes → merged Bayer. ---
        let mergedPlanes = try context.makeRGBA(width: pw, height: ph)
        let mergedBayer = try context.makeFloat(width: width, height: height)
        let finalCB = try context.makeCommandBuffer()
        try context.run("merge_finalize", gridWidth: pw, gridHeight: ph, in: finalCB) { enc in
            enc.setTexture(accSrc, index: 0)
            enc.setTexture(wSrc, index: 1)
            enc.setTexture(mergedPlanes, index: 2)
        }
        try context.run("planes_to_bayer", gridWidth: width, gridHeight: height, in: finalCB) { enc in
            enc.setTexture(mergedPlanes, index: 0)
            enc.setTexture(mergedBayer, index: 1)
        }
        finalCB.commit()
        finalCB.waitUntilCompleted()

        return MergeResult(mergedBayer: mergedBayer, mergedPlanes: mergedPlanes,
                           width: width, height: height, referenceIndex: referenceIndex)
    }

    private func extractPlanes(_ bayer: MTLTexture, in commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let planes = try context.makeRGBA(width: bayer.width / 2, height: bayer.height / 2)
        try context.run("extract_planes", gridWidth: planes.width, gridHeight: planes.height,
                        in: commandBuffer) { enc in
            enc.setTexture(bayer, index: 0)
            enc.setTexture(planes, index: 1)
        }
        return planes
    }
}
