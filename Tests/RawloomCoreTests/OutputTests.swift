import XCTest
import simd
@testable import RawloomCore

/// Pure-CPU tests for the DNG/JPEG writers — run on host and simulator alike.
final class OutputTests: XCTestCase {

    func testDNGStructureAndTags() {
        let w = 8, h = 4
        let meta = RawImageMetadata(
            cfa: .rggb, blackLevel: SIMD4(repeating: 0), whiteLevel: 65535,
            iso: 100, exposureDuration: 0.01, timestamp: 0,
            whiteBalance: WhiteBalanceGains(red: 2.0, green: 1, blue: 1.5)
        )
        let bayer = [Float](repeating: 0.5, count: w * h)
        let dng = DNGWriter.write(normalizedBayer: bayer, width: w, height: h, metadata: meta)

        // TIFF header.
        XCTAssertEqual(Array(dng[0..<2]), [0x49, 0x49], "little-endian TIFF")
        XCTAssertEqual(u16(dng, 2), 42, "TIFF magic")
        let ifd = u32(dng, 4)
        XCTAssertEqual(ifd, 8)

        // Walk the IFD into a tag → inline-value map.
        let count = u16(dng, ifd)
        var values: [Int: (type: Int, count: Int, valueOffset: Int)] = [:]
        for i in 0..<count {
            let e = ifd + 2 + i * 12
            values[u16(dng, e)] = (u16(dng, e + 2), u32(dng, e + 4), e + 8)
        }

        XCTAssertEqual(u32(dng, values[256]!.valueOffset), w)       // ImageWidth
        XCTAssertEqual(u32(dng, values[257]!.valueOffset), h)       // ImageLength
        XCTAssertEqual(u16(dng, values[258]!.valueOffset), 16)      // BitsPerSample
        XCTAssertEqual(u16(dng, values[262]!.valueOffset), 32803)   // CFA photometric
        XCTAssertEqual(u32(dng, values[50717]!.valueOffset), 65535) // WhiteLevel

        // CFAPattern (RGGB = 0,1,1,2) stored inline as 4 bytes.
        let cfaOff = values[33422]!.valueOffset
        XCTAssertEqual(Array(dng[cfaOff..<cfaOff + 4]), [0, 1, 1, 2])

        // Pixel data present at StripOffsets, length width*height*2.
        let strip = u32(dng, values[273]!.valueOffset)
        XCTAssertEqual(u32(dng, values[279]!.valueOffset), w * h * 2) // StripByteCounts
        XCTAssertGreaterThanOrEqual(dng.count, strip + w * h * 2)
        // 0.5 → code 32768 = 0x8000, little-endian bytes [0x00, 0x80].
        XCTAssertEqual(dng[strip], 0x00)
        XCTAssertEqual(dng[strip + 1], 0x80)
    }

    /// When the source carries real sensor colour tags + noise, the DNG must record them verbatim
    /// (so external editors render correctly), plus BaselineExposure and an EXIF sub-IFD.
    func testDNGFaithfulColorExifAndNoiseTags() {
        let w = 8, h = 4
        let cm: [Float] = [1.0, 0.1, -0.2, -0.3, 1.2, 0.05, 0.02, -0.1, 1.4]   // XYZ→camera
        let fm: [Float] = [0.6, 0.2, 0.1, 0.3, 0.7, 0.0, 0.0, 0.1, 0.8]        // camera→XYZ D50
        let neutral = SIMD3<Float>(0.52, 1.0, 0.71)
        let noise = NoiseModel(a: 3.0e-5, b: 8.0e-7)
        let meta = RawImageMetadata(
            cfa: .rggb, blackLevel: SIMD4(repeating: 0), whiteLevel: 65535,
            iso: 1600, exposureDuration: 1.0 / 120, timestamp: 0,
            whiteBalance: WhiteBalanceGains(red: 1.9, green: 1, blue: 1.4),
            colorMatrixXYZToCamera: cm, forwardMatrix: fm, asShotNeutral: neutral,
            noise: noise
        )
        let bayer = [Float](repeating: 0.25, count: w * h)
        // exposureGain 4 ⇒ BaselineExposure log2(4) = 2 stops.
        let dng = DNGWriter.write(normalizedBayer: bayer, width: w, height: h, metadata: meta, exposureGain: 4.0)

        let ifd0 = readIFD(dng, at: u32(dng, 4))

        // ColorMatrix1 (50721, SRATIONAL ×9) — the real sensor matrix, not the generic fallback.
        let cm1 = srationals(dng, ifd0[50721]!)
        XCTAssertEqual(cm1.count, 9)
        for (got, want) in zip(cm1, cm.map(Double.init)) { XCTAssertEqual(got, want, accuracy: 2e-4) }

        // ForwardMatrix1 (50964) present and equal.
        XCTAssertNotNil(ifd0[50964])
        for (got, want) in zip(srationals(dng, ifd0[50964]!), fm.map(Double.init)) {
            XCTAssertEqual(got, want, accuracy: 2e-4)
        }

        // AsShotNeutral (50728, RATIONAL ×3) == the provided camera neutral.
        let asn = rationals(dng, ifd0[50728]!)
        XCTAssertEqual(asn.count, 3)
        XCTAssertEqual(asn[0], Double(neutral.x), accuracy: 2e-4)
        XCTAssertEqual(asn[1], Double(neutral.y), accuracy: 2e-4)
        XCTAssertEqual(asn[2], Double(neutral.z), accuracy: 2e-4)

        // BaselineExposure (50730, SRATIONAL) == log2(4) = 2.
        XCTAssertEqual(srationals(dng, ifd0[50730]!).first ?? .nan, 2.0, accuracy: 1e-3)

        // NoiseProfile (51041, DOUBLE ×2) == [a, b] (round-trips exactly).
        let np = doubles(dng, ifd0[51041]!)
        XCTAssertEqual(np.count, 2)
        XCTAssertEqual(np[0], Double(noise.a), accuracy: 1e-12)
        XCTAssertEqual(np[1], Double(noise.b), accuracy: 1e-12)

        // EXIF sub-IFD (34665) reachable, carrying ISO + exposure time.
        let exif = readIFD(dng, at: u32(dng, ifd0[34665]!.valueOffset))
        XCTAssertEqual(u16(dng, exif[34855]!.valueOffset), 1600)                  // ISOSpeedRatings (inline)
        XCTAssertEqual(rationals(dng, exif[33434]!).first ?? .nan, 1.0 / 120, accuracy: 1e-4) // ExposureTime
    }

