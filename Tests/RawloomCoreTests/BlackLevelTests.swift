import XCTest
import simd
@testable import RawloomCore

/// Pins down the real-device **pink/magenta cast** and its fix. Pure CPU — runs anywhere.
///
/// The cast is not a colour-matrix problem (an identity CCM makes the image *green*, the opposite
/// hue). It is an *un-subtracted black pedestal* amplified by white balance: WB scales red and blue by
/// gains > 1 while green stays at 1, so any pedestal left in the signal lifts R and B above G → pink.
final class BlackLevelTests: XCTestCase {

    /// Apply the colour-affecting part of finishing to a uniform neutral patch: normalise the raw
    /// codes with `blackUsed`, then white-balance. Returns the linear camera-RGB triplet.
    private func finishNeutral(blackUsed: Float,
                               pedestal: Float = 512,
                               whiteLevel: Float = 16383,
                               wb: WhiteBalanceGains) -> SIMD3<Float> {
        // A perfectly neutral object: per-channel raw signal chosen so that *correct* WB returns it to
        // a flat grey at normalised level 0.3. (Green is the brightest raw channel; R and B sit lower
        // and WB lifts them — exactly why a leftover pedestal turns pink.)
        let target: Float = 0.3
        let span = whiteLevel - pedestal
        func code(_ signalN: Float) -> UInt16 { UInt16(pedestal + signalN * span) }
        let codeR = code(target / wb.red)
        let codeG = code(target / wb.green)
        let codeB = code(target / wb.blue)

        // 2×2 RGGB cell carrying those codes, normalised by the (possibly wrong) black level.
        let meta = RawImageMetadata(
            cfa: .rggb, blackLevel: SIMD4(repeating: blackUsed), whiteLevel: whiteLevel,
            iso: 100, exposureDuration: 1.0 / 120, timestamp: 0)
        let frame = RawFrame(width: 2, height: 2,
                             samples: [codeR, codeG, codeG, codeB], metadata: meta)
        let cam = SIMD3(frame.normalized(x: 0, y: 0),   // R site
                        frame.normalized(x: 1, y: 0),   // G site
                        frame.normalized(x: 1, y: 1))   // B site
        return cam * wb.simd                            // white balance
    }

    func testUnsubtractedPedestalCausesPinkCast() {
        // iPhone-like AWB: red & blue lifted relative to green.
        let wb = WhiteBalanceGains(red: 2.0, green: 1, blue: 1.5)

        // Correct black level → neutral object stays neutral.
        let ok = finishNeutral(blackUsed: 512, wb: wb)
        XCTAssertEqual(ok.x, ok.y, accuracy: 2e-3, "R should match G when the pedestal is removed")
        XCTAssertEqual(ok.z, ok.y, accuracy: 2e-3, "B should match G when the pedestal is removed")

        // Parse failed → black level 0 → pedestal left in → pink.
        let pink = finishNeutral(blackUsed: 0, wb: wb)
        XCTAssertGreaterThan(pink.x, pink.y * 1.05, "red lifted above green ⇒ pink")
        XCTAssertGreaterThan(pink.z, pink.y * 1.02, "blue lifted above green ⇒ pink")
        // The cast is a genuine hue shift, not just a brightness change: R and B both exceed G.
        XCTAssertGreaterThan(min(pink.x, pink.z), pink.y)
    }

