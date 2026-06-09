import Foundation
import Metal

/// Allocation + CPU⇄GPU transfer helpers for the textures the pipeline passes between stages.
///
/// Conventions used throughout Rawloom:
/// * raw Bayer mosaics live in single-channel `.r16Uint` textures (the sensor codes verbatim);
/// * scalar working images (grayscale, single Bayer plane, luma) are `.r32Float`;
/// * full-colour images are `.rgba32Float` (alpha unused / 1).
public extension MetalContext {

    func makeTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw MetalError.textureAllocationFailed
        }
        return texture
    }

    func makeFloat(width: Int, height: Int,
                   usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) throws -> MTLTexture {
        try makeTexture(width: width, height: height, pixelFormat: .r32Float, usage: usage)
    }

    func makeRGBA(width: Int, height: Int,
                  usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) throws -> MTLTexture {
        try makeTexture(width: width, height: height, pixelFormat: .rgba32Float, usage: usage)
    }

    /// A 2-channel float texture holding a per-tile motion vector field (dx, dy).
    func makeField(tilesX: Int, tilesY: Int,
                   usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) throws -> MTLTexture {
        try makeTexture(width: tilesX, height: tilesY, pixelFormat: .rg32Float, usage: usage)
    }

    // MARK: Upload

    /// Upload a raw Bayer mosaic (16-bit codes) into a `.r16Uint` texture.
    func uploadRaw(_ frame: RawFrame) throws -> MTLTexture {
        let texture = try makeTexture(width: frame.width, height: frame.height,
                                      pixelFormat: .r16Uint, usage: [.shaderRead])
        frame.samples.withUnsafeBytes { buf in
            texture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: frame.width * MemoryLayout<UInt16>.stride
            )
        }
        return texture
    }

    /// Upload a single-channel float image.
    func uploadFloat(_ values: [Float], width: Int, height: Int) throws -> MTLTexture {
        precondition(values.count == width * height)
        let texture = try makeFloat(width: width, height: height)
        values.withUnsafeBytes { buf in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float>.stride
            )
        }
        return texture
    }

    // MARK: Read-back

    /// Read a `.r32Float` texture into a row-major `[Float]`.
    func readFloats(_ texture: MTLTexture) -> [Float] {
        let w = texture.width, h = texture.height
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBytes { buf in
            texture.getBytes(
                buf.baseAddress!,
                bytesPerRow: w * MemoryLayout<Float>.stride,
                from: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0
            )
        }
        return out
    }

    /// Read an `.rg32Float` motion-vector field into `[SIMD2<Float>]`.
    func readField(_ texture: MTLTexture) -> [SIMD2<Float>] {
        let w = texture.width, h = texture.height
        var out = [SIMD2<Float>](repeating: .zero, count: w * h)
        out.withUnsafeMutableBytes { buf in
            texture.getBytes(
                buf.baseAddress!,
                bytesPerRow: w * MemoryLayout<SIMD2<Float>>.stride,
                from: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0
            )
        }
        return out
    }

    /// Read an `.rgba32Float` texture into interleaved RGBA floats (length `w*h*4`).
    func readRGBA(_ texture: MTLTexture) -> [Float] {
        let w = texture.width, h = texture.height
        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buf in
            texture.getBytes(
                buf.baseAddress!,
                bytesPerRow: w * 4 * MemoryLayout<Float>.stride,
                from: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0
            )
        }
        return out
    }
}
