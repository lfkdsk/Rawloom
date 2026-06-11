import Foundation
import CoreGraphics
import ImageIO

#if canImport(Metal)
import Metal
#endif

/// Assembles a portable **Ultra HDR** JPEG (the ISO 21496-1 / Adobe gain-map family, `docs/PIPELINE.md`
/// §7): a standard SDR base JPEG with an appended single-channel gain-map JPEG, tied together by XMP —
/// a GContainer directory in the primary image and `hdrgm` parameters in the gain map. HDR-aware
/// viewers (Chrome, Android, modern Photos) reconstruct the HDR rendition; every other decoder simply
/// shows the SDR base and ignores the trailing bytes.
public enum UltraHDRWriter {

    /// Assemble the file from an already-encoded SDR base JPEG and gain-map JPEG + its metadata.
    public static func assemble(sdrJPEG: Data, gainMapJPEG: Data, metadata: GainMapMetadata) -> Data {
        let gm = insertXMP(into: gainMapJPEG, xmp: gainMapXMP(metadata))
        let primary = insertXMP(into: sdrJPEG, xmp: primaryXMP(gainMapLength: gm.count))
        return primary + gm
    }

    /// Encode interleaved sRGB RGBA (SDR) + linear RGBA (HDR) into one Ultra HDR JPEG. The gain map is
    /// written at `1/downsample` resolution (decoders upsample it). Returns `nil` only if the underlying
    /// JPEG encode fails.
    public static func encode(
        sdrSRGB: [Float], hdrLinear: [Float], width: Int, height: Int,
        downsample: Int = 2, quality: CGFloat = 0.95
    ) -> Data? {
        guard let sdr = JPEGEncoder.encode(rgba: sdrSRGB, width: width, height: height, quality: quality)
        else { return nil }
        let gm = GainMap.compute(sdrSRGB: sdrSRGB, hdrLinear: hdrLinear,
                                 width: width, height: height, downsample: downsample)
        guard let gmJPEG = encodeGray8(gm.pixels, width: gm.width, height: gm.height, quality: quality)
        else { return nil }
        return assemble(sdrJPEG: sdr, gainMapJPEG: gmJPEG, metadata: gm.metadata)
    }

    // MARK: - Grayscale JPEG

    /// Encode a single-channel 8-bit image (`width*height` bytes) as a grayscale JPEG.
    static func encodeGray8(_ pixels: [UInt8], width: Int, height: Int, quality: CGFloat) -> Data? {
        precondition(pixels.count == width * height)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let img = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, jpegUTType, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - XMP

    private static let xmpHeader = "http://ns.adobe.com/xap/1.0/\0"
    private static let jpegUTType: CFString = "public.jpeg" as CFString

    /// Insert an APP1 XMP segment immediately after the SOI marker. Returns the input unchanged if it
    /// is not a JPEG or the packet would overflow a single APP1 segment (64 KB).
    static func insertXMP(into jpeg: Data, xmp: String) -> Data {
        let bytes = [UInt8](jpeg)
        guard bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return jpeg }
        let payload = Array(xmpHeader.utf8) + Array(xmp.utf8)
        let len = payload.count + 2   // APP1 length field counts itself
        guard len <= 0xFFFF else { return jpeg }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + 4 + payload.count)
        out.append(contentsOf: [0xFF, 0xD8])                                   // SOI
        out.append(contentsOf: [0xFF, 0xE1, UInt8(len >> 8), UInt8(len & 0xFF)]) // APP1 marker + length
        out.append(contentsOf: payload)                                        // "http://ns.adobe…\0" + XMP
        out.append(contentsOf: bytes[2...])                                    // the rest of the JPEG
        return Data(out)
    }

    /// GContainer directory for the primary image: declares the Primary item and the appended GainMap
    /// item with its exact byte length, so a decoder can locate the gain map after the primary's EOI.
    static func primaryXMP(gainMapLength: Int) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Rawloom">\
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" \
        xmlns:Container="http://ns.google.com/photos/1.0/container/" \
        xmlns:Item="http://ns.google.com/photos/1.0/container/item/" \
        xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0">\
        <Container:Directory><rdf:Seq>\
        <rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/></rdf:li>\
        <rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="GainMap" Item:Mime="image/jpeg" Item:Length="\(gainMapLength)"/></rdf:li>\
        </rdf:Seq></Container:Directory>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }

    /// `hdrgm` parameters for the gain-map image: how a decoder turns stored 0…1 values into the log2
    /// gain and reconstructs HDR.
    static func gainMapXMP(_ m: GainMapMetadata) -> String {
        func f(_ v: Float) -> String { String(format: "%.6f", v) }
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Rawloom">\
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" \
        hdrgm:Version="1.0" \
        hdrgm:GainMapMin="\(f(m.gainMapMin))" hdrgm:GainMapMax="\(f(m.gainMapMax))" \
        hdrgm:Gamma="\(f(m.gamma))" \
        hdrgm:OffsetSDR="\(f(m.offsetSDR))" hdrgm:OffsetHDR="\(f(m.offsetHDR))" \
        hdrgm:HDRCapacityMin="\(f(m.hdrCapacityMin))" hdrgm:HDRCapacityMax="\(f(m.hdrCapacityMax))" \
        hdrgm:BaseRenditionIsHDR="False"/>\
        </rdf:RDF></x:xmpmeta>
        """
    }
}

#if canImport(Metal)
public extension JPEGEncoder {
    /// Convenience: build an Ultra HDR JPEG from a finished SDR display texture and the HDR (linear)
    /// rendition texture (both `rgba32Float`, same size).
    static func encodeUltraHDR(sdr: MTLTexture, hdr: MTLTexture, context: MetalContext,
                               quality: CGFloat = 0.95) -> Data? {
        UltraHDRWriter.encode(
            sdrSRGB: context.readRGBA(sdr), hdrLinear: context.readRGBA(hdr),
            width: sdr.width, height: sdr.height, quality: quality)
    }

    /// Convenience: build an Ultra HDR JPEG from a finished SDR display texture and a *precomputed* gain
    /// map (the pipeline builds the map; the app only encodes + assembles).
    static func encodeUltraHDR(sdr: MTLTexture, gainMap: GainMapData, context: MetalContext,
                               quality: CGFloat = 0.95) -> Data? {
        guard let sdrJPEG = JPEGEncoder.encode(rgba: context.readRGBA(sdr),
                                               width: sdr.width, height: sdr.height, quality: quality),
              let gmJPEG = UltraHDRWriter.encodeGray8(gainMap.pixels, width: gainMap.width,
                                                      height: gainMap.height, quality: quality)
        else { return nil }
        return UltraHDRWriter.assemble(sdrJPEG: sdrJPEG, gainMapJPEG: gmJPEG, metadata: gainMap.metadata)
    }
}
#endif
