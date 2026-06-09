import Foundation
#if canImport(Metal)
import Metal
#endif

/// Writes the merged, low-noise raw as a **computed-raw DNG** — a single-channel, 16-bit, *linear*
/// CFA image (one colour per pixel), exactly Indigo's DNG concept (`docs/PIPELINE.md` §7): a "better
/// negative" already aligned-and-merged across the burst, leaving tone/colour to the editor.
///
/// This hand-builds a minimal but valid TIFF/DNG container (little-endian, single IFD, uncompressed).
public enum DNGWriter {

    /// - Parameter normalizedBayer: merged linear Bayer in `[0,1]`, row-major (`width*height`).
    /// - Returns: DNG file bytes.
    public static func write(
        normalizedBayer: [Float],
        width: Int,
        height: Int,
        metadata: RawImageMetadata
    ) -> Data {
        precondition(normalizedBayer.count == width * height)

        // 16-bit linear samples (BlackLevel 0, WhiteLevel 65535).
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 2)
        for v in normalizedBayer {
            let code = UInt16(min(max(v, 0), 1) * 65535 + 0.5)
            pixels.append(UInt8(code & 0xFF))
            pixels.append(UInt8(code >> 8))
        }

        // CFA pattern bytes, row-major (0=R,1=G,2=B).
        let cc = metadata.cfa.cellColors
        let cfaBytes: [UInt8] = [UInt8(cc[0]), UInt8(cc[1]), UInt8(cc[2]), UInt8(cc[3])]

        // ColorMatrix1 (XYZ D65 → camera ≈ sRGB) and AsShotNeutral from the WB gains.
        let colorMatrix = xyzToSRGB
        let wb = metadata.whiteBalance
        let neutral: [Float] = [1.0 / max(wb.red, 1e-3), 1.0 / max(wb.green, 1e-3), 1.0 / max(wb.blue, 1e-3)]

        var entries: [TIFFEntry] = [
            .long(254, 0),                                   // NewSubfileType
            .long(256, UInt32(width)),                       // ImageWidth
            .long(257, UInt32(height)),                      // ImageLength
            .short(258, [16]),                               // BitsPerSample
            .short(259, [1]),                                // Compression: none
            .short(262, [32803]),                            // PhotometricInterpretation: CFA
            .ascii(271, "Rawloom"),                          // Make
            .ascii(272, "Rawloom Camera"),                   // Model
            .long(273, 0),                                   // StripOffsets (patched below)
            .short(274, [1]),                                // Orientation
            .short(277, [1]),                                // SamplesPerPixel
            .long(278, UInt32(height)),                      // RowsPerStrip
            .long(279, UInt32(width * height * 2)),          // StripByteCounts
            .short(284, [1]),                                // PlanarConfiguration
            .short(33421, [2, 2]),                           // CFARepeatPatternDim
            .bytes(33422, cfaBytes),                         // CFAPattern
            .bytes(50706, [1, 4, 0, 0]),                     // DNGVersion
            .bytes(50707, [1, 3, 0, 0]),                     // DNGBackwardVersion
            .ascii(50708, "Rawloom"),                        // UniqueCameraModel
            .bytes(50710, [0, 1, 2]),                        // CFAPlaneColor RGB
            .short(50711, [1]),                              // CFALayout: rectangular
            .short(50714, [0]),                              // BlackLevel
            .long(50717, 65535),                             // WhiteLevel
            .srational(50721, colorMatrix),                  // ColorMatrix1
            .rational(50728, neutral),                       // AsShotNeutral
            .short(50778, [21]),                             // CalibrationIlluminant1: D65
        ]
        entries.sort { $0.tag < $1.tag }

        // --- layout: header(8) | IFD | data area | pixel strip ---
        let ifdOffset = 8
        let ifdSize = 2 + entries.count * 12 + 4
        var cursor = ifdOffset + ifdSize

        // Assign data-area offsets to entries whose value doesn't fit in 4 bytes.
        var offsets = [Int](repeating: 0, count: entries.count)
        for i in entries.indices where entries[i].payload.count > 4 {
            offsets[i] = cursor
            cursor += entries[i].payload.count
            if cursor % 2 == 1 { cursor += 1 } // word-align
        }
        let pixelOffset = cursor

