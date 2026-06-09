import XCTest
import simd
@testable import RawloomCore

/// Pure-CPU tests for the model layer — these run anywhere (no GPU required).
final class ModelTests: XCTestCase {

    func testCFARedPositions() {
        XCTAssertEqual(CFAPattern.rggb.redPosition.x, 0)
        XCTAssertEqual(CFAPattern.rggb.redPosition.y, 0)
        XCTAssertEqual(CFAPattern.bggr.redPosition.x, 1)
        XCTAssertEqual(CFAPattern.bggr.redPosition.y, 1)
        XCTAssertEqual(CFAPattern.grbg.redPosition.x, 1)
        XCTAssertEqual(CFAPattern.grbg.redPosition.y, 0)
        XCTAssertEqual(CFAPattern.gbrg.redPosition.x, 0)
        XCTAssertEqual(CFAPattern.gbrg.redPosition.y, 1)
    }

    func testCFAPermutationToRGGB() {
        // RGGB is already aligned.
        XCTAssertEqual(CFAPattern.rggb.permutationToRGGB.dx, 0)
        XCTAssertEqual(CFAPattern.rggb.permutationToRGGB.dy, 0)
        // BGGR needs a (1,1) crop to re-phase to RGGB.
        XCTAssertEqual(CFAPattern.bggr.permutationToRGGB.dx, 1)
        XCTAssertEqual(CFAPattern.bggr.permutationToRGGB.dy, 1)
    }

    func testNoiseModelIsAffineAndGainScaled() {
        let m = NoiseModel(a: 2, b: 1)
        XCTAssertEqual(m.variance(at: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(m.variance(at: 0.5), 2, accuracy: 1e-6)
        // Higher ISO ⇒ strictly more noise at the same signal level.
        let lo = NoiseModel.estimated(iso: 100)
        let hi = NoiseModel.estimated(iso: 3200)
        XCTAssertGreaterThan(hi.variance(at: 0.2), lo.variance(at: 0.2))
    }

    func testWhiteBalanceDefaultsNeutral() {
        XCTAssertEqual(WhiteBalanceGains.neutral.simd, SIMD3<Float>(1, 1, 1))
    }

    func testColorMatrixTransposeRoundTrip() {
        let m = ColorMatrix([1, 2, 3, 4, 5, 6, 7, 8, 9])
        // columnMajor is the transpose of rowMajor.
        XCTAssertEqual(m.columnMajor, [1, 4, 7, 2, 5, 8, 3, 6, 9])
        let v = m.transform(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(v, SIMD3<Float>(1, 4, 7)) // first column
    }

    func testForwardMatrixCCMPreservesNeutral() {
        // A valid DNG ForwardMatrix maps the camera neutral (1,1,1) to the D50 white point. Build one
        // whose rows sum to D50 white; the derived camera→sRGB CCM must then map neutral → sRGB white,
        // i.e. add no colour cast (the property that makes wiring the CCM in safe).
        let d50 = SIMD3<Float>(0.96422, 1.0, 0.82521)
        let fm: [Float] = [
            d50.x / 3, d50.x / 3, d50.x / 3,
            d50.y / 3, d50.y / 3, d50.y / 3,
            d50.z / 3, d50.z / 3, d50.z / 3,
        ]
        let ccm = ColorMatrix.cameraToLinearSRGB(forwardMatrixD50: fm)
        let white = ccm.transform(SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(white.x, 1, accuracy: 2e-3)
        XCTAssertEqual(white.y, 1, accuracy: 2e-3)
        XCTAssertEqual(white.z, 1, accuracy: 2e-3)
        // A grey of any level stays neutral (no hue shift, only scaled).
        let grey = ccm.transform(SIMD3<Float>(0.4, 0.4, 0.4))
        XCTAssertEqual(grey.x, grey.y, accuracy: 2e-3)
        XCTAssertEqual(grey.z, grey.y, accuracy: 2e-3)
        // Malformed input falls back to identity.
        XCTAssertEqual(ColorMatrix.cameraToLinearSRGB(forwardMatrixD50: [1, 2, 3]).m, ColorMatrix.identity.m)
    }

    func testColorMatrixCCMPreservesNeutral() {
        // The ColorMatrix fallback (XYZ→camera) must also be neutral-preserving via dcraw's row
        // normalisation — this is the path real iPhone DNGs take (no ForwardMatrix). A plausible
        // XYZ→camera matrix:
        let cm: [Float] = [
             1.0234, -0.2969, -0.2266,
            -0.5625,  1.4688,  0.0625,
            -0.0469,  0.2031,  0.9531,
        ]
        let ccm = ColorMatrix.cameraToLinearSRGB(colorMatrixXYZtoCam: cm)
        let white = ccm.transform(SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(white.x, 1, accuracy: 2e-3)
        XCTAssertEqual(white.y, 1, accuracy: 2e-3)
        XCTAssertEqual(white.z, 1, accuracy: 2e-3)
        // It must actually transform colour (not collapse to identity).
        XCTAssertNotEqual(ccm.m, ColorMatrix.identity.m)
        // Malformed / singular input falls back to identity.
        XCTAssertEqual(ColorMatrix.cameraToLinearSRGB(colorMatrixXYZtoCam: [1, 2, 3]).m, ColorMatrix.identity.m)
    }

    func testRawFrameNormalization() {
        // 4×4 RGGB frame, black 64, white 1088 ⇒ a code of 576 normalises to 0.5.
        let meta = RawImageMetadata(
            cfa: .rggb,
            blackLevel: SIMD4(64, 64, 64, 64),
            whiteLevel: 1088,
            iso: 100,
            exposureDuration: 1.0 / 120,
            timestamp: 0
        )
        let frame = RawFrame(width: 4, height: 4,
                             samples: [UInt16](repeating: 576, count: 16),
                             metadata: meta)
        XCTAssertEqual(frame.normalized(x: 0, y: 0), 0.5, accuracy: 1e-4)
        XCTAssertEqual(frame.normalized(x: 1, y: 1), 0.5, accuracy: 1e-4)
    }

    func testGreenSharpnessRespondsToDetail() {
        let meta = RawImageMetadata(cfa: .rggb, blackLevel: SIMD4(repeating: 0),
                                    whiteLevel: 1023, iso: 100,
                                    exposureDuration: 0.01, timestamp: 0)
        let n = 32
        let flat = RawFrame(width: n, height: n,
                            samples: [UInt16](repeating: 500, count: n * n), metadata: meta)
        var textured = [UInt16](repeating: 500, count: n * n)
        for y in 0..<n { for x in 0..<n where (x / 2 + y / 2) % 2 == 0 { textured[y * n + x] = 900 } }
        let detailed = RawFrame(width: n, height: n, samples: textured, metadata: meta)
        XCTAssertGreaterThan(detailed.greenSharpness(), flat.greenSharpness())
    }
}
