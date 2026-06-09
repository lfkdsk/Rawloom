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
    /// - Returns: a single-channel 8-bit gain map (`width*height` bytes, row-major) and its metadata.
    public static func compute(
        sdrSRGB: [Float], hdrLinear: [Float], width: Int, height: Int,
        maxStops: Float = 6, offset: Float = 1.0 / 64
    ) -> (pixels: [UInt8], metadata: GainMapMetadata) {
        precondition(sdrSRGB.count == width * height * 4 && hdrLinear.count == width * height * 4)
        let n = width * height
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

        var pixels = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let m = (recovery[i] - gmin) / range
            pixels[i] = UInt8((min(max(m, 0), 1) * 255).rounded())
        }

        let meta = GainMapMetadata(
            gainMapMin: gmin, gainMapMax: gmax, gamma: 1,
            offsetSDR: offset, offsetHDR: offset,
            hdrCapacityMin: 0, hdrCapacityMax: max(gmax, 0)
        )
        return (pixels, meta)
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
