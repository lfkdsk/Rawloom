# Rawloom architecture

How the algorithm in [PIPELINE.md](PIPELINE.md) maps onto the code, and the conventions that keep the
GPU pipeline consistent.

## Two layers

```
┌─ App (iOS only, assembled by project.yml / XcodeGen) ───────────────────────┐
│  Camera/   AVFoundation ZSL raw-burst capture, ring buffer, motion metering  │
│  UI/       SwiftUI viewfinder, Photo/Night modes, result preview             │
│  depends on ↓                                                                │
└──────────────────────────────────────────────────────────────────────────-─┘
┌─ RawloomCore (SwiftPM, iOS + macOS) ────────────────────────────────────────┐
│  Model/      RawFrame, CFAPattern, NoiseModel, Color, PipelineConfiguration  │
│  Metal/      MetalContext (device, queue, runtime-compiled library), textures│
│  Shaders/    *.metal — all compute kernels                                   │
│  Pipeline/   RawIngest → ReferenceSelection → Alignment → Merge →            │
│              SuperResolution → Finishing → IndigoPipeline (orchestrator)     │
│  Output/     DNGWriter, JPEGEncoder, GainMap                                  │
│  Synthetic/  SyntheticScene + SyntheticBurstGenerator (tests & sim demo)     │
└──────────────────────────────────────────────────────────────────────────-─┘
```

The split exists so the **algorithm is portable and testable without a phone**: `RawloomCore` has no
AVFoundation/UIKit dependency, builds for macOS and the iOS Simulator, and runs its Metal kernels
against synthetic bursts in CI. Only the thin capture/UI shell is iOS-only. See
[TESTING.md](TESTING.md).

## Capture is an abstraction

The pipeline never talks to AVFoundation directly. It consumes `[RawFrame]`. Capture is hidden behind
a source protocol so the same pipeline runs on device and in the Simulator:

```swift
protocol CaptureSource {
    func captureBurst(mode: CaptureMode) async throws -> [RawFrame]
}
// AVFoundationCaptureSource  — real ZSL raw burst (device).
// SyntheticCaptureSource     — replays SyntheticBurstGenerator output (Simulator / previews / tests).
```

On the Simulator (no camera) the app selects `SyntheticCaptureSource`, so the UI and the full
process-and-display path are exercisable there.

## Data flow & texture conventions

```
RawFrame ──uploadRaw──▶ r16Uint ──normalize_raw──▶ r32Float (normalised linear Bayer)
                                                      │
                          bayer_to_gray + downsample_half │ (per frame)
                                                      ▼
                                              GrayPyramid (r32Float levels)
        reference ┌───────────────── align_level (coarse→fine) ───────────────┐ alternate
                  ▼                                                            ▼
            AlignmentField (rg32Float per-tile vectors)  ──▶ Merge (DFT, per Bayer plane)
                                                      │
                                              merged r32Float Bayer ──▶ DNG (16-bit linear)
                                                      │
                          Finishing: demosaic → CCM → tone map → sharpen → sRGB
                                                      ▼
                                              rgba32Float ──▶ JPEG (8-bit) + gain map
```

| Data | Texture format | Notes |
|------|----------------|-------|
| raw sensor codes | `.r16Uint` | upload only; immediately normalised |
| normalised Bayer / gray / single plane / luma | `.r32Float` | the scalar working format |
| motion-vector field | `.rg32Float` | one (dx,dy) per tile |
| full-colour image | `.rgba32Float` | finishing & output |

Helpers for all of these (`makeFloat`, `makeRGBA`, `makeField`, `uploadRaw`, `readFloats`,
`readField`) live in `Metal/TextureFactory.swift`.

## Conventions

**Runtime shader compilation.** `MetalContext.loadLibrary` concatenates every `Shaders/*.metal`
(`Common.metal` first — it holds the shared helpers) and compiles them once with
`makeLibrary(source:)`. This removes any build-time dependency on the `metal` compiler, so the package
builds under Command Line Tools alone, and the *same* source compiles inside the Simulator and on
device. A single shader typo fails the whole library — which is exactly why the Simulator test suite
is the gate (`make test-sim`).

**Parameter passing.** Kernels take a small `constant Params&` struct via `setBytes`. Each struct is
declared **twice** — once in the `.metal` file, once as a Swift mirror next to its caller — using
**only 4-byte scalar fields** (`UInt32`/`Int32`/`Float`) in the same order, so the two layouts are
binary-identical with no alignment padding. (Vectors/matrices are passed as separate scalar fields or
flattened arrays to avoid Metal's 16-byte alignment rules.)

**Command buffers.** A pipeline run encodes all stages into one `MTLCommandBuffer` and commits once;
intermediate textures are `.shared` so tests can read them back. `MetalContext.run(_:gridWidth:…)`
wraps the encoder + threadgroup sizing; kernels bounds-check against the real image size.

**Coordinate spaces.** Alignment runs in **grayscale = half Bayer resolution**, so a field vector of
`v` gray-px corresponds to `2v` Bayer-px. The merge scales the field to Bayer space before sampling
the four planes. This is the single most error-prone bookkeeping point; it is asserted by
`AlignmentTests.testAlignmentRecoversKnownShift`.

## Status of modules

| Module | State |
|--------|-------|
| Model, Metal context, RawIngest | ✅ implemented + tested on simulator |
| Pyramid, Alignment, ReferenceSelection | ✅ implemented + tested on simulator |
| Synthetic bursts | ✅ implemented + tested |
| Merge (robust, spatial) | ✅ implemented + tested (denoise + ghost rejection) |
| Finishing (demosaic→tone→color) | ✅ implemented + tested (end-to-end) |
| Output (DNG + JPEG) | ✅ implemented + tested |
| App (capture + UI) | ✅ builds & runs on the Simulator |
| Merge (frequency-domain DFT) | 🚧 optional refinement (spatial path is the default) |
| SuperResolution (drizzle) | ⏳ optional; fully specified in PIPELINE.md §5 |
| JPEG HDR gain map | ⏳ optional; SDR base is written |
