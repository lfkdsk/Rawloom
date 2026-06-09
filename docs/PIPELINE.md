# The Rawloom / Project-Indigo Pipeline

This is the complete, stage-by-stage logic of the imaging pipeline. It is the reference spec the
code follows; every `Sources/RawloomCore` module maps to a section here.

Project Indigo is a member of the **HDR+ family** of burst computational-photography pipelines.
The intellectual lineage is:

- **HDR+** — Hasinoff et al., *"Burst photography for high dynamic range and low-light imaging on
  mobile cameras"*, SIGGRAPH Asia 2016. → align + frequency-domain robust merge + finishing.
- **Super-Res Zoom** — Wronski et al., *"Handheld Multi-Frame Super-Resolution"*, SIGGRAPH 2019.
  → exploit hand tremor to reconstruct a higher-resolution / full-color image without demosaic.
- **Night Sight** — Liba et al., *"Handheld Mobile Photography in Very Low Light"*, SIGGRAPH Asia
  2019. → motion metering, longer bursts, learned AWB.
- **Project Indigo** — Levoy & Kainz, Adobe, 2025. → the above, but with *more* frames (up to 32),
  always-on under-exposure for a natural "full-frame camera" look, lens-aware corrections, and a
  computed-raw DNG output in addition to a hybrid SDR+HDR JPEG.

> **Sourcing note.** Adobe's Indigo write-up states the pipeline's *philosophy* and a few hard
> numbers (32 frames, 16-bit DNG, zero-shutter-lag, super-resolution) but deliberately withholds the
> algorithmic constants (tile sizes, search radii, Wiener parameters). Indigo is, in Levoy's words,
> "a descendant of HDR+ … Night Sight … and super-resolution," so every load-bearing constant below
> comes from those papers and is exposed as a **tunable** in `PipelineConfiguration` — treat them as
> reference defaults to re-tune, not confirmed Indigo values. Where a fact *is* Indigo-specific it is
> marked **[Indigo]**.

The defining idea across all of them: **a single shutter press is actually a burst.** You never
brighten a single noisy exposure; you average many aligned exposures so that read+shot noise falls
as √N, *then* you can afford to lift shadows and apply a strong tone curve without the result
falling apart.

---

## 0. Notation & invariants

- A **raw frame** is a single-channel Bayer mosaic, `W×H`, with a known CFA pattern (Rawloom assumes
  `RGGB` internally and permutes other patterns to it at ingest). Sample values are linear scene
  radiance after **black-level subtraction** and **white-level normalization** to `[0, 1]`.
- The **reference frame** `F_ref` defines the output geometry. Every other frame is an *alternate*
  `F_n`, warped onto the reference's coordinate system before it contributes.
- We work on the **green channel** for alignment (it is the densest, least-noisy channel of the
  mosaic and the luminance proxy), but we **merge all four Bayer planes**.
- Coordinates: tiles are addressed by their top-left corner in reference space. An **alignment
  vector** `u(t) = (dx, dy)` says where tile `t` of the reference is found in the alternate frame.

All stages run on the GPU (Metal). The CPU only orchestrates and moves metadata.

---

## 1. Capture — zero-shutter-lag underexposed raw burst

**Goal:** when the user taps the shutter, we already have the moment. The "shutter" only *selects*
frames that were captured slightly in the past.

### 1.1 The ring buffer (negative shutter lag)

The camera runs continuously the moment the viewfinder opens. Raw frames stream into a fixed-size
**ring buffer**, holding the most recent ~1 s. Each slot keeps the Bayer plane + per-frame metadata
(exposure time, ISO/analog gain, timestamp, gyro sample, lens focus). When the shutter fires:

