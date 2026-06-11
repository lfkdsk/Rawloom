import XCTest
import simd
@testable import RawloomCore

final class MergeTests: XCTestCase {

    /// Merging a static burst denoises: the merged raw is closer to the clean ground truth than any
    /// single frame — the √N noise reduction that underpins the whole pipeline.
    func testMergeDenoisesStaticScene() throws {
        let ctx = try requireMetal()
        let scene = SyntheticScene.gradientBlobs(width: 128, height: 128)
        // Static camera (only tremor), strong noise so the gain is unambiguous.
        let spec = SyntheticBurstSpec(frameCount: 8, iso: 3200, tremorSigma: 0.5,
                                      globalShift: .zero, addNoise: true, seed: 5)
        let burst = SyntheticBurstGenerator.generate(scene: scene, spec: spec)

        let merger = Merger(context: ctx)
        let result = try merger.merge(frames: burst.frames, referenceIndex: 0, config: .photo)

        let merged = ctx.readFloats(result.mergedBayer)
        let clean = normalized(burst.cleanReference)
        let single = normalized(burst.frames[0])

        XCTAssertFalse(merged.contains { $0.isNaN }, "merged image must not contain NaNs")

        let psnrSingle = psnr(single, clean)
        let psnrMerged = psnr(merged, clean)
        XCTAssertGreaterThan(psnrMerged, psnrSingle + 2.0,
            "8-frame merge should beat a single frame by >2 dB (single=\(psnrSingle), merged=\(psnrMerged))")
    }

    /// The robust merge must reject an independently moving object instead of ghosting it. We compare
    /// against a near-naive average (huge robustness): in a region the object passes through in the
    /// alternates but NOT in the reference, the robust merge stays much closer to the reference.
    func testMergeRejectsMovingObject() throws {
        let ctx = try requireMetal()
        let scene = SyntheticScene.gradientBlobs(width: 160, height: 160)
        let mo = MovingObject(origin: SIMD2(36, 40), size: SIMD2(16, 16),
                              velocity: SIMD2(12, 0), color: SIMD3(0.95, 0.95, 0.95))
        let spec = SyntheticBurstSpec(frameCount: 8, iso: 800, tremorSigma: 0.3,
                                      movingObject: mo, addNoise: true, seed: 11)
        let burst = SyntheticBurstGenerator.generate(scene: scene, spec: spec)

        let merger = Merger(context: ctx)

        func mergedNormalized(robustness: Float) throws -> [Float] {
            var cfg = PipelineConfiguration.photo
            cfg.mergeRobustness = robustness
            let r = try merger.merge(frames: burst.frames, referenceIndex: 0, config: cfg)
            return ctx.readFloats(r.mergedBayer)
        }

        let robust = try mergedNormalized(robustness: 6)        // normal: should reject the object
        let naive = try mergedNormalized(robustness: 1.0e6)     // ~plain average: should ghost
        let reference = normalized(burst.frames[0])

        // Region the object occupies in mid/late frames (x≈36+12·k) but not in frame 0.
        let region = (x: 104, y: 40, w: 16, h: 16)
        let dRobust = regionMAD(robust, reference, w: 160, region: region)
        let dNaive = regionMAD(naive, reference, w: 160, region: region)

        XCTAssertLessThan(dRobust, dNaive * 0.6,
            "robust merge should ghost far less than a naive average (robust=\(dRobust), naive=\(dNaive))")
        XCTAssertLessThan(dRobust, 0.08, "robust merge should stay close to the (object-free) reference")
    }

    // MARK: helpers

    private func normalized(_ f: RawFrame) -> [Float] {
        var out = [Float](repeating: 0, count: f.width * f.height)
        for y in 0..<f.height { for x in 0..<f.width { out[y * f.width + x] = f.normalized(x: x, y: y) } }
        return out
    }

    private func psnr(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        var mse = 0.0
        for i in 0..<a.count { let d = Double(a[i] - b[i]); mse += d * d }
        mse /= Double(a.count)
        return mse < 1e-12 ? 120 : 10 * Foundation.log10(1.0 / mse)
    }

    private func regionMAD(_ a: [Float], _ b: [Float], w: Int, region: (x: Int, y: Int, w: Int, h: Int)) -> Double {
        var acc = 0.0; var n = 0
        for y in region.y..<(region.y + region.h) {
            for x in region.x..<(region.x + region.w) {
                acc += Double(abs(a[y * w + x] - b[y * w + x])); n += 1
            }
        }
        return n > 0 ? acc / Double(n) : 0
    }
}
