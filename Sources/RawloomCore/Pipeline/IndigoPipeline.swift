import Foundation
import Metal

/// The result of processing a burst: the finished display image and the merged computed-raw, plus
/// the metadata needed to write a DNG/JPEG.
public struct ProcessedImage {
    /// Finished, sRGB-encoded display image (`rgba32Float`, values in `[0,1]`) → JPEG (SDR base).
    public let displayImage: MTLTexture
    /// Precomputed Ultra HDR gain map — the HDR companion of `displayImage`, built in `process` so the
    /// full-res HDR float texture isn't carried past finishing (`docs/PIPELINE.md` §7).
    public let gainMap: GainMapData
    /// Merged, low-noise, linear Bayer mosaic (`r32Float`, normalised) → computed-raw DNG.
    public let mergedBayer: MTLTexture
    public let width: Int
    public let height: Int
    /// Index of the frame chosen as the reference.
    public let referenceIndex: Int
    /// Metadata of the reference frame (CFA, black/white, WB, CCM, noise) for output files.
    public let referenceMetadata: RawImageMetadata
    /// The exposure gain ("memorised gain") applied in finishing.
    public let exposureGain: Float
    /// Burst length (frames merged) — scales the DNG NoiseProfile by the merge's ~1/N variance cut.
    public let mergedFrameCount: Int
}

/// End-to-end orchestration of the Project-Indigo pipeline:
/// reference selection → robust merge → finishing. See `docs/PIPELINE.md` §8.
///
/// (Super-resolution and the frequency-domain merge are optional refinements layered on the same
/// flow; capture lives in the iOS app and feeds `process(frames:config:)` a `[RawFrame]`.)
public final class IndigoPipeline {
    public let context: MetalContext

    public init(context: MetalContext) {
        self.context = context
    }

    /// Convenience initialiser that creates its own Metal context (throws if there is no GPU).
    public convenience init() throws {
        self.init(context: try MetalContext())
    }

    /// Process a captured burst into a finished image + merged raw.
    public func process(frames: [RawFrame], config: PipelineConfiguration) throws -> ProcessedImage {
        precondition(!frames.isEmpty, "cannot process an empty burst")

        // 1. choose the reference (sharpest of the first few frames).
        let referenceIndex = ReferenceSelector.selectIndex(from: frames)
        let referenceMeta = frames[referenceIndex].metadata

        // 2. robust multi-frame merge → low-noise linear Bayer. The merger manages its own command
        //    buffers (one per frame) to keep peak memory independent of the burst length.
        let merger = Merger(context: context)
        let merge = try merger.merge(frames: frames, referenceIndex: referenceIndex, config: config)

        // 3. finishing → display image. Exposure gain compensates the capture under-exposure.
        let exposure = Self.exposureGain(for: frames[referenceIndex], config: config)
        let finisher = Finisher(context: context)
        let finishCB = try context.makeCommandBuffer()
        let finished = try finisher.finish(
            mergedBayer: merge.mergedBayer,
            cfa: referenceMeta.cfa,
            whiteBalance: referenceMeta.whiteBalance,
            colorMatrix: referenceMeta.colorMatrix,
            config: config,
            exposure: exposure,
            in: finishCB
        )

        finishCB.commit()
        finishCB.waitUntilCompleted()

        // Build the Ultra HDR gain map now, while both renditions are on hand, so only the small map —
        // not the full-res HDR float texture — travels on in `ProcessedImage`.
        let gainMap = GainMap.data(
            sdrSRGB: context.readRGBA(finished.display),
            hdrLinear: context.readRGBA(finished.hdr),
            width: finished.display.width, height: finished.display.height
        )

        return ProcessedImage(
            displayImage: finished.display,
            gainMap: gainMap,
            mergedBayer: merge.mergedBayer,
            width: merge.width, height: merge.height,
            referenceIndex: referenceIndex,
            referenceMetadata: referenceMeta,
            exposureGain: exposure,
            mergedFrameCount: frames.count
        )
    }

    /// Adaptive "memorised gain": lift the under-exposed capture so its midtones land near a pleasing
    /// target before tone mapping. Mirrors the HDR+/Indigo idea of metering for highlights then
    /// brightening (`docs/PIPELINE.md` §1.2) — there is no fixed EV.
    static func exposureGain(for reference: RawFrame, config: PipelineConfiguration,
                             targetMidtone: Double = 0.18) -> Float {
        let mean = max(reference.meanBrightness(), 1e-3)
        let gain = targetMidtone / mean
        return Float(min(max(gain, 1.0), 16.0))
    }
}