    /// NoiseProfile must scale down by 1/frameCount to reflect the merge's variance reduction.
    func testDNGNoiseProfileScalesWithFrameCount() {
        let w = 4, h = 4
        let noise = NoiseModel(a: 3.0e-5, b: 8.0e-7)
        let meta = RawImageMetadata(
            cfa: .rggb, blackLevel: SIMD4(repeating: 0), whiteLevel: 65535,
            iso: 100, exposureDuration: 0.01, timestamp: 0, noise: noise
        )
        let bayer = [Float](repeating: 0.5, count: w * h)
        let dng = DNGWriter.write(normalizedBayer: bayer, width: w, height: h, metadata: meta, frameCount: 8)
        let np = doubles(dng, readIFD(dng, at: u32(dng, 4))[51041]!)
        XCTAssertEqual(np[0], Double(noise.a) / 8, accuracy: 1e-12)
        XCTAssertEqual(np[1], Double(noise.b) / 8, accuracy: 1e-12)
    }

    func testJPEGEncodes() {
        let w = 16, h = 16
        var rgba = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            rgba[i] = Float(x) / Float(w); rgba[i + 1] = Float(y) / Float(h); rgba[i + 2] = 0.5; rgba[i + 3] = 1
        } }
        let data = JPEGEncoder.encode(rgba: rgba, width: w, height: h, quality: 0.9)
        XCTAssertNotNil(data)
        // JPEG SOI marker.
        XCTAssertEqual(Array(data!.prefix(2)), [0xFF, 0xD8])
        XCTAssertGreaterThan(data!.count, 100)
    }

    // little-endian readers
    private func u16(_ d: Data, _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) }
    private func u32(_ d: Data, _ o: Int) -> Int {
        Int(d[o]) | (Int(d[o + 1]) << 8) | (Int(d[o + 2]) << 16) | (Int(d[o + 3]) << 24)
    }

    // Minimal TIFF helpers for the faithful-tag test.
    private typealias Entry = (type: Int, count: Int, valueOffset: Int)

    private func readIFD(_ d: Data, at off: Int) -> [Int: Entry] {
        var m = [Int: Entry]()
        for i in 0..<u16(d, off) {
            let e = off + 2 + i * 12
            m[u16(d, e)] = (u16(d, e + 2), u32(d, e + 4), e + 8)
        }
        return m
    }

    /// Offset of an entry's value bytes: inline (≤4 bytes) or pointed-to in the data area.
    private func dataOffset(_ d: Data, _ e: Entry) -> Int {
        let sizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]
        return (sizes[e.type] ?? 1) * e.count <= 4 ? e.valueOffset : u32(d, e.valueOffset)
    }

    private func rationals(_ d: Data, _ e: Entry) -> [Double] {  // type 5 (unsigned)
        let base = dataOffset(d, e)
        return (0..<e.count).map { i in
            let den = u32(d, base + i * 8 + 4)
            return den != 0 ? Double(u32(d, base + i * 8)) / Double(den) : 0
        }
    }

    private func srationals(_ d: Data, _ e: Entry) -> [Double] {  // type 10 (signed)
        let base = dataOffset(d, e)
        return (0..<e.count).map { i in
            let num = Int32(bitPattern: UInt32(u32(d, base + i * 8)))
            let den = Int32(bitPattern: UInt32(u32(d, base + i * 8 + 4)))
            return den != 0 ? Double(num) / Double(den) : 0
        }
    }

    private func doubles(_ d: Data, _ e: Entry) -> [Double] {  // type 12
        let base = dataOffset(d, e)
        return (0..<e.count).map { i in
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(d[base + i * 8 + k]) << (8 * k) }
            return Double(bitPattern: bits)
        }
    }
}
