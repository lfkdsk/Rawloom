import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Non-destructive edit parameters applied to a finished JPEG (the creative "develop" layer on top of
/// the already-correct render — exposure/contrast/saturation/temperature, plus an optional 3D LUT).
struct PhotoAdjustments: Equatable {
    var exposure: Float = 0       // EV, −2…+2
    var contrast: Float = 1       // 0.5…1.5
    var saturation: Float = 1     // 0…2
    var temperature: Float = 6500 // K, 4000…9000 (6500 = no shift)
    var lut: CubeLUT?

    var isIdentity: Bool {
        exposure == 0 && contrast == 1 && saturation == 1 && temperature == 6500 && lut == nil
    }
}

/// Applies `PhotoAdjustments` with Core Image. A shared `CIContext` renders both the live preview
/// (downscaled) and the full-resolution save.
enum PhotoEditor {
    static let context = CIContext(options: [.useSoftwareRenderer: false])
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)

    static func apply(_ adj: PhotoAdjustments, to input: CIImage) -> CIImage {
        var img = input

        if adj.temperature != 6500 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: CGFloat(adj.temperature), y: 0)
            img = f.outputImage ?? img
        }
        if adj.exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = adj.exposure
            img = f.outputImage ?? img
        }
        if adj.contrast != 1 || adj.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = img; f.contrast = adj.contrast; f.saturation = adj.saturation
            img = f.outputImage ?? img
        }
        if let lut = adj.lut {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img
            f.cubeDimension = Float(lut.size)
            f.cubeData = lut.data
            f.colorSpace = srgb
            img = f.outputImage ?? img
        }
        return img
    }

    /// Render a (possibly downscaled) preview CGImage.
    static func renderCGImage(_ adj: PhotoAdjustments, from image: CIImage) -> CGImage? {
        let out = apply(adj, to: image)
        return context.createCGImage(out, from: out.extent)
    }

    /// Render the full-resolution edit to JPEG data.
    static func renderJPEG(_ adj: PhotoAdjustments, fromFile url: URL) -> Data? {
        guard let input = CIImage(contentsOf: url) else { return nil }
        let out = apply(adj, to: input)
        guard let cg = context.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.95)
    }

    /// A downscaled `CIImage` for responsive live editing (longest side ≈ `maxDimension`).
    static func previewImage(from url: URL, maxDimension: CGFloat = 1400) -> CIImage? {
        guard let full = CIImage(contentsOf: url) else { return nil }
        let scale = min(1, maxDimension / max(full.extent.width, full.extent.height))
        return scale < 1 ? full.transformed(by: .init(scaleX: scale, y: scale)) : full
    }
}
