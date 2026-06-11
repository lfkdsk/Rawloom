import Foundation
import Metal
import simd

/// Mutable scratch threaded down through the pipeline (Merger / Finisher) when stage capture is on.
///
/// It holds *references* to the intermediate GPU textures so they survive the ping-pong reuse inside
/// the merge loop — capturing the texture object (not the variable) pins the exact buffer we want.
/// Nothing here runs unless `IndigoPipeline.process(captureStages:)` is `true`, so the normal capture
/// path pays nothing. `StageRenderer` turns the collected textures into `StagePreview`s *after* the
/// command buffer has completed.
///
/// Public only so it can appear in `Merger`/`Finisher`'s public signatures; its members are internal
/// and it is constructed solely by `IndigoPipeline`. Callers never touch it directly.
public final class StageCollector {
    init() {}
    var frameCount = 0
    var referenceIndex = 0
    var exposureGain: Float = 1
    var config: PipelineConfiguration?

    // Captured during encoding, read back after commit/wait.
    var referencePlanes: MTLTexture?   // noisy reference, half-res 4-plane (align base)
    var mergedPlanes: MTLTexture?      // clean merged, half-res 4-plane
    var weight: MTLTexture?            // final merge weight sum (ghost-rejection map)
    var motionField: AlignmentField?   // one representative per-tile field
    var camRGB: MTLTexture?            // demosaiced camera-native RGB (pre-WB)
    var linearRGB: MTLTexture?         // after WB + CCM + exposure
}

/// Turns the captured intermediate textures + raw frames into the ordered list of `StagePreview`s.
/// All downscaling is a CPU box-average to ≤`maxEdge` px — small enough to be cheap, large enough to
/// read well. Linear-light stages get an sRGB OETF so they look right; the raw stages stay grayscale
/// (they *are* uncoloured) and the raw burst is brightened by the memorised gain so it is visible.
enum StageRenderer {
    /// ~full-screen-hero resolution: the inspector/reveal show these edge-to-edge, so 256 looked soft.
    /// Sources ≤ this are copied 1:1 (no softening); half-res plane stages cap at their native half-res.
    static let maxEdge = 1024

    static func render(collector c: StageCollector, frames: [RawFrame],
                       display: MTLTexture, context: MetalContext) -> [StagePreview] {
        var out: [StagePreview] = []
        let gain = c.exposureGain

        // 0. Capture — the underexposed raw burst (grayscale: it is pre-colour).
        let burst = frameThumb(frames[min(c.referenceIndex, frames.count - 1)], gain: gain)
        out.append(StagePreview(
            kind: .capture, title: "Capture",
            detail: "\(c.frameCount) raw frames · underexposed",
            image: burst))

        // 1. Reference — the sharpest frame, chosen as the merge base.
        out.append(StagePreview(
            kind: .reference, title: "Reference",
            detail: "frame \(c.referenceIndex + 1)/\(c.frameCount) · sharpest",
            image: frameThumb(frames[c.referenceIndex], gain: gain)))

        // 2. Align — reference planes with the estimated per-tile motion field on top.
        if let ref = c.referencePlanes {
            var overlay: PreviewOverlay?
            if let f = c.motionField {
                overlay = .motionField(vectors: context.readField(f.texture),
                                       cols: f.tilesX, rows: f.tilesY, tileSize: f.tileSize)
            }
            let detail = c.config.map { "\($0.tileSize)px tiles · ±\($0.searchRadius)px search" }
                ?? "coarse-to-fine tile match"
            out.append(StagePreview(kind: .align, title: "Align", detail: detail,
                                    image: planesThumb(ref, context: context, gain: gain),
                                    overlay: overlay))
        }

        // 3. Merge — the denoised result + the robustness heatmap (where alternates were rejected).
        if let merged = c.mergedPlanes {
            var overlay: PreviewOverlay?
            if let w = c.weight {
                overlay = .heatmap(weightHeatmap(w, context: context),
                                   caption: "warm = rejected (anti-ghost) · cool = merged")
            }
            out.append(StagePreview(
                kind: .merge, title: "Merge",
                detail: "\(max(c.frameCount - 1, 0)) frames merged · robust",
                image: planesThumb(merged, context: context, gain: gain),
                overlay: overlay))
        }

        // 4. Demosaic — Bayer → camera-native RGB (green-cast, pre white balance).
        if let cam = c.camRGB {
            out.append(StagePreview(kind: .demosaic, title: "Demosaic", detail: "Bayer → RGB",
                                    image: rgbaThumb(cam, context: context, gain: gain, gamma: true)))
        }
        // 5. Colour — white balance · CCM · exposure already applied (linear, corrected colour).
        if let lin = c.linearRGB {
            out.append(StagePreview(kind: .color, title: "Colour",
                                    detail: String(format: "white balance · CCM · %.1f× gain", gain),
                                    image: rgbaThumb(lin, context: context, gain: 1, gamma: true)))
        }
        // 6. Result — the finished display image (already sRGB-encoded).
        out.append(StagePreview(kind: .result, title: "Result", detail: "tone map · sRGB",
                                image: rgbaThumb(display, context: context, gain: 1, gamma: false)))
        return out
    }

