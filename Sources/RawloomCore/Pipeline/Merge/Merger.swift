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

    public func merge(
        frames: [RawFrame],
        referenceIndex: Int,
        config: PipelineConfiguration,
        in commandBuffer: MTLCommandBuffer
    ) throws -> MergeResult {
        precondition(!frames.isEmpty)
        let refFrame = frames[referenceIndex]
        let width = refFrame.width, height = refFrame.height
        let pw = width / 2, ph = height / 2
        let aligner = Aligner(context: context)

        // Reference: ingest, pyramid, planes.
        let refBayer = try RawIngest.normalize(refFrame, context: context, in: commandBuffer)
        let refPyramid = try PyramidBuilder.build(normalizedBayer: refBayer, context: context, in: commandBuffer)
        let refPlanes = try extractPlanes(refBayer, in: commandBuffer)

        // Accumulators seeded with the reference (weight 1). Ping-ponged across alternates.
        var accSrc = try context.makeRGBA(width: pw, height: ph)
        var accDst = try context.makeRGBA(width: pw, height: ph)
        var wSrc = try context.makeRGBA(width: pw, height: ph)
        var wDst = try context.makeRGBA(width: pw, height: ph)
        try context.run("merge_init", gridWidth: pw, gridHeight: ph, in: commandBuffer) { enc in
            enc.setTexture(refPlanes, index: 0)
            enc.setTexture(accSrc, index: 1)
            enc.setTexture(wSrc, index: 2)
        }

        let noise = refFrame.metadata.noise
        for (i, frame) in frames.enumerated() where i != referenceIndex {
            let altBayer = try RawIngest.normalize(frame, context: context, in: commandBuffer)
            let altPyramid = try PyramidBuilder.build(normalizedBayer: altBayer, context: context, in: commandBuffer)
            let field = try aligner.align(reference: refPyramid, alternate: altPyramid,
                                          config: config, in: commandBuffer)
            let altPlanes = try extractPlanes(altBayer, in: commandBuffer)

            var params = MergeParams(
                width: UInt32(pw), height: UInt32(ph),
                tileSize: UInt32(field.tileSize),
                tilesX: UInt32(field.tilesX), tilesY: UInt32(field.tilesY),
                robustness: config.mergeRobustness,
                noiseA: noise.a, noiseB: noise.b
            )
            try context.run("merge_accumulate", gridWidth: pw, gridHeight: ph, in: commandBuffer) { enc in
                enc.setTexture(refPlanes, index: 0)
                enc.setTexture(altPlanes, index: 1)
                enc.setTexture(field.texture, index: 2)
                enc.setTexture(accSrc, index: 3)
                enc.setTexture(wSrc, index: 4)
                enc.setTexture(accDst, index: 5)
                enc.setTexture(wDst, index: 6)
                enc.setBytes(&params, length: MemoryLayout<MergeParams>.stride, index: 0)
            }
            swap(&accSrc, &accDst)
            swap(&wSrc, &wDst)
        }

        // Finalise → merged planes → merged Bayer.
        let mergedPlanes = try context.makeRGBA(width: pw, height: ph)
        try context.run("merge_finalize", gridWidth: pw, gridHeight: ph, in: commandBuffer) { enc in
            enc.setTexture(accSrc, index: 0)
            enc.setTexture(wSrc, index: 1)
            enc.setTexture(mergedPlanes, index: 2)
        }
        let mergedBayer = try context.makeFloat(width: width, height: height)
        try context.run("planes_to_bayer", gridWidth: width, gridHeight: height, in: commandBuffer) { enc in
            enc.setTexture(mergedPlanes, index: 0)
            enc.setTexture(mergedBayer, index: 1)
        }

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
