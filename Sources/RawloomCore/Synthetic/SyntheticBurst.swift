import Foundation
import simd

/// An object that moves independently of the camera between frames — used to test that the robust
/// merge rejects it (no ghosting) instead of averaging it into the static background.
public struct MovingObject: Sendable {
    public var origin: SIMD2<Float>      // top-left at frame 0 (pixels)
    public var size: SIMD2<Float>        // width, height (pixels)
    public var velocity: SIMD2<Float>    // pixels per frame
    public var color: SIMD3<Float>       // linear RGB
    public init(origin: SIMD2<Float>, size: SIMD2<Float>, velocity: SIMD2<Float>, color: SIMD3<Float>) {
        self.origin = origin; self.size = size; self.velocity = velocity; self.color = color
    }
}

/// Parameters for synthesising a raw burst from a clean scene.
public struct SyntheticBurstSpec: Sendable {
    public var frameCount: Int
    public var iso: Double
    public var exposureDuration: Double
    /// Std-dev of per-frame sub-pixel hand tremor (px). Indigo measured ≈0.89 px (1σ).
    public var tremorSigma: Float
    /// A deterministic camera shift (Bayer px) added to every *alternate* frame (frame 0 stays the
    /// reference at zero). Lets tests assert the aligner recovers a known motion (`-globalShift`).
    public var globalShift: SIMD2<Float>
    public var cfa: CFAPattern
    public var whiteLevel: Float
    public var blackLevel: Float
    /// Scene-radiance scale emulating Indigo's highlight-protecting under-exposure (<1 darkens).
    public var underexposure: Float
    public var movingObject: MovingObject?
    public var addNoise: Bool
    public var seed: UInt64

    public init(
        frameCount: Int = 8,
        iso: Double = 800,
        exposureDuration: Double = 1.0 / 120,
        tremorSigma: Float = 0.6,
        globalShift: SIMD2<Float> = .zero,
        cfa: CFAPattern = .rggb,
        whiteLevel: Float = 16383,
        blackLevel: Float = 512,
        underexposure: Float = 0.5,
        movingObject: MovingObject? = nil,
        addNoise: Bool = true,
        seed: UInt64 = 1
    ) {
        self.frameCount = frameCount
        self.iso = iso
        self.exposureDuration = exposureDuration
        self.tremorSigma = tremorSigma
        self.globalShift = globalShift
        self.cfa = cfa
        self.whiteLevel = whiteLevel
        self.blackLevel = blackLevel
        self.underexposure = underexposure
        self.movingObject = movingObject
        self.addNoise = addNoise
        self.seed = seed
    }
}

/// The output of ``SyntheticBurstGenerator``: the noisy burst plus everything a test needs to score
/// the pipeline against ground truth.
public struct GeneratedBurst: Sendable {
    /// Noisy, sub-pixel-shifted raw frames. Frame 0 is the reference (zero shift).
    public var frames: [RawFrame]
    /// Noise-free frame-0 of the *static* scene (no moving object) — the PSNR reference.
    public var cleanReference: RawFrame
    /// The clean full-RGB scene.
    public var groundTruthRGB: SyntheticScene
    /// Camera shift applied to each frame (frame 0 = .zero). The aligner should recover `-shift`.
    public var cameraShifts: [SIMD2<Float>]
    /// Noise model corresponding to `spec.iso`.
    public var noiseModel: NoiseModel
}

/// Generates a raw Bayer burst from a clean scene with controlled sub-pixel motion and a calibrated
/// Poisson–Gaussian noise model. Deterministic for a given `seed`. See `docs/PIPELINE.md` §1, and
/// `docs/TESTING.md` for how the tests use it.
public enum SyntheticBurstGenerator {