    // MARK: - Thumbnails

    /// Box-average a raw mosaic to a grayscale thumbnail (mixing the 2×2 Bayer sites desaturates to a
    /// luma-like value — apt, since this is pre-demosaic raw). Brightened by the memorised gain.
    private static func frameThumb(_ f: RawFrame, gain: Float) -> PreviewImage {
        let scale = downscale(f.width, f.height)
        let w = max(1, f.width / scale), h = max(1, f.height / scale)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for oy in 0..<h {
            for ox in 0..<w {
                var acc = 0.0, n = 0
                let x0 = ox * scale, y0 = oy * scale
                var yy = y0
                while yy < min(y0 + scale, f.height) {
                    var xx = x0
                    while xx < min(x0 + scale, f.width) {
                        acc += Double(f.normalized(x: xx, y: yy)); n += 1; xx += 1
                    }
                    yy += 1
                }
                let v = u8(srgb(clamp01(Float(acc / Double(max(n, 1))) * gain)))
                let i = (oy * w + ox) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v
            }
        }
        return PreviewImage(width: w, height: h, rgba8: px)
    }

    /// Half-res 4-plane image → fake-colour thumbnail. Planes are positional (RGBA = block 0,0 / 1,0 /
    /// 0,1 / 1,1); for the common RGGB phase that maps to (R, mean-green, B) — a good-enough preview.
    private static func planesThumb(_ tex: MTLTexture, context: MetalContext, gain: Float) -> PreviewImage {
        boxReduce(context.readRGBA(tex), sw: tex.width, sh: tex.height) { c0, c1, c2, c3 in
            (srgb(clamp01(c0 * gain)),
             srgb(clamp01((c1 + c2) * 0.5 * gain)),
             srgb(clamp01(c3 * gain)))
        }
    }

    /// Full-colour RGBA texture → thumbnail, optionally with an sRGB OETF for linear-light sources.
    private static func rgbaThumb(_ tex: MTLTexture, context: MetalContext,
                                  gain: Float, gamma: Bool) -> PreviewImage {
        let encode: (Float) -> Float = gamma ? { srgb(clamp01($0)) } : { clamp01($0) }
        return boxReduce(context.readRGBA(tex), sw: tex.width, sh: tex.height) { r, g, b, _ in
            (encode(r * gain), encode(g * gain), encode(b * gain))
        }
    }

