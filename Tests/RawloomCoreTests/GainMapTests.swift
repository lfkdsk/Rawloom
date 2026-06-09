import XCTest
import CoreGraphics
import ImageIO
@testable import RawloomCore

/// Pure-CPU tests for the HDR gain map + Ultra HDR JPEG assembly.
final class GainMapTests: XCTestCase {

    /// Two regions — no gain vs ~2-stop gain — must yield byte 0 / 255 and reconstruct the HDR value.
    func testGainMapRoundTrip() {
        let w = 4, h = 2, n = w * h
        let sdrGray: Float = 0.542     // sRGB-encodes linear 0.25 (gray ⇒ luminance 0.25)
        var sdr = [Float](repeating: 0, count: n * 4)
        var hdr = [Float](repeating: 0, count: n * 4)
        for i in 0..<n {
            let right = (i % w) >= w / 2
            for c in 0..<3 {
                sdr[i * 4 + c] = sdrGray
                hdr[i * 4 + c] = right ? 1.0 : 0.25   // right half is 4× brighter in linear light
            }
            sdr[i * 4 + 3] = 1; hdr[i * 4 + 3] = 1
        }

        let (pixels, meta) = GainMap.compute(sdrSRGB: sdr, hdrLinear: hdr, width: w, height: h)

        XCTAssertEqual(meta.gainMapMin, 0, accuracy: 0.02)
        XCTAssertEqual(meta.gainMapMax, 1.935, accuracy: 0.05)   // log2((1+1/64)/(0.25+1/64))
        for i in 0..<n {
            XCTAssertEqual(pixels[i], (i % w) >= w / 2 ? 255 : 0)
        }

        // Decode a boosted pixel back to HDR luminance: (SDRlin+oSDR)·2^rec − oHDR ≈ 1.0.
        let rec = GainMap.decodeRecovery(255, meta)
        let hdrRec = (Float(0.25) + meta.offsetSDR) * pow(2, rec) - meta.offsetHDR
        XCTAssertEqual(hdrRec, 1.0, accuracy: 0.02)
    }

    /// `insertXMP` must splice a well-formed APP1 XMP segment immediately after SOI.
    func testInsertXMPAfterSOI() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xD9]) // SOI+APP0+EOI
        let out = [UInt8](UltraHDRWriter.insertXMP(into: jpeg, xmp: "<x/>"))
        XCTAssertEqual(Array(out.prefix(2)), [0xFF, 0xD8])      // SOI kept
        XCTAssertEqual(out[2], 0xFF); XCTAssertEqual(out[3], 0xE1) // APP1 right after SOI
        let len = Int(out[4]) << 8 | Int(out[5])
        XCTAssertEqual(len, 2 + "http://ns.adobe.com/xap/1.0/\0".utf8.count + "<x/>".utf8.count)
        let resume = 6 + (len - 2)                              // first original byte after the segment
        XCTAssertEqual(out[resume], 0xFF); XCTAssertEqual(out[resume + 1], 0xE0) // original APP0 resumes
    }

    /// The assembled Ultra HDR file: correct GContainer length, both namespaces, still a valid SDR JPEG.
    func testUltraHDRStructure() {
        let w = 8, h = 8, n = w * h
        var sdr = [Float](repeating: 0, count: n * 4)
        for i in 0..<n { let v = Float(i) / Float(n); for c in 0..<3 { sdr[i * 4 + c] = v }; sdr[i * 4 + 3] = 1 }
        let gmPixels = [UInt8](repeating: 128, count: n)

        let sdrJPEG = JPEGEncoder.encode(rgba: sdr, width: w, height: h, quality: 0.9)!
        let gmJPEG = UltraHDRWriter.encodeGray8(gmPixels, width: w, height: h, quality: 0.9)!
        let meta = GainMapMetadata(gainMapMin: 0, gainMapMax: 2, gamma: 1,
                                   offsetSDR: 1.0 / 64, offsetHDR: 1.0 / 64,
                                   hdrCapacityMin: 0, hdrCapacityMax: 2)
        let file = UltraHDRWriter.assemble(sdrJPEG: sdrJPEG, gainMapJPEG: gmJPEG, metadata: meta)

        // The appended bytes are exactly the XMP-tagged gain-map JPEG…
        let gmWithXMP = UltraHDRWriter.insertXMP(into: gmJPEG, xmp: UltraHDRWriter.gainMapXMP(meta))
        XCTAssertTrue(file.suffix(gmWithXMP.count).elementsEqual(gmWithXMP))

        // …and the primary's GContainer advertises that exact length, with the expected namespaces.
        let text = String(decoding: file, as: UTF8.self)
        XCTAssertTrue(text.contains("Item:Length=\"\(gmWithXMP.count)\""))
        XCTAssertTrue(text.contains("ns.google.com/photos/1.0/container"))
        XCTAssertTrue(text.contains("Semantic=\"GainMap\""))
        XCTAssertTrue(text.contains("ns.adobe.com/hdr-gain-map/1.0"))
        XCTAssertTrue(text.contains("BaseRenditionIsHDR=\"False\""))

        // Degrades gracefully: the file still decodes as a normal JPEG at the original size.
        let src = CGImageSourceCreateWithData(file as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        XCTAssertEqual(img.width, w)
        XCTAssertEqual(img.height, h)

        let bytes = [UInt8](file)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8])   // SOI
        XCTAssertEqual(Array(bytes.suffix(2)), [0xFF, 0xD9])   // gain map's EOI
    }
}