        // Patch StripOffsets (tag 273) value to the pixel-data offset.
        if let idx = entries.firstIndex(where: { $0.tag == 273 }) {
            entries[idx] = .long(273, UInt32(pixelOffset))
        }

        // --- emit ---
        var out = Data()
        out.append(contentsOf: [0x49, 0x49])           // "II" little-endian
        out.appendLE(UInt16(42))                        // TIFF magic
        out.appendLE(UInt32(ifdOffset))

        out.appendLE(UInt16(entries.count))
        for (i, e) in entries.enumerated() {
            out.appendLE(e.tag)
            out.appendLE(e.type)
            out.appendLE(e.count)
            if e.payload.count <= 4 {
                var v = e.payload
                while v.count < 4 { v.append(0) }
                out.append(contentsOf: v)
            } else {
                out.appendLE(UInt32(offsets[i]))
            }
        }
        out.appendLE(UInt32(0)) // next IFD

        // data area
        for (i, e) in entries.enumerated() where e.payload.count > 4 {
            while out.count < offsets[i] { out.append(0) }
            out.append(contentsOf: e.payload)
        }
        while out.count < pixelOffset { out.append(0) }
        out.append(contentsOf: pixels)
        return out
    }

    /// Standard XYZ(D65) → linear sRGB matrix, row-major (used as ColorMatrix1 assuming camera≈sRGB).
    private static let xyzToSRGB: [Float] = [
        3.2406, -1.5372, -0.4986,
        -0.9689, 1.8758, 0.0415,
        0.0557, -0.2040, 1.0570,
    ]
}

#if canImport(Metal)
public extension DNGWriter {
    /// Convenience: read a merged Bayer texture and write its DNG.
    static func write(mergedBayer: MTLTexture, context: MetalContext, metadata: RawImageMetadata) -> Data {
        write(normalizedBayer: context.readFloats(mergedBayer),
              width: mergedBayer.width, height: mergedBayer.height, metadata: metadata)
    }
}
#endif

// MARK: - Minimal TIFF entry encoding

private struct TIFFEntry {
    let tag: UInt16
    let type: UInt16
    let count: UInt32
    /// Serialized value bytes (little-endian). ≤4 ⇒ inline; otherwise stored in the data area.
    let payload: [UInt8]

    static func short(_ tag: UInt16, _ v: [UInt16]) -> TIFFEntry {
        var p = [UInt8](); for x in v { p.appendLE(x) }
        return TIFFEntry(tag: tag, type: 3, count: UInt32(v.count), payload: p)
    }
    static func long(_ tag: UInt16, _ v: UInt32) -> TIFFEntry {
        var p = [UInt8](); p.appendLE(v)
        return TIFFEntry(tag: tag, type: 4, count: 1, payload: p)
    }
    static func bytes(_ tag: UInt16, _ v: [UInt8]) -> TIFFEntry {
        TIFFEntry(tag: tag, type: 1, count: UInt32(v.count), payload: v)
    }
    static func ascii(_ tag: UInt16, _ s: String) -> TIFFEntry {
        var p = Array(s.utf8); p.append(0)
        return TIFFEntry(tag: tag, type: 2, count: UInt32(p.count), payload: p)
    }
    static func rational(_ tag: UInt16, _ v: [Float], den: UInt32 = 10000) -> TIFFEntry {
        var p = [UInt8](); for x in v { p.appendLE(UInt32(max(x, 0) * Float(den) + 0.5)); p.appendLE(den) }
        return TIFFEntry(tag: tag, type: 5, count: UInt32(v.count), payload: p)
    }
    static func srational(_ tag: UInt16, _ v: [Float], den: Int32 = 10000) -> TIFFEntry {
        var p = [UInt8](); for x in v { p.appendLE(Int32((x * Float(den)).rounded())); p.appendLE(den) }
        return TIFFEntry(tag: tag, type: 10, count: UInt32(v.count), payload: p)
    }
}

// MARK: - little-endian append helpers

private extension Array where Element == UInt8 {
    mutating func appendLE(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendLE(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * i)) & 0xFF)) } }
    mutating func appendLE(_ v: Int32) { appendLE(UInt32(bitPattern: v)) }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendLE(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * i)) & 0xFF)) } }
}
