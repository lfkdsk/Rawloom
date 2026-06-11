import XCTest
import simd
@testable import RawloomCore

/// The opt-in per-stage capture used by the "how it was made" inspector. Verifies the pipeline emits
/// the full, ordered set of stage previews with valid thumbnails + overlays — and that the default
/// path stays free of them.
final class StagePreviewTests: XCTestCase {

    private func makeBurst() -> GeneratedBurst {
        let scene = SyntheticScene.gradientBlobs(width: 128, height: 128)
        let spec = SyntheticBurstSpec(frameCount: 8, iso: 1600, tremorSigma: 0.5,
                                      underexposure: 0.2, addNoise: true, seed: 3)
        return SyntheticBurstGenerator.generate(scene: scene, spec: spec)
    }

    func testCaptureStagesEmitsOrderedPreviews() throws {
        let ctx = try requireMetal()
        let pipeline = IndigoPipeline(context: ctx)
        let out = try pipeline.process(frames: makeBurst().frames, config: .photo, captureStages: true)

        // Full ordered story: capture → reference → align → merge → demosaic → colour → result.
        XCTAssertEqual(out.stages.map(\.kind),
                       [.capture, .reference, .align, .merge, .demosaic, .color, .result])

        for stage in out.stages {
            let img = stage.image
            XCTAssertEqual(img.rgba8.count, img.width * img.height * 4, "\(stage.kind) buffer size")
            XCTAssertLessThanOrEqual(max(img.width, img.height), 1024, "\(stage.kind) downscaled")
            XCTAssertGreaterThan(img.width, 0); XCTAssertGreaterThan(img.height, 0)
            XCTAssertFalse(stage.title.isEmpty); XCTAssertFalse(stage.detail.isEmpty)
        }

        // The two showpiece overlays are present, the others absent.
        if case .motionField(let v, let cols, let rows, _)? = stage(.align, in: out).overlay {
            XCTAssertEqual(v.count, cols * rows, "one motion vector per tile")
            XCTAssertGreaterThan(v.count, 0)
        } else { XCTFail("align stage should carry a motion field overlay") }

        if case .heatmap(let map, let caption)? = stage(.merge, in: out).overlay {
            XCTAssertEqual(map.rgba8.count, map.width * map.height * 4)
            XCTAssertFalse(caption.isEmpty)
        } else { XCTFail("merge stage should carry a weight heatmap overlay") }

        XCTAssertNil(stage(.result, in: out).overlay)

        // The finished thumbnail must actually carry signal (not a blank buffer).
        let result = stage(.result, in: out).image
        let nonBlack = result.rgba8.contains { $0 > 8 }
        XCTAssertTrue(nonBlack, "result thumbnail should not be all black")
    }

    func testDefaultPathProducesNoStages() throws {
        let ctx = try requireMetal()
        let pipeline = IndigoPipeline(context: ctx)
        let out = try pipeline.process(frames: makeBurst().frames, config: .photo)
        XCTAssertTrue(out.stages.isEmpty, "stage capture must be opt-in")
    }

    private func stage(_ kind: StagePreview.Kind, in out: ProcessedImage) -> StagePreview {
        out.stages.first { $0.kind == kind }!
    }
}