1. Freeze the ring; **[Indigo]** the reference is the *last frame captured before the press*, and the
   burst that gets merged is drawn from the frames already in the buffer at the press instant. The
   shutter "fires into the past," so perceived shutter lag is **zero or negative** — exactly HDR+'s
   ZSL trick (and Super-Res Zoom's "ring buffer when the user opens the camera").
2. **ZSL applies to Photo mode only.** **[Indigo]** Night mode does *not* use ZSL: because each frame
   is a long exposure, Night begins capturing *after* the press and the user holds still.

→ `App/Camera/RingBuffer.swift`, `BurstCaptureController.swift`.

### 1.2 Exposure strategy — *under*-expose every frame

This is the single most important capture decision and what gives Indigo its look.

- **Every frame in the burst uses the same, short, highlight-protecting exposure.** No frame is "the
  bright one"; there is no exposure bracket. All frames identical exposure ⇒ uniform noise and easy
  alignment (HDR+).
- **[Indigo]** "We under-expose more strongly than most cameras" to avoid clipping highlights — but
  **Adobe publishes no numeric EV**. It is an *adaptive* auto-exposure decision, not a fixed −2 EV.
  Rawloom therefore meters adaptively: pick the exposure so the 95th-percentile highlight lands at
  `highlightHeadroom`·white (default 0.8), and **memorise the compensating gain** to re-apply during
  tone mapping (the HDR+ "memorized gain" trick). Do *not* hard-code a stop value.
- Highlights are therefore *never* blown in any single frame, so HDR is recovered "for free" by
  later lifting shadows from the merged (low-noise) result rather than by fusing different
  exposures.
- The penalty — dark, noisy shadows in each individual frame — is exactly what the **merge** pays
  off: averaging N frames cuts noise by √N (the blog's own framing: 9 frames → ~3×, 32 → ~5.7×).

| Mode  | Burst length `N` | Per-frame exposure | Notes |
|-------|------------------|--------------------|-------|
| Photo | up to 32 (default 8 handheld) | adaptive, short, highlight-protecting | **[Indigo]** ZSL: frames come from the ring. |
| Night | up to 32 | motion-metered, up to ~1 s/frame on a tripod | **[Indigo]** no ZSL; captures after the press. Gyro motion metering. |

**Motion metering (Night):** read the gyro during preview; estimate handshake/scene motion; choose
per-frame exposure as the longest that keeps motion blur under ~1 px, and choose `N` to hit a total
integration-time budget (Night Sight's worked example: 0.14 s×6 → 0.33 s×13, 1–6 s total).
(Liba 2019, §"Motion metering".)

### 1.3 What lands in the pipeline

A `[RawFrame]` of length `N`, all the *same* nominal exposure, plus per-frame metadata. → `Capture/`.

---

## 2. Reference-frame selection

A burst has one frame that everything else is aligned to. Picking a *sharp* reference avoids baking
motion blur into the result.

- Consider only the first ~3 frames (the ones closest in time to the shutter intent / freshest from
  the ring).
- Score each by a **sharpness metric**: the sum of gradient magnitude (or variance of Laplacian) of
  the green channel over the frame. Higher = crisper.
- Pick the max. Ties → the temporally most central frame (more alternates on both sides).

→ `Pipeline/ReferenceSelection.swift`, kernel `sharpness_score` in `Pyramid.metal`.

---

## 3. Alignment — coarse-to-fine tile block matching

We must know, for every region of every alternate frame, the sub-pixel motion that maps it onto the
reference. Indigo/HDR+ use a classic **hierarchical block-matching** aligner (not dense optical
flow): robust, cheap, GPU-friendly.

### 3.1 Grayscale + Gaussian pyramid

First reduce the full-res Bayer to a single-channel grayscale by a **2×2 box filter over each RGGB
quad** (averaging the quad). This halves resolution and—crucially—keeps all motion in multiples of
2 px so the CFA *phase* is preserved (we never align in a way that swaps colour planes).

Build a **4-level Gaussian pyramid** of that grayscale with successive downsampling factors
**2, 4, 4** (grayscale → coarsest), matching HDR+. → `Pyramid.metal` (`bayer_to_gray`,
`gaussian_downsample`).

### 3.2 Block matching per level (coarse → fine)

At the coarsest level, alignment starts from zero. At each finer level the parent's vector is
upsampled and used as the search center; **three candidate upsampled vectors** (the parent tile and
its two nearest neighbours in each spatial dim) are evaluated and the one minimising L1 is kept —
this mitigates errors at moving-object boundaries (HDR+).

For each tile `t` (top-left `p`) of the reference at this level:

```
best = (0,0); bestcost = +inf
for dy in [-R, R]:
  for dx in [-R, R]:
     cost = Σ_{x,y in tile} dist( Ref(p+x,y), Alt(p + u_guess + (dx,dy) + (x,y)) )
     cost += λ * ||(dx,dy)||              # mild regularizer: prefer small, smooth motion
     if cost < bestcost: bestcost, best = cost, (dx,dy)
u(t) = u_guess + best
```

- **Tile size:** **8×8 at the coarsest level, 16×16 at the finer levels** (HDR+).
- **Distance:** **L2 at every level except the finest; L1 at the finest level** (HDR+). L1 is more
  robust to the residual noise that survives to full resolution; L2 is smoother for coarse search.
- **Search radius `R`:** ±4 px per level; the pyramid turns that into a large effective range.
- **Subpixel refinement:** fit a bivariate quadratic to the 3×3 window of costs around the integer
  minimum and solve `μ = −A⁻¹b` for the sub-pixel offset; accept only if `‖μ‖ ≤ 1`. **Skipped at the
  finest level** — at full Bayer resolution a sub-pixel shift would blend adjacent colour planes and
  cause colour fringing. (For the *super-resolution* path, which needs true sub-pixel accuracy, this
  is replaced by 3 iterations of Lucas–Kanade optical-flow refinement — Wronski 2019.)
- Final vectors are scaled **×2** to return from grayscale to full Bayer resolution.
- For the merge, **tiles overlap by 50%** (stride = tile/2); overlap + the merge's window function
  prevents block seams.

Output per alternate: a dense field of sub-pixel vectors `U_n(t)`. → `Pipeline/Alignment/`, kernels
`align_level`, `upsample_alignment` in `Alignment.metal`.

---

## 4. Merge — temporal denoise with robustness (the core)

Now we combine the reference and the *aligned* alternates into one low-noise raw. The hard part is
**robustness**: any tile that didn't align (a moving car, a waving hand, an alignment failure) must
*not* be averaged in, or it ghosts. HDR+ solves this in the **frequency domain** with a per-tile,
per-frequency Wiener-style shrinkage. Rawloom implements exactly this.

### 4.1 Why frequency domain

A spatial robust average (reject whole tiles above a threshold) throws away a good tile because of a
few bad pixels. The DFT merge instead decides *per spatial frequency* how much of each alternate to
trust, so a tile that agrees with the reference at low frequencies but disagrees at high frequencies
(slight misalignment) still contributes its low frequencies. This is the key to HDR+'s ghost-free,
detail-preserving merge.

### 4.2 The algorithm (per overlapped tile, **per Bayer plane separately**)

The four Bayer planes (R, Gr, Gb, B) are merged **independently** — each is its own band of tiles
with its own DFT. Operate on overlapping tiles (16×16, 50% overlap) windowed by a **modified
raised-cosine** `w(x) = ½ − ½·cos(2π(x+½)/n)` (two half-overlapped such windows sum to 1, so the
overlap-add normalises itself and there are no block seams). For a reference tile `T₀` and the
aligned alternates `T₁..T_{N-1}` (each sampled at its sub-pixel vector `Uₙ(t)` by bilinear taps):

```
# 1. window + forward DFT of every frame's tile (including the reference)
for n in 0..N-1:  T̂n = DFT(w · Tn)

# 2. per-frequency robust temporal merge — canonical HDR+ form
for each frequency ω:
    merged(ω) = 0
    for n in 0..N-1:                         # n = 0 is the reference (D=0 ⇒ A=0 ⇒ contributes T̂0)
        D = T̂0(ω) - T̂n(ω)
        A = |D|² / (|D|² + c·σ²)             # Wiener shrinkage 0..1
        merged(ω) += (1 - A)·T̂n(ω) + A·T̂0(ω)
    merged(ω) /= N
# When an alternate disagrees beyond noise (|D|²≫σ²) → A→1 → that term falls back to the reference
# (no ghost). When it agrees (|D|²≲σ²) → A→0 → it is averaged in (denoise).

# 3. (optional) spatial Wiener pass: a second shrink with variance σ²/N and a high-frequency
#    shaping f(ω) that raises the effective noise floor at high ω — light residual cleanup.

# 4. inverse DFT, overlap-add into the output plane
out += w · IDFT(merged)
```

- **Noise model `σ²`:** signal-dependent shot+read, `σ²(x) = λ_s·x + λ_r` (§NoiseModel). For
  efficiency it is taken **constant within a tile**, evaluated at the tile's **RMS** level `ρ(T)`
  (RMS, not mean — higher-contrast tiles get more aggressive denoising). `λ_s,λ_r` scale with gain:
  `σ²(α·x)=α²σ²(x)`, `α = ISO/100`; from the DNG `NoiseProfile` when present. (Hasinoff 2016.)
- **Robustness `c = k·τ`:** raising `c` merges more aggressively (more denoise, more ghost risk);
  lowering it is conservative (`τ→0` keeps the reference, `τ→∞` is a naive average). Night merges
  harder.
- The reference's own tile is *never* shrunk toward anything — it anchors geometry and guarantees the
  output is at least as good as a single frame.

> **[Indigo] "Long Exposure" mode** is the revealing contrast: Adobe says it "replaces our robust
> merging method … with just adding the frames together." So the *default* path is exactly the robust
> Wiener merge above; Long Exposure swaps step 2 for a plain sum to get motion-blur light trails.

Output: one merged raw Bayer image, same resolution as the reference, with noise reduced by up to
√N and highlights intact. → `Pipeline/Merge/`, kernels `forward_dft`, `merge_tiles`,
`inverse_dft_accumulate` in `Merge.metal`.

### 4.3 Spatial fallback

For very low frame counts or when the DFT path is disabled, Rawloom also ships a **spatial robust
merge**: per pixel, average alternates whose aligned value is within `k·σ` of the reference, else use
the reference. Cheaper, slightly softer; used as a fast preview.

---

## 5. Super-resolution (drizzle) — *optional*, exploits hand tremor

Indigo, like Super-Res Zoom, can skip demosaic and instead reconstruct a **full-color, higher-res**
image directly from the burst, because the *sub-pixel* hand motion between frames means the color
filter array samples the scene at many different sub-pixel positions. (Wronski 2019.)

Logic:

1. Work at an upsampled grid (typically **1.5×–3×** input Bayer resolution).
2. Each raw sample of each frame is a *known color* (its CFA color) at a *known sub-pixel position*
   (its alignment vector). **[Indigo]** "counts on your natural handshake" — tremor of ≈**0.89 px
   (1σ)** scatters samples ~uniformly in sub-pixel space (equidistribution), giving the aliased views
   SR needs (no intentional shaking — that just blurs).
3. Splat each sample onto the high-res grid as an **anisotropic Gaussian RBF** `w = exp(−½·dᵀΩ⁻¹d)`.
   The covariance `Ω = k₁·e₁e₁ᵀ + k₂·e₂e₂ᵀ` comes from the **local structure tensor**'s eigenvectors
   `e₁,e₂` / eigenvalues, so kernels **stretch along edges and shrink across them** (paper:
   k_stretch≈4, k_shrink≈2; very sharp regions k_detail≈0.05 px). Kills zipper/maze artifacts and
   tolerates small misalignment.
4. Per output pixel, per channel: `ŝ = Σ(c·w·R) / Σ(w·R)`, where `R` is a **robustness mask**
   `R = s·exp(−d²/σ²) − t` from the local colour difference `d` vs local std-dev `σ` (a noise model
   corrects `σ` in flat dark areas; a motion prior from the alignment field sets `s`). Differences
   ≲σ → merge (denoise / the aliasing that *is* the SR signal); larger → reject (motion). Degrades
   gracefully to single-frame upsampling where alignment fails. Same anti-ghost role as §4.2.
5. The result is a full-RGB image — **no separate demosaic** (§6.4 is skipped) — at the upsampled
   resolution, with aliasing suppressed. **[Indigo]** triggers SR at ≥2× on the main lens (≥10× on
   the tele), and insists "the extra detail is real, not hallucinated."

When super-res is **off** (the default Photo path), we instead demosaic the merged Bayer in §6.1.
→ `Pipeline/SuperResolution/Drizzle.swift`, kernel `drizzle_splat` in `SuperResolution.metal`.

---

## 6. Finishing — merged raw → display image

The merged raw is clean and linear but looks flat and green. The finishing pipeline is a fixed,
ordered ISP. **Order matters**; this is the Indigo/HDR+ order:

1. **Black-level / white-level** — already normalized to `[0,1]` at ingest (§0).
2. **Lens shading correction** — multiply by the inverse of the per-channel vignetting/flat-field
   gain map (from camera metadata; radial fallback). Do this *before* white balance so color shading
   is corrected too. **[Indigo]** stresses *lens-aware* corrections tuned per iPhone module.
3. **White balance** — multiply R and B by the AWB gains (G = 1). Gains come from the camera's AWB,
   or Rawloom's gray-world/white-patch estimate as fallback. **[Indigo]** uses a learned/AI AWB
   ("Adaptive Color Profile"); Night Sight uses a low-light-trained learned AWB. We expose a hook.
4. **Demosaic** — if not super-resolving: a high-quality gradient-corrected interpolation
   (Malvar–He–Cutler 5×5) to go Bayer → full RGB. (On the super-res path, §5 already produced RGB and
   this step is skipped entirely.)
5. **Chroma denoise** — convert to a luma/chroma space (YUV); a sparse non-linear 3×3 kernel, **two
   passes**, blurs the chroma channels to remove red/green shadow mottle while keeping luma detail.
   Done **before** the CCM (HDR+ order) so the matrix doesn't amplify colour noise. The temporal
   merge already killed most *luma* noise — **[Indigo]** applies *less* spatial denoise than typical.
6. **Color space transform (CCM)** — apply the 3×3 **color correction matrix** (camera-native → linear
   sRGB / Rec.709 primaries). From DNG `ColorMatrix`/`ForwardMatrix` metadata.
7. **Local tone mapping** — the step that makes shadows visible without flattening the image. Rawloom
   implements **local Laplacian filtering** (Paris et al. 2011) as the primary LTM — build a Laplacian
   pyramid, remap each coefficient with a per-level detail/edge function so local contrast is
   preserved while global range is compressed — with HDR+'s **exposure-fusion** variant (synthesise a
   short+long exposure from the single merged image, Laplacian-pyramid fuse) available as an
   alternative. Recovers HDR appearance from the single merged exposure; re-applies the memorised
   under-exposure gain (§1.2).
8. **Dehaze + global tone curve** — a global curve that pushes low values lower (veiling-glare/haze
   mitigation) then the overall S-curve / "Indigo look": gentle highlight rolloff, lifted-but-
   controlled shadows, slightly reduced global contrast for the natural full-frame-camera feel.
9. **Chromatic-aberration & sharpening** — fix colour fringing on high-contrast edges; then unsharp
   mask as a **sum of Gaussians** (σ∈{1,2,4}, α∈{1,0.5,0.5}) on luma only, noise-aware (less in
   flat/dark regions). **[Indigo]** deliberately keeps sharpening *mild* — avoids the "phone" look.
10. **Hue/sat & finishing color** — small saturation lift, memory-color tweaks (cyans/purples→blue,
    sky/foliage), then clamp. **[Indigo]** "mild saturation boost".
11. **Output transfer function** — blue-noise dither, then encode with the **sRGB gamma** for JPEG;
    keep the *pre-tone-map linear* merged data for the DNG (see §7).

→ `Pipeline/Finishing/`, kernels in `Demosaic.metal`, `Color.metal`, `ToneMap.metal`,
`Finishing.metal`.

---

## 7. Output — computed-raw DNG + display JPEG

Indigo writes **two** files:

- **JPEG** — the fully finished §6 image. **[Indigo]** it is a **hybrid SDR + HDR** file: an SDR base
  image plus a **gain map** that reconstructs the HDR rendition on capable displays ("an HDR camera
  from the get-go, with graceful fallback to SDR"). 8-bit base + gain map.
- **Computed-raw DNG** — the *merged, low-noise raw* (after §4, before the §6 tone/color render).
  **[Indigo]** it is stored **before demosaicking — one colour per pixel, 16 bits** — and is linear
  (proportional to scene brightness, not tone-mapped) with greater dynamic range than the JPEG. Being
  single-channel it is ~30% smaller than Apple ProRAW (which is demosaicked/3-channel). It carries
  the original CFA, black/white levels, `AsShotNeutral`, `NoiseProfile` and colour matrices.

So the DNG is a *better negative* — already aligned-and-merged across 8–32 frames (noise reduction +
HDR headroom that "most raw images do not have"), but it leaves tone/colour rendering to the editor.
→ `Output/DNGWriter.swift`, `Output/JPEGEncoder.swift`, `Output/GainMap.swift`.

---

## 8. End-to-end summary

```
capture (ZSL ring, N underexposed raw frames, same exposure)
   └─► select reference (sharpest of first 3)
         └─► for each alternate: build green pyramid → coarse-to-fine block-match → subpixel vectors
               └─► merge: overlapped tiles → DFT → per-frequency Wiener shrink toward reference
                          → IDFT → overlap-add  ➜  MERGED RAW  ──────────────► DNG (16-bit linear)
                     └─► finishing: shading → WB → demosaic → CCM → chroma-denoise
                                    → local-Laplacian tone map → global curve → sharpen → sRGB
                                                                              ➜ JPEG (8-bit sRGB)
   (optional: replace demosaic with drizzle super-resolution using sub-pixel hand tremor)
```

### Parameter quick-reference (Rawloom defaults)

| Symbol | Meaning | Photo | Night |
|--------|---------|-------|-------|
| `N` | burst length | 8 (up to 32) | up to 32 |
| ZSL | zero shutter lag | **yes** | no (capture after press) |
| exposure | per-frame, highlight-protected | adaptive/short | motion-metered, up to ~1 s |
| pyramid levels | alignment hierarchy | 4 (downsample 2/4/4) | 4 |
| tile | coarse → finest | 8 → 16 px | 8 → 16 px |
| overlap | merge tile stride | 50% | 50% |
| `R` | per-level search radius | 4 px | 4 px |
| distance | block-match cost | L2 coarse / L1 finest | L2 / L1 |
| `c` | merge robustness | 8 | 12 (harder) |
| `σ²(x)=λ_s·x+λ_r` | noise model (at tile RMS) | per-ISO | per-ISO |
| super-res | drizzle upsample | off (×1) | optional 1.5–3× |
| tone map | local contrast | local Laplacian | local Laplacian |
| output | files | 16-bit DNG + SDR/HDR JPEG | DNG + JPEG |

---

## References

1. S. Hasinoff, D. Sharlet, R. Geiss, A. Adams, J. Barron, F. Kainz, J. Chen, M. Levoy.
   *Burst photography for high dynamic range and low-light imaging on mobile cameras.* SIGGRAPH
   Asia 2016. (HDR+: align + frequency-domain robust merge + finishing.)
2. B. Wronski, I. Garcia-Dorado, M. Ernst, D. Kelly, M. Krainin, C.-K. Liang, M. Levoy, P. Milanfar.
   *Handheld Multi-Frame Super-Resolution.* SIGGRAPH 2019. (Super-Res Zoom / drizzle.)
3. O. Liba, K. Murthy, Y.-T. Tsai, T. Brooks, T. Xue, N. Karnad, Q. He, J. Barron, D. Sharlet,
   R. Geiss, S. Hasinoff, Y. Pritch, M. Levoy. *Handheld Mobile Photography in Very Low Light.*
   SIGGRAPH Asia 2019. (Night Sight: motion metering, learned AWB.)
4. S. Paris, S. Hasinoff, J. Kautz. *Local Laplacian Filters: Edge-aware Image Processing with a
   Laplacian Pyramid.* SIGGRAPH 2011. (Local tone mapping.)
5. M. Levoy, F. Kainz. *Project Indigo.* Adobe Research, 2025.
   <https://research.adobe.com/articles/indigo/indigo.html> (Product write-up: 32 frames, always-on
   under-exposure, ZSL, super-resolution, computed-raw 16-bit DNG, SDR+HDR JPEG.) See also the
   Indigo FAQ: <https://helpx.adobe.com/project-indigo/get-started/faq.html>.
6. H. Malvar, L. He, R. Cutler. *High-quality linear interpolation for demosaicing of Bayer-patterned
   color images.* ICASSP 2004. (Demosaic.)
7. A. Monod, J. Delon, T. Veit. *An Analysis and Implementation of the HDR+ Burst Denoising Method.*
   IPOL 2021. <https://www.ipol.im/pub/art/2021/336/> — the best public source for HDR+'s exact tile
   sizes, pyramid factors, and Wiener-merge math; Rawloom's alignment/merge constants follow it.
