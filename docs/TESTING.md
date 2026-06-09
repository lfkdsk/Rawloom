# Testing Rawloom on the iOS Simulator

Rawloom's pipeline is GPU code (Metal compute) with no camera dependency until the very edge
(capture). That makes the **iOS Simulator** an excellent test target: on Apple Silicon the Simulator
exposes a real Metal device, and `XCTest` runs there — so the alignment / merge / finishing kernels
execute *for real* against synthetic raw bursts, end to end, with no phone required.

This document describes the complete, runnable test workflow.

## TL;DR

```bash
make test-sim          # build for the iOS Simulator, boot it, run the whole XCTest suite
make test-sim-gpu      # only the Metal/GPU pipeline tests
make build             # fast host compile of the algorithm core (no simulator)
```

`make test-sim` is the **primary correctness gate**. It prints a pass/fail summary and writes an
`.xcresult` bundle to `.build/sim-tests.xcresult`.

## Why not `swift test`?

`swift test` runs on the host. Two problems on a typical dev box / CI:

1. **XCTest** isn't present in a Command-Line-Tools-only toolchain (it ships with Xcode).
2. A headless host often has **no Metal device**, so GPU tests can't run anyway.

So `swift test` is kept only as an optional host check; the real suite runs on the Simulator, which
has both XCTest and Metal. GPU tests call `requireMetal()`, which `XCTSkip`s gracefully if a host
ever lacks a GPU — they simply *run* on the Simulator and on device.

## How it works

`scripts/test-sim.sh`:

1. Points `DEVELOPER_DIR` at `Xcode.app` so the full toolchain (xcodebuild, simctl, the `metal`
   compiler, simulator runtimes) is used **without** `sudo xcode-select` — it never disturbs a
   machine whose global `xcode-select` is the Command Line Tools.
2. Resolves a concrete, *available* simulator (default **iPhone 17**; override with `SIM_NAME=…`),
   falling back to the first available iPhone if that exact model is missing.
3. Runs `xcodebuild test -scheme Rawloom -destination 'platform=iOS Simulator,id=…'`, building the
   SwiftPM package's `RawloomCore` + `RawloomCoreTests` for the simulator and executing them on it.
4. Summarises the result bundle with `xcresulttool` (pass/fail/skip counts, failure messages).

Because the Metal shaders are **compiled at runtime** from source (`MetalContext.loadLibrary`), there
is no offline `.metal` build step — the same library that runs on device compiles inside the
Simulator process.

## What the suite covers

| File | Runs on | What it checks |
|------|---------|----------------|
| `ModelTests` | host + sim | CFA geometry, noise model, colour math, raw normalisation, sharpness — pure CPU. |
| `PipelineGPUTests` | **sim / device** | shader library compiles; `normalize_raw` (incl. per-position black levels) matches the CPU model; synthetic-burst ingest is valid `[0,1]`; generator determinism. |
| _added per stage_ | sim / device | alignment recovers known sub-pixel shifts; merge denoises a static scene by ~√N and **rejects** a moving object (no ghost); finishing output is in-range & plausible; end-to-end PSNR beats a single frame. |

### Synthetic bursts — the test fixture

`SyntheticBurstGenerator` (in `RawloomCore`, so the app's simulator demo mode can reuse it) turns a
clean procedural scene (`SyntheticScene.gradientBlobs / .checker / .siemensStar`) into a raw Bayer
burst with:

- **known sub-pixel camera shifts** (Gaussian hand-tremor, σ configurable; Indigo measured ≈0.89 px)
  → lets tests assert the aligner recovers `-shift` within tolerance;
- a **calibrated Poisson–Gaussian noise model** keyed to ISO → lets tests measure denoising in dB;
- an optional **independently moving object** → lets tests assert the robust merge doesn't smear it;
- a **noise-free reference frame** + the clean RGB scene as **ground truth** for PSNR.

Everything is seeded (`SeededGenerator`, SplitMix64), so fixtures are bit-for-bit reproducible.

> **Note — the app project shadows the package scheme.** Once you've run `xcodegen generate` (or
> `make app`/`make screenshots`), a `Rawloom.xcodeproj` exists, and `xcodebuild` would resolve *its*
> schemes (`RawloomApp`, `RawloomCore`) instead of the SwiftPM package's auto-generated `Rawloom`
> test scheme. `scripts/test-sim.sh` handles this by temporarily stashing the generated project for
> the duration of the package test (restored via a `trap`), so `make test-sim` works whether or not
> the app project is present.

## CI

`.github/workflows/ci.yml` runs two jobs on a `macos-15` runner: a fast `swift build`, and the full
Simulator suite via `scripts/test-sim.sh` (uploading the `.xcresult` as an artifact). The script's
device fallback means it adapts to whatever simulators the runner image provides.

## Running the app on the Simulator

The Simulator has no camera, so the app selects a **synthetic capture source** there (replaying
`SyntheticBurstGenerator` output through the exact same pipeline) instead of AVFoundation. That makes
the UI, mode switching, and the full process-and-display path testable on the Simulator too;
`scripts/screenshots.sh` drives it and captures `simctl io … screenshot`s. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the `CaptureSource` abstraction.
