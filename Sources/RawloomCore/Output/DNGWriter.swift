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

    /// - Parameters:
    ///   - normalizedBayer: merged linear Bayer in `[0,1]`, row-major (`width*height`).
    ///   - exposureGain: the finishing "memorised gain" (≥1). Recorded as `BaselineExposure` so the
    ///     under-exposed linear raw opens at the intended brightness in an editor. Default 1 (0 EV).
    ///   - frameCount: burst length. The `NoiseProfile` (per-frame model) is scaled by `1/frameCount` to
    ///     reflect the merge's ~1/N variance reduction over static content. Default 1 (no scaling).
    /// - Returns: DNG file bytes.
    public static func write(
        normalizedBayer: [Float],
        width: Int,
        height: Int,
        metadata: RawImageMetadata,
        exposureGain: Float = 1,
        frameCount: Int = 1
    ) -> Data {
        precondition(normalizedBayer.count == width * height)

        // 16-bit linear samples. BlackLevel 0 / WhiteLevel 65535 are *correct* here: the merged raw is
        // already black-subtracted and normalised to [0,1] (the computed-raw is linearised), so codes
        // span the full 0…65535 with no pedestal. The real sensor exposure/ISO go in the EXIF IFD.
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

        // ColorMatrix1 (XYZ→camera): the real sensor matrix carried from the source DNG when available;
        // otherwise a generic XYZ→sRGB so synthetic/test input still yields a valid (if uncalibrated)
        // file. Writing the *real* matrix is what makes the DNG render correctly in external editors.
        let colorMatrix1: [Float] = {
            if let cm = metadata.colorMatrixXYZToCamera, cm.count == 9 { return cm }
            return xyzToSRGB
        }()

        // AsShotNeutral: the true camera neutral when known; else derived from the WB gains.
        let wb = metadata.whiteBalance
        let neutral: [Float] = metadata.asShotNeutral.map { [$0.x, $0.y, $0.z] }
            ?? [1.0 / max(wb.red, 1e-3), 1.0 / max(wb.green, 1e-3), 1.0 / max(wb.blue, 1e-3)]

        // BaselineExposure: the memorised under-exposure gain, in stops.
        let baselineExposure = log2(max(exposureGain, 1e-3))

        // NoiseProfile reflects the *merged* raw: the robust merge cuts variance by ~1/N over static
        // content, so scale the per-frame model down by the burst length (optimistic in motion regions).
        let noiseScale = 1.0 / Double(max(frameCount, 1))

        // --- EXIF sub-IFD: exposure time + ISO ---
        var exif: [TIFFEntry] = [
            .rational(33434, [Float(metadata.exposureDuration)], den: 1_000_000), // ExposureTime (µs prec.)
            .short(34855, [UInt16(min(max(metadata.iso, 1), 65535))]),            // ISOSpeedRatings
        ]
        exif.sort { $0.tag < $1.tag }

        // --- IFD0 ---
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
            .long(34665, 0),                                 // ExifIFD pointer (patched below)
            .short(33421, [2, 2]),                           // CFARepeatPatternDim
            .bytes(33422, cfaBytes),                         // CFAPattern
            .bytes(50706, [1, 4, 0, 0]),                     // DNGVersion
            .bytes(50707, [1, 3, 0, 0]),                     // DNGBackwardVersion
            .ascii(50708, "Rawloom"),                        // UniqueCameraModel
            .bytes(50710, [0, 1, 2]),                        // CFAPlaneColor RGB
            .short(50711, [1]),                              // CFALayout: rectangular
            .short(50714, [0]),                              // BlackLevel (data already black-subtracted)
            .long(50717, 65535),                             // WhiteLevel (data normalised to [0,1])
            .srational(50721, colorMatrix1),                 // ColorMatrix1 (XYZ→camera)
            .rational(50728, neutral),                       // AsShotNeutral
            .srational(50730, [baselineExposure]),           // BaselineExposure (memorised gain, stops)
            .short(50778, [21]),                             // CalibrationIlluminant1: D65
            .double(51041, [Double(metadata.noise.a) * noiseScale,
                            Double(metadata.noise.b) * noiseScale]), // NoiseProfile (var=a·x+b), merged
        ]
        if let fm = metadata.forwardMatrix, fm.count == 9 {
            entries.append(.srational(50964, fm))            // ForwardMatrix1 (camera→XYZ D50)
        }
        entries.sort { $0.tag < $1.tag }

        // --- layout: header(8) | IFD0 | EXIF-IFD | data area | pixel strip ---
        let ifd0Offset = 8
        let ifd0Size = 2 + entries.count * 12 + 4
        let exifOffset = ifd0Offset + ifd0Size
        let exifSize = 2 + exif.count * 12 + 4
        var cursor = exifOffset + exifSize

        // Assign data-area offsets to values that don't fit in 4 bytes — IFD0 first, then EXIF, so the
        // offsets stay monotonically increasing for the single-pass emit below.
        var entryOffsets = [Int](repeating: 0, count: entries.count)
        for i in entries.indices where entries[i].payload.count > 4 {
            entryOffsets[i] = cursor
            cursor += entries[i].payload.count
            if cursor % 2 == 1 { cursor += 1 } // word-align
        }
        var exifOffsets = [Int](repeating: 0, count: exif.count)
        for i in exif.indices where exif[i].payload.count > 4 {
            exifOffsets[i] = cursor
            cursor += exif[i].payload.count
            if cursor % 2 == 1 { cursor += 1 }
        }
        let pixelOffset = cursor

        // Patch the dynamic IFD0 pointers now that the offsets are known.
        if let idx = entries.firstIndex(where: { $0.tag == 273 }) {
            entries[idx] = .long(273, UInt32(pixelOffset))   // StripOffsets → pixel data
        }
        if let idx = entries.firstIndex(where: { $0.tag == 34665 }) {
            entries[idx] = .long(34665, UInt32(exifOffset))  // ExifIFD → sub-IFD
        }

        // --- emit ---
        var out = Data()
        out.append(contentsOf: [0x49, 0x49])           // "II" little-endian
        out.appendLE(UInt16(42))                        // TIFF magic
        out.appendLE(UInt32(ifd0Offset))

        emitIFD(entries, offsets: entryOffsets, nextIFD: 0, into: &out)
        emitIFD(exif, offsets: exifOffsets, nextIFD: 0, into: &out)

        // data area: IFD0 payloads then EXIF payloads, in assigned-offset order.
        for (i, e) in entries.enumerated() where e.payload.count > 4 {
            while out.count < entryOffsets[i] { out.append(0) }
            out.append(contentsOf: e.payload)
        }
        for (i, e) in exif.enumerated() where e.payload.count > 4 {
            while out.count < exifOffsets[i] { out.append(0) }
            out.append(contentsOf: e.payload)
        }
        while out.count < pixelOffset { out.append(0) }
        out.append(contentsOf: pixels)
        return out
    }

    /// Serialise one IFD (entry count, the 12-byte records, then the `nextIFD` link) into `out`. Values
    /// ≤4 bytes are stored inline; larger ones reference their pre-assigned `offsets` in the data area.
    private static func emitIFD(_ entries: [TIFFEntry], offsets: [Int], nextIFD: UInt32, into out: inout Data) {
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
        out.appendLE(nextIFD)
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
    static func write(mergedBayer: MTLTexture, context: MetalContext,
                      metadata: RawImageMetadata, exposureGain: Float = 1, frameCount: Int = 1) -> Data {
        write(normalizedBayer: context.readFloats(mergedBayer),
              width: mergedBayer.width, height: mergedBayer.height,
              metadata: metadata, exposureGain: exposureGain, frameCount: frameCount)
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
    static func double(_ tag: UInt16, _ v: [Double]) -> TIFFEntry {
        var p = [UInt8]()
        for x in v { let bits = x.bitPattern; for i in 0..<8 { p.append(UInt8(truncatingIfNeeded: bits >> (8 * i))) } }
        return TIFFEntry(tag: tag, type: 12, count: UInt32(v.count), payload: p)
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