    func testEstimatorRecoversPedestal() {
        // 64×64 RGGB frame with a real pedestal + signal and a handful of stuck-low pixels.
        let w = 64, h = 64
        let pedestal: UInt16 = 528
        var s = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                // Some near-black texture (down to the pedestal) plus brighter content.
                let signal = UInt16(((x * 7 + y * 13) % 400))
                s[y * w + x] = pedestal + signal
            }
        }
        s[0] = 3; s[5 * w + 5] = 11   // stuck-low outliers — must not drag the estimate to ~0

        let est = BlackLevelEstimator.estimate(samples: s, width: w, height: h, cfa: .rggb)
        for c in [est.x, est.y, est.z, est.w] {
            XCTAssertEqual(c, Float(pedestal), accuracy: 24,
                           "should recover the pedestal, robust to stuck pixels")
        }
    }

    func testLevelScaleFactorDetectsBitDepthMismatch() {
        // The real-device case: 12-bit DNG white, 14-bit buffer running to 14318 ⇒ ×4.
        XCTAssertEqual(RawLevelScale.factor(dngWhite: 4095, sampleMax: 14318), 4)
        // 13-bit native in a 14-bit container ⇒ ×2.
        XCTAssertEqual(RawLevelScale.factor(dngWhite: 8191, sampleMax: 16000), 2)
        // Genuine 14-bit levels (data never exceeds white) ⇒ no scaling.
        XCTAssertEqual(RawLevelScale.factor(dngWhite: 16383, sampleMax: 16383), 1)
        XCTAssertEqual(RawLevelScale.factor(dngWhite: 16383, sampleMax: 12000), 1)
        // 12-bit levels with a right-justified 12-bit buffer (data fits) ⇒ no scaling.
        XCTAssertEqual(RawLevelScale.factor(dngWhite: 4095, sampleMax: 4000), 1)
    }

    func testBitDepthMismatchCausesPurpleAndScaleFixesIt() {
        // Exact reproduction of the device readout: 14-bit pixel buffer (black ~2112, white 16383),
        // but 12-bit DNG levels (528 / 4095), warm-light WB with a strong blue gain.
        let wb = WhiteBalanceGains(red: 1.6, green: 1, blue: 2.89)
        let pedestal14: Float = 2112, white14: Float = 16383
        let dngBlack: Float = 528, dngWhite: Float = 4095

        // A mid-dark neutral patch encoded in 14-bit codes, finished with the given (black, white).
        func finish(black: Float, white: Float) -> SIMD3<Float> {
            let target: Float = 0.1
            let span = white14 - pedestal14
            func code(_ sN: Float) -> Float { pedestal14 + sN * span }
            func norm(_ c: Float) -> Float { min(max((c - black) / (white - black), 0), 1) }
            let cam = SIMD3(norm(code(target / wb.red)), norm(code(target / wb.green)), norm(code(target / wb.blue)))
            return cam * wb.simd
        }

        let f = RawLevelScale.factor(dngWhite: dngWhite, sampleMax: 14318)
        XCTAssertEqual(f, 4)

        // Bug: 12-bit levels on 14-bit data ⇒ huge residual pedestal ⇒ blue ≫ green ⇒ purple.
        let buggy = finish(black: dngBlack, white: dngWhite)
        XCTAssertGreaterThan(buggy.z, buggy.y * 1.5)

        // Fix: scale the levels by the detected factor ⇒ neutral.
        let fixed = finish(black: dngBlack * f, white: dngWhite * f)
        XCTAssertEqual(fixed.x, fixed.y, accuracy: 3e-3)
        XCTAssertEqual(fixed.z, fixed.y, accuracy: 3e-3)
    }

    func testEstimatorMuchBetterThanZeroOnRealisticData() {
        // Even when nothing in the scene is exactly at the pedestal, the estimate stays close to the
        // true floor and far below the signal mean — so subtracting it removes most of the cast.
        let w = 48, h = 48
        let pedestal: Float = 512
        var s = [UInt16](repeating: 0, count: w * h)
        for i in 0..<(w * h) { s[i] = UInt16(pedestal) + UInt16(40 + (i % 2000)) }
        let est = BlackLevelEstimator.estimate(samples: s, width: w, height: h, cfa: .rggb)
        for c in [est.x, est.y, est.z, est.w] {
            XCTAssertGreaterThan(c, pedestal * 0.9)            // not collapsed to 0
            XCTAssertLessThan(c, pedestal + 120)               // not eating real signal
        }
    }
}
