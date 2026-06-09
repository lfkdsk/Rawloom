import XCTest
import simd
@testable import RawloomCore

final class AlignmentTests: XCTestCase {

    // MARK: Reference selection (CPU)

    func testReferenceSelectionPicksSharpestOfPool() {
        let meta = RawImageMetadata(cfa: .rggb, blackLevel: SIMD4(repeating: 0),
                                    whiteLevel: 1023, iso: 100, exposureDuration: 0.01, timestamp: 0)
        let n = 32
        func frame(detail: Bool) -> RawFrame {
            var s = [UInt16](repeating: 400, count: n * n)
            if detail {
                for y in 0..<n { for x in 0..<n where (x / 2 + y / 2) % 2 == 0 { s[y * n + x] = 900 } }
            }
            return RawFrame(width: n, height: n, samples: s, metadata: meta)
        }
        // frames: blurry, SHARP, blurry, (sharp-but-outside-pool)
        let frames = [frame(detail: false), frame(detail: true), frame(detail: false)]
        XCTAssertEqual(ReferenceSelector.selectIndex(from: frames, candidatePool: 3), 1)
        // Only the first frame is in the pool ⇒ index 0 even though frame 1 is sharper.
        XCTAssertEqual(ReferenceSelector.selectIndex(from: frames, candidatePool: 1), 0)
    }

    // MARK: Alignment (GPU / simulator)

    func testAlignmentRecoversKnownShift() throws {
        let ctx = try requireMetal()
        // A known camera motion of (4, -2) Bayer px on the alternate frame.
        let scene = SyntheticScene.gradientBlobs(width: 160, height: 160)
        let spec = SyntheticBurstSpec(frameCount: 2, iso: 400, tremorSigma: 0.2,
                                      globalShift: SIMD2(4, -2), seed: 99)
        let burst = SyntheticBurstGenerator.generate(scene: scene, spec: spec)

        let aligner = Aligner(context: ctx)
        let cb = try ctx.makeCommandBuffer()
        let (field, refGray, altGray) = try aligner.alignFrames(
            reference: burst.frames[0], alternate: burst.frames[1],
            config: .photo, in: cb)
        let warped = try aligner.warpGray(altGray, field: field, in: cb)
        cb.commit(); cb.waitUntilCompleted()

        // The aligner works in grayscale (half Bayer resolution): a Bayer shift `s` appears as `s/2`,
        // and the recovered vector is `-s/2`.
        let vectors = ctx.readField(field.texture)
        let mean = interiorMean(vectors, tilesX: field.tilesX, tilesY: field.tilesY)
        let expected = -burst.cameraShifts[1] / 2

        XCTAssertEqual(mean.x, expected.x, accuracy: 0.8, "recovered dx should match -shift/2")
        XCTAssertEqual(mean.y, expected.y, accuracy: 0.8, "recovered dy should match -shift/2")

        // And warping the alternate by the field should match the reference far better than the
        // unaligned alternate does.
        let ref = ctx.readFloats(refGray)
        let alt = ctx.readFloats(altGray)
        let warpedVals = ctx.readFloats(warped)
        let w = refGray.width, h = refGray.height
        let before = centralMAD(ref, alt, w: w, h: h)
        let after = centralMAD(ref, warpedVals, w: w, h: h)
        XCTAssertLessThan(after, before * 0.6,
                          "alignment should cut the residual to the reference by >40% (before=\(before), after=\(after))")
    }

    // MARK: helpers

    /// Mean vector over the interior tiles (excludes the unreliable 1-tile border).
    private func interiorMean(_ v: [SIMD2<Float>], tilesX: Int, tilesY: Int) -> SIMD2<Float> {
        guard tilesX > 2 && tilesY > 2 else {
            return v.reduce(.zero, +) / Float(max(v.count, 1))
        }
        var acc = SIMD2<Float>.zero
        var count = 0
        for ty in 1..<(tilesY - 1) {
            for tx in 1..<(tilesX - 1) {
                acc += v[ty * tilesX + tx]
                count += 1
            }
        }
        return acc / Float(max(count, 1))
    }

    /// Mean absolute difference over the central 50% of two grayscale images.
    private func centralMAD(_ a: [Float], _ b: [Float], w: Int, h: Int) -> Double {
        let x0 = w / 4, x1 = 3 * w / 4, y0 = h / 4, y1 = 3 * h / 4
        var acc = 0.0
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                acc += Double(abs(a[y * w + x] - b[y * w + x]))
                count += 1
            }
        }
        return count > 0 ? acc / Double(count) : 0
    }
}
