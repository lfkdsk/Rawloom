import Foundation
import CoreGraphics
import ImageIO

#if canImport(Metal)
import Metal
#endif

/// Encodes the finished display image (sRGB-encoded `rgba32Float`, `[0,1]`) as JPEG.
///
/// Project Indigo's JPEG is actually a hybrid SDR + HDR-gain-map file (`docs/PIPELINE.md` §7); this
/// writes the SDR base. The gain map is produced separately (`GainMap`) and can be attached as an
/// auxiliary image by an ISO-HDR-aware encoder.
public enum JPEGEncoder {

    /// Encode interleaved RGBA floats (length `width*height*4`) to JPEG `Data`.
    public static func encode(rgba: [Float], width: Int, height: Int, quality: CGFloat = 0.95) -> Data? {
        precondition(rgba.count == width * height * 4)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            bytes[i * 4 + 0] = quantize(rgba[i * 4 + 0])
            bytes[i * 4 + 1] = quantize(rgba[i * 4 + 1])
            bytes[i * 4 + 2] = quantize(rgba[i * 4 + 2])
            bytes[i * 4 + 3] = 255
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, jpegUTType, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    @inline(__always)
    private static func quantize(_ v: Float) -> UInt8 {
        UInt8(min(max(v, 0), 1) * 255 + 0.5)
    }

    private static let jpegUTType: CFString = "public.jpeg" as CFString
}

#if canImport(Metal)
public extension JPEGEncoder {
    /// Convenience: encode a finished display texture from a `MetalContext`.
    static func encode(displayTexture: MTLTexture, context: MetalContext, quality: CGFloat = 0.95) -> Data? {
        encode(rgba: context.readRGBA(displayTexture),
               width: displayTexture.width, height: displayTexture.height, quality: quality)
    }
}
#endif
