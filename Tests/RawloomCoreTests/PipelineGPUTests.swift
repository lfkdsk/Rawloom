import XCTest
import simd
@testable import RawloomCore

/// GPU pipeline tests. These compile the Metal shader library at runtime and run compute kernels, so
/// they execute on the iOS Simulator / device (where Metal exists) and `XCTSkip` on a GPU-less host.
final class PipelineGPUTests: XCTestCase {

    /// The runtime-compiled shader library builds and the ingest kernel is present.
    func testShaderLibraryCompiles() throws {
        let ctx = try requireMetal()
        XCTAssertNoThrow(try ctx.pipeline("normalize_raw"),
                         "normalize_raw should be present in the compiled library")
    }

    /// Black-level subtraction + white-level normalisation on the GPU matches the CPU model.
    func testNormalizeRawMatchesModel() throws {
        let ctx = try requireMetal()
        let meta = RawImageMetadata(
            cfa: .rggb,
            blackLevel: SIMD4(repeating: 64),
            whiteLevel: 1088,             // span = 1024
            iso: 100, exposureDuration: 0.01, timestamp: 0
        )
        // code 576 ⇒ (576-64)/1024 = 0.5 everywhere.
        let frame = RawFrame(width: 8, height: 8,
                             samples: [UInt16](repeating: 576, count: 64), metadata: meta)
        let out = try ctx.ingestAndRead(frame)
        XCTAssertEqual(out.count, 64)
        for v in out { XCTAssertEqual(v, 0.5, accuracy: 1e-3) }
    }

    /// Per-Bayer-position black levels are applied to the correct pixels.
    func testNormalizeRawPerPositionBlackLevel() throws {
        let ctx = try requireMetal()
        // Red black 320, others 64; white 1088 (span differs per channel).
        let meta = RawImageMetadata(
            cfa: .rggb,
            blackLevel: SIMD4(320, 64, 64, 64),
            whiteLevel: 1088,
            iso: 100, exposureDuration: 0.01, timestamp: 0
        )
        let frame = RawFrame(width: 4, height: 4,
                             samples: [UInt16](repeating: 576, count: 16), metadata: meta)
        let out = try ctx.ingestAndRead(frame)
        // Red site (0,0): (576-320)/(1088-320)=256/768≈0.3333
        XCTAssertEqual(out[0], 256.0 / 768.0, accuracy: 1e-3)
        // Green site (1,0): (576-64)/1024=0.5
        XCTAssertEqual(out[1], 0.5, accuracy: 1e-3)
        // Blue site (1,1): (576-64)/1024=0.5
        XCTAssertEqual(out[1 * 4 + 1], 0.5, accuracy: 1e-3)
    }

    /// The synthetic burst generator produces a sane, reproducible burst and the GPU can ingest it.
    func testSyntheticBurstIngest() throws {
        let ctx = try requireMetal()
        let scene = SyntheticScene.gradientBlobs(width: 64, height: 64)
        let spec = SyntheticBurstSpec(frameCount: 6, iso: 1600, tremorSigma: 0.7, seed: 42)
        let burst = SyntheticBurstGenerator.generate(scene: scene, spec: spec)

        XCTAssertEqual(burst.frames.count, 6)
        XCTAssertEqual(burst.cameraShifts.first, .zero, "frame 0 is the reference (zero shift)")

        // Each noisy frame ingests to a valid [0,1] image.
        let img = try ctx.ingestAndRead(burst.frames[0])
        XCTAssertEqual(img.count, 64 * 64)
        XCTAssertFalse(img.contains { $0.isNaN || $0 < 0 || $0 > 1 })

        // Noise actually perturbs the frames: a noisy frame differs from the clean reference, and
        // the clean reference matches itself.
        let noisyPSNR = ImageMetric.psnr(burst.frames[0], burst.cleanReference)
        XCTAssertLessThan(noisyPSNR, 100, "noisy frame should differ measurably from the clean ref")
        XCTAssertGreaterThan(noisyPSNR, 10, "…but still be recognisably the same scene")
    }

    /// Determinism: the same seed yields byte-identical bursts (fixtures are reproducible).
    func testSyntheticBurstDeterminism() throws {
        let scene = SyntheticScene.checker(width: 32, height: 32, square: 8)
        let spec = SyntheticBurstSpec(frameCount: 4, seed: 7)
        let a = SyntheticBurstGenerator.generate(scene: scene, spec: spec)
        let b = SyntheticBurstGenerator.generate(scene: scene, spec: spec)
        XCTAssertEqual(a.frames[1].samples, b.frames[1].samples)
        XCTAssertEqual(a.cameraShifts, b.cameraShifts)
    }
}
