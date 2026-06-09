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
}
