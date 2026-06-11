import XCTest
import simd
@testable import RawloomCore

/// Exercises the whole frontend+backend: capture (synthetic) → reference → merge → finish.
final class PipelineEndToEndTests: XCTestCase {

    func testEndToEndProducesFaithfulDisplayImage() throws {
        let ctx = try requireMetal()
        let scene = SyntheticScene.gradientBlobs(width: 128, height: 128)
        let spec = SyntheticBurstSpec(frameCount: 8, iso: 1600, tremorSigma: 0.5,
                                      underexposure: 0.2, addNoise: true, seed: 3)
        let burst = SyntheticBurstGenerator.generate(scene: scene, spec: spec)

        let pipeline = IndigoPipeline(context: ctx)
        let out = try pipeline.process(frames: burst.frames, config: .photo)

        XCTAssertEqual(out.width, 128)
        XCTAssertEqual(out.height, 128)
        XCTAssertGreaterThan(out.exposureGain, 1.0, "under-exposed capture should be brightened")

        let rgba = ctx.readRGBA(out.displayImage)
        XCTAssertFalse(rgba.contains { $0.isNaN }, "display image must not contain NaNs")
        XCTAssertFalse(rgba.contains { $0 < -0.001 || $0 > 1.001 }, "display image must be in [0,1]")

        // Structure must survive: output luma should correlate strongly with the ground-truth scene.
        var outLuma = [Double](repeating: 0, count: 128 * 128)
        var refLuma = [Double](repeating: 0, count: 128 * 128)
        for i in 0..<(128 * 128) {
            let r = Double(rgba[i * 4]); let g = Double(rgba[i * 4 + 1]); let b = Double(rgba[i * 4 + 2])
            outLuma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let p = scene.pixels[i]
            refLuma[i] = 0.2126 * Double(p.x) + 0.7152 * Double(p.y) + 0.0722 * Double(p.z)
        }
        let corr = pearson(outLuma, refLuma)
        XCTAssertGreaterThan(corr, 0.85, "finished image should preserve scene structure (corr=\(corr))")

        // The image should actually use the tonal range (not collapsed to black/white).
        let mean = outLuma.reduce(0, +) / Double(outLuma.count)
        XCTAssertGreaterThan(mean, 0.15)
        XCTAssertLessThan(mean, 0.9)

        // The Ultra HDR gain map is built in-pipeline: a sub-resolution single-channel map (default /2)
        // with a valid HDR range, and the burst length is recorded for the DNG NoiseProfile.
        XCTAssertEqual(out.gainMap.pixels.count, out.gainMap.width * out.gainMap.height)
        XCTAssertEqual(out.gainMap.width, 64)   // 128 downsampled by 2
        XCTAssertEqual(out.gainMap.height, 64)
        XCTAssertGreaterThanOrEqual(out.gainMap.metadata.gainMapMax, 0)
        XCTAssertLessThanOrEqual(out.gainMap.metadata.gainMapMax, 6)   // clamped to maxStops
        XCTAssertEqual(out.mergedFrameCount, 8)
    }

    private func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var cov = 0.0, va = 0.0, vb = 0.0
        for i in 0..<a.count {
            let da = a[i] - ma, db = b[i] - mb
            cov += da * db; va += da * da; vb += db * db
        }
        return cov / max((va * vb).squareRoot(), 1e-9)
    }
}