    public static func generate(scene: SyntheticScene, spec: SyntheticBurstSpec) -> GeneratedBurst {
        let w = scene.width, h = scene.height
        let noise = NoiseModel.estimated(iso: spec.iso)
        var rng = SeededGenerator(seed: spec.seed)

        // Camera shifts: frame 0 is the reference; the rest jitter by Gaussian tremor plus the
        // deterministic global shift.
        var shifts: [SIMD2<Float>] = [.zero]
        for _ in 1..<max(spec.frameCount, 1) {
            shifts.append(SIMD2(rng.nextGaussian() * spec.tremorSigma + spec.globalShift.x,
                                rng.nextGaussian() * spec.tremorSigma + spec.globalShift.y))
        }

        let meta = { (timestamp: Double) in
            RawImageMetadata(
                cfa: spec.cfa,
                blackLevel: SIMD4(repeating: spec.blackLevel),
                whiteLevel: spec.whiteLevel,
                iso: spec.iso,
                exposureDuration: spec.exposureDuration,
                timestamp: timestamp,
                whiteBalance: .neutral,
                colorMatrix: .identity,
                noise: noise
            )
        }

        var frames: [RawFrame] = []
        frames.reserveCapacity(spec.frameCount)
        for (f, shift) in shifts.enumerated() {
            let samples = mosaic(scene: scene, spec: spec, shift: shift, frameIndex: f,
                                 noise: noise, addNoise: spec.addNoise, rng: &rng)
            frames.append(RawFrame(width: w, height: h, samples: samples,
                                   metadata: meta(Double(f) * spec.exposureDuration)))
        }

        // Noise-free static reference (no moving object) for PSNR scoring.
        var refRng = SeededGenerator(seed: spec.seed ^ 0xABCD)
        var refSpec = spec
        refSpec.movingObject = nil
        let cleanSamples = mosaic(scene: scene, spec: refSpec, shift: .zero, frameIndex: 0,
                                  noise: noise, addNoise: false, rng: &refRng)
        let clean = RawFrame(width: w, height: h, samples: cleanSamples, metadata: meta(0))

        return GeneratedBurst(frames: frames, cleanReference: clean,
                              groundTruthRGB: scene, cameraShifts: shifts, noiseModel: noise)
    }

    /// Render one mosaiced frame: shift the scene, overlay any moving object, mosaic to the CFA,
    /// add signal-dependent noise, and quantise to raw codes.
    private static func mosaic(
        scene: SyntheticScene,
        spec: SyntheticBurstSpec,
        shift: SIMD2<Float>,
        frameIndex: Int,
        noise: NoiseModel,
        addNoise: Bool,
        rng: inout SeededGenerator
    ) -> [UInt16] {
        let w = scene.width, h = scene.height
        var out = [UInt16](repeating: 0, count: w * h)
        let span = spec.whiteLevel - spec.blackLevel

        // Moving-object rectangle for this frame.
        var moRect: (x0: Float, y0: Float, x1: Float, y1: Float)?
        if let mo = spec.movingObject {
            let o = mo.origin + mo.velocity * Float(frameIndex)
            moRect = (o.x, o.y, o.x + mo.size.x, o.y + mo.size.y)
        }

        for y in 0..<h {
            for x in 0..<w {
                var rgb = scene.sample(x: Float(x) + shift.x, y: Float(y) + shift.y)
                if let r = moRect, Float(x) >= r.x0, Float(x) < r.x1, Float(y) >= r.y0, Float(y) < r.y1 {
                    rgb = spec.movingObject!.color
                }
                rgb *= spec.underexposure

                let ci = spec.cfa.colorIndex(x: x, y: y)
                var value = max(rgb[ci], 0)
                if addNoise {
                    let sigma = noise.standardDeviation(at: value)
                    value = max(value + rng.nextGaussian() * sigma, 0)
                }
                let code = spec.blackLevel + value * span
                out[y * w + x] = UInt16(min(max(code, 0), spec.whiteLevel).rounded())
            }
        }
        return out
    }
}

// MARK: - Quality metrics (shared by tests)

public enum ImageMetric {
    /// PSNR (dB) between two raw mosaics of equal size, computed on normalised linear values.
    public static func psnr(_ a: RawFrame, _ b: RawFrame) -> Double {
        precondition(a.width == b.width && a.height == b.height)
        var mse = 0.0
        let n = a.width * a.height
        for i in 0..<n {
            let av = Double(a.samples[i]), bv = Double(b.samples[i])
            let d = av - bv
            mse += d * d
        }
        mse /= Double(n)
        if mse < 1e-9 { return 120 }
        let peak = Double(a.metadata.whiteLevel)
        return 10 * Foundation.log10((peak * peak) / mse)
    }

    /// Mean absolute difference (normalised [0,1]) over a rectangular region — used for ghost checks.
    public static func meanAbsDiff(_ a: RawFrame, _ b: RawFrame,
                                   region: (x: Int, y: Int, w: Int, h: Int)? = nil) -> Double {
        let r = region ?? (0, 0, a.width, a.height)
        var acc = 0.0
        var count = 0
        for y in r.y..<min(r.y + r.h, a.height) {
            for x in r.x..<min(r.x + r.w, a.width) {
                acc += Double(abs(a.normalized(x: x, y: y) - b.normalized(x: x, y: y)))
                count += 1
            }
        }
        return count > 0 ? acc / Double(count) : 0
    }
}