    /// The final merge weight sum → a warm/cool heatmap. weight ∈ [1, N]: low (≈1) means alternates
    /// were rejected (motion / ghost / disagreement) — warm; high means they agreed and were merged
    /// (denoised) — cool. Max-normalised so it always reads well.
    private static func weightHeatmap(_ tex: MTLTexture, context: MetalContext) -> PreviewImage {
        let data = context.readRGBA(tex)
        let sw = tex.width, sh = tex.height
        let scale = downscale(sw, sh)
        let w = max(1, sw / scale), h = max(1, sh / scale)
        var vals = [Float](repeating: 0, count: w * h)
        var maxV: Float = 1e-6
        for oy in 0..<h {
            for ox in 0..<w {
                var acc = 0.0, n = 0
                let x0 = ox * scale, y0 = oy * scale
                var yy = y0
                while yy < min(y0 + scale, sh) {
                    var xx = x0
                    while xx < min(x0 + scale, sw) {
                        let i = (yy * sw + xx) * 4
                        acc += Double((data[i] + data[i + 1] + data[i + 2] + data[i + 3]) * 0.25)
                        n += 1; xx += 1
                    }
                    yy += 1
                }
                let v = Float(acc / Double(max(n, 1)))
                vals[oy * w + ox] = v
                if v > maxV { maxV = v }
            }
        }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for k in 0..<(w * h) {
            let (r, g, b) = heatColor(clamp01(vals[k] / maxV))
            px[k * 4] = u8(r); px[k * 4 + 1] = u8(g); px[k * 4 + 2] = u8(b)
        }
        return PreviewImage(width: w, height: h, rgba8: px)
    }

    // MARK: - Helpers

    /// Box-average an interleaved RGBA float buffer to a thumbnail, mapping each averaged texel → RGB.
    private static func boxReduce(_ data: [Float], sw: Int, sh: Int,
                                  _ map: (Float, Float, Float, Float) -> (Float, Float, Float)) -> PreviewImage {
        let scale = downscale(sw, sh)
        let w = max(1, sw / scale), h = max(1, sh / scale)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for oy in 0..<h {
            for ox in 0..<w {
                var ar = 0.0, ag = 0.0, ab = 0.0, aa = 0.0, n = 0
                let x0 = ox * scale, y0 = oy * scale
                var yy = y0
                while yy < min(y0 + scale, sh) {
                    var xx = x0
                    while xx < min(x0 + scale, sw) {
                        let i = (yy * sw + xx) * 4
                        ar += Double(data[i]); ag += Double(data[i + 1])
                        ab += Double(data[i + 2]); aa += Double(data[i + 3]); n += 1; xx += 1
                    }
                    yy += 1
                }
                let inv = 1.0 / Double(max(n, 1))
                let (r, g, b) = map(Float(ar * inv), Float(ag * inv), Float(ab * inv), Float(aa * inv))
                let i = (oy * w + ox) * 4
                px[i] = u8(r); px[i + 1] = u8(g); px[i + 2] = u8(b)
            }
        }
        return PreviewImage(width: w, height: h, rgba8: px)
    }

    private static func downscale(_ w: Int, _ h: Int) -> Int {
        max(1, (max(w, h) + maxEdge - 1) / maxEdge)
    }

    /// warm (rejected, t→0) → cool (merged, t→1). Colours follow the InkType palette:
    /// terracotta `#C8553D` for rejection, slate blue `#6B8CA3` for merged.
    private static func heatColor(_ t: Float) -> (Float, Float, Float) {
        let warm: (Float, Float, Float) = (0.78, 0.33, 0.24)
        let cool: (Float, Float, Float) = (0.42, 0.55, 0.64)
        return (warm.0 + (cool.0 - warm.0) * t,
                warm.1 + (cool.1 - warm.1) * t,
                warm.2 + (cool.2 - warm.2) * t)
    }

    private static func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }
    private static func u8(_ v: Float) -> UInt8 { UInt8(clamp01(v) * 255 + 0.5) }

    /// sRGB opto-electronic transfer function (linear → display-encoded).
    private static func srgb(_ v: Float) -> Float {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }
}
