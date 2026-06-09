import Foundation

/// Parameters of an ISO 21496-1 / Adobe (Ultra HDR `hdrgm`) gain map. The log2-domain values are
/// scalars applied to every channel — we encode a single-channel **luminance** gain map, so colour is
/// carried by the SDR base and the map only re-scales brightness.
public struct GainMapMetadata: Sendable, Equatable {
    /// log2 gain that the stored value 0 de-quantises to.
    public var gainMapMin: Float
    /// log2 gain that the stored value 1 de-quantises to.
    public var gainMapMax: Float
    /// Encoding gamma applied to the normalised stored value (1 = linear).
    public var gamma: Float
    /// Small offsets added before the ratio, so deep shadows don't blow the log up.
    public var offsetSDR: Float
    public var offsetHDR: Float
    /// log2 display headroom at/below which only the SDR base shows, and at which the full gain applies.
    public var hdrCapacityMin: Float
    public var hdrCapacityMax: Float
}

/// A computed Ultra HDR gain map: the single-channel 8-bit image, its dimensions, and the metadata
/// needed to assemble the file. Built in the pipeline so the full-res HDR float texture need not travel
/// downstream.
public struct GainMapData: Sendable {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int
    public let metadata: GainMapMetadata
}

/// Computes a single-channel HDR gain map from an SDR (sRGB-encoded) and an HDR (linear) rendition of
/// the same scene — the basis of the portable Ultra HDR / ISO 21496-1 JPEG (`docs/PIPELINE.md` §7).
///
/// Per pixel it stores the log2 luminance ratio `recovery = log2((HDR+offset)/(SDR+offset))`, clamped
/// to `[0, maxStops]` and normalised over the image's `[gainMapMin, gainMapMax]`. A decoder rebuilds
/// `HDR = (SDR + offsetSDR)·2^recovery − offsetHDR`, where `recovery = min + storedᵞ·(max − min)`.
public enum GainMap {

    /// - Parameters:
    ///   - sdrSRGB: interleaved RGBA floats, sRGB-encoded `[0,1]` (the finished display image).
    ///   - hdrLinear: interleaved RGBA floats, **linear** light (the pre-tone-map rendition; may exceed 1).
    ///   - downsample: integer factor by which the gain map is smaller than the base. Ultra HDR allows a
    ///     sub-resolution map (decoders upsample it), which shrinks the file at negligible cost. `1` =
    ///     full resolution. `min`/`max` are always measured at full resolution so the range is exact.
    /// - Returns: the single-channel 8-bit gain map (row-major) with its own dimensions, and metadata.
    public static func compute(
        sdrSRGB: [Float], hdrLinear: [Float], width: Int, height: Int,
        downsample: Int = 1, maxStops: Float = 6, offset: Float = 1.0 / 64
    ) -> (pixels: [UInt8], width: Int, height: Int, metadata: GainMapMetadata) {
        precondition(sdrSRGB.count == width * height * 4 && hdrLinear.count == width * height * 4)
        let n = width * height

        // 1. Per-pixel log2 recovery at full resolution, tracking the exact range.
        var recovery = [Float](repeating: 0, count: n)
        var gmin = Float.greatestFiniteMagnitude
        var gmax = -Float.greatestFiniteMagnitude
        for i in 0..<n {
            let s = i * 4
            let sY = luminance(srgbDecode(sdrSRGB[s]), srgbDecode(sdrSRGB[s + 1]), srgbDecode(sdrSRGB[s + 2]))
            let hY = luminance(hdrLinear[s], hdrLinear[s + 1], hdrLinear[s + 2])
            let r = min(max(log2((max(hY, 0) + offset) / (max(sY, 0) + offset)), 0), maxStops)
            recovery[i] = r
            gmin = min(gmin, r)
            gmax = max(gmax, r)
        }
        if !(gmax > gmin) { gmax = gmin + 1e-4 }   // guard a degenerate (flat) range
        let range = gmax - gmin

        // 2. Box-average recovery into the (optionally smaller) gain-map grid, then quantise.
        let ds = max(1, downsample)
        let gw = max(1, (width + ds - 1) / ds)
        let gh = max(1, (height + ds - 1) / ds)
        var pixels = [UInt8](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                var acc: Float = 0, cnt: Float = 0
                for dy in 0..<ds {
                    let y = gy * ds + dy
                    if y >= height { break }
                    for dx in 0..<ds {
                        let x = gx * ds + dx
                        if x >= width { break }
                        acc += recovery[y * width + x]
                        cnt += 1
                    }
                }
                let m = (acc / max(cnt, 1) - gmin) / range
                pixels[gy * gw + gx] = UInt8((min(max(m, 0), 1) * 255).rounded())
            }
        }

        let meta = GainMapMetadata(
            gainMapMin: gmin, gainMapMax: gmax, gamma: 1,
            offsetSDR: offset, offsetHDR: offset,
            hdrCapacityMin: 0, hdrCapacityMax: max(gmax, 0)
        )
        return (pixels, gw, gh, meta)
    }

    /// Convenience around ``compute`` that returns a ``GainMapData``.
    public static func data(
        sdrSRGB: [Float], hdrLinear: [Float], width: Int, height: Int,
        downsample: Int = 2, maxStops: Float = 6, offset: Float = 1.0 / 64
    ) -> GainMapData {
        let r = compute(sdrSRGB: sdrSRGB, hdrLinear: hdrLinear, width: width, height: height,
                        downsample: downsample, maxStops: maxStops, offset: offset)
        return GainMapData(pixels: r.pixels, width: r.width, height: r.height, metadata: r.metadata)
    }

    /// Reconstruct the HDR luminance multiplier a decoder would apply, for a stored byte. Used by tests
    /// to verify the round-trip; mirrors the Ultra HDR decode (`gamma`, `min`/`max`).
    public static func decodeRecovery(_ byte: UInt8, _ m: GainMapMetadata) -> Float {
        let stored = pow(Float(byte) / 255, m.gamma)
        return m.gainMapMin + stored * (m.gainMapMax - m.gainMapMin)
    }

    @inline(__always) static func srgbDecode(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    @inline(__always) static func luminance(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
