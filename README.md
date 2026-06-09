# Rawloom

**A computational-photography camera for iOS that reproduces the algorithm behind Adobe's
*Project Indigo*.**

Project Indigo (Marc Levoy, Florian Kainz et al., Adobe, 2025) is a direct descendant of the
Google HDR+ / Night Sight lineage. It captures a long burst of deliberately *underexposed* raw
frames, aligns them to a single reference, merges them to suppress noise and recover highlight
detail, optionally super-resolves using natural hand tremor, and finishes the merged raw with a
careful, SLR-like tone-and-color rendering. Rawloom implements that same pipeline end-to-end.

```
                 ┌─────────────────────── Rawloom pipeline ───────────────────────┐
 ZSL ring buffer │  capture → select ref → align → merge → (super-res) → finish    │  DNG + JPEG
   (raw Bayer)   └────────────────────────────────────────────────────────────────┘
```

See **[docs/PIPELINE.md](docs/PIPELINE.md)** for the complete, stage-by-stage algorithm — this is
the heart of the project and the document to read first. **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**
maps the algorithm onto the codebase.

---

## What's here

| Layer | Where | Summary |
|-------|-------|---------|
| **Algorithm core** | `Sources/RawloomCore` | Platform-agnostic Metal pipeline: pyramid, alignment, frequency-domain robust merge, drizzle super-resolution, finishing (demosaic → tone map → color). Builds & unit-tests on macOS with synthetic data. |
| **Metal kernels** | `Sources/RawloomCore/Shaders/*.metal` | All heavy lifting: pyramid build, tile alignment, Wiener merge, demosaic, local-Laplacian tone map, color. |
| **Capture** | `App/Camera` | AVFoundation zero-shutter-lag raw burst capture (iOS only). |
| **App / UI** | `App` | SwiftUI camera app with Photo / Night modes. |
| **Output** | `Sources/RawloomCore/Output` | Computed-raw **DNG** writer + display **JPEG** encoder. |

## Building

The **algorithm core** builds and tests anywhere Swift + Metal exist (incl. macOS):

```bash
swift build            # builds RawloomCore + compiles the .metal kernels into a metallib
swift test             # runs the pipeline unit tests on synthetic mosaics
```

The **full iOS app** (capture + UI) is assembled with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate      # reads project.yml → Rawloom.xcodeproj
open Rawloom.xcodeproj # build & run on a device (raw capture needs real hardware)
```

> Raw burst capture requires a physical iPhone — the Simulator has no camera and no
> `AVCapturePhotoOutput` raw support.

### Running on a real iPhone (real raw capture)

The Simulator only runs the *synthetic* capture path. To exercise the real Bayer-raw burst
(`AVFoundationCaptureSource`) you need a device:

1. **One-time:** Xcode ▸ Settings ▸ Accounts ▸ add your Apple ID (a free account works — it creates a
   "Personal Team" and a development certificate).
2. `xcodegen generate && open Rawloom.xcodeproj`
3. Select the **RawloomApp** target ▸ *Signing & Capabilities* ▸ tick *Automatically manage signing*
   ▸ choose your **Team**. If the bundle id clashes, change `PRODUCT_BUNDLE_IDENTIFIER` to something
   unique (e.g. `com.<you>.rawloom`).
4. Plug in the iPhone, unlock it, tap **Trust**. Pick it as the run destination and press **⌘R**.
   First launch: on the phone, *Settings ▸ General ▸ VPN & Device Management* ▸ trust your developer
   cert. Grant the camera permission, then tap the shutter.
5. **Get the output files:** the JPEG + computed-raw DNG are written to the app's Documents
   (`UIFileSharingEnabled` is on) — open Finder ▸ *your iPhone* ▸ *Files* ▸ **Rawloom**, or the Files
   app ▸ *On My iPhone ▸ Rawloom*, and copy out `rawloom_*.dng` / `.jpg`.

CLI alternative (after setting a team): find the device with `xcrun devicectl list devices`, then
`xcodebuild -scheme RawloomApp -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAMID> build`.

Notes: needs an iPhone whose main camera supports raw (all recent models); ZSL is approximated by a
tight sequential burst; free signing certs expire after 7 days (just re-run from Xcode). The default
color matrix is identity, so colours are approximate until a per-device CCM is wired in — see
`docs/PIPELINE.md` §6.5.

## Status

Working end-to-end and **verified on the iOS Simulator** (19 XCTest cases, incl. real Metal GPU
kernels — `make test-sim`):

- ✅ raw ingest, grayscale pyramid, **coarse-to-fine alignment** (recovers known sub-pixel shifts)
- ✅ **robust multi-frame merge** — denoises a static burst by >2 dB and **rejects a moving object**
  (no ghosting) vs a naive average
- ✅ **finishing** — demosaic → WB → CCM → local/global tone → sRGB (faithful end-to-end render)
- ✅ **computed-raw DNG** (16-bit linear CFA) + **JPEG** output
- ✅ **SwiftUI app** builds & runs on the Simulator (synthetic capture → pipeline → display → save)

Deliberately left as documented-but-optional refinements: the frequency-domain (DFT/Wiener) merge
(the spatial robust merge is the default), drizzle super-resolution (`docs/PIPELINE.md` §5), and the
JPEG HDR gain map. This is a faithful, readable re-implementation of the *published* Indigo/HDR+
algorithm — not Adobe's proprietary code; numeric defaults follow the HDR+ (Hasinoff 2016),
Super-Res Zoom (Wronski 2019) and Night Sight (Liba 2019) papers and Levoy's Indigo write-up
(citations in `docs/PIPELINE.md`).

## License

MIT. See `LICENSE`.
