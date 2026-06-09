import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import os
import RawloomCore

/// Converts an `AVCapturePhoto` (Bayer raw) into a `RawFrame` the pipeline can consume.
///
/// Black/white levels and full raw white-balance aren't always exposed via `AVCapturePhoto`
/// metadata; we read what's available (ISO, exposure, CFA from the pixel format) and fall back to
/// sane 14-bit-sensor defaults otherwise. The values are recorded back into the DNG on output.
enum RawPhotoConverter {

    private static let log = Logger(subsystem: "com.rawloom", category: "raw")

    static func convert(_ photo: AVCapturePhoto,
                        whiteBalance: WhiteBalanceGains = .neutral,
                        sensor: SensorRawInfo? = nil,
                        diagnostics: Bool = false) -> RawFrame? {
        guard let pixelBuffer = photo.pixelBuffer else { return nil }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        // Prefer the CFA/levels from the DNG metadata; fall back to the pixel-format guess + defaults.
        let cfa = sensor?.cfa ?? cfaPattern(for: format)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        // Raw Bayer is one 16-bit sample per pixel (14 significant bits).
        var samples = [UInt16](repeating: 0, count: width * height)
        samples.withUnsafeMutableBytes { dst in
            for y in 0..<height {
                let src = base.advanced(by: y * bytesPerRow)
                memcpy(dst.baseAddress!.advanced(by: y * width * 2), src, width * 2)
            }
        }

        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first as? Double ?? 100
        let exposure = exif?[kCGImagePropertyExifExposureTime as String] as? Double ?? (1.0 / 120)

        // White balance: the DNG's AsShotNeutral is authoritative; else the device AWB gains.
        var wb = whiteBalance
        if let n = sensor?.asShotNeutral, n.x > 0, n.y > 0, n.z > 0 {
            wb = WhiteBalanceGains(red: n.y / n.x, green: 1, blue: n.y / n.z)
        }

        // CCM (camera-native → linear sRGB): prefer the DNG's ForwardMatrix; fall back to ColorMatrix
        // (Apple's Bayer-raw DNGs ship ColorMatrix but usually omit ForwardMatrix); else identity.
        // Identity leaves colours flat/washed-out (docs/PIPELINE.md §6.5). Both matrix paths are
        // neutral-preserving, so they add colour richness without a cast.
        let colorMatrix: ColorMatrix
        let ccmSource: String
        if let fm = sensor?.forwardMatrix {
            colorMatrix = .cameraToLinearSRGB(forwardMatrixD50: fm); ccmSource = "fwdMatrix"
        } else if let cm = sensor?.colorMatrix {
            colorMatrix = .cameraToLinearSRGB(colorMatrixXYZtoCam: cm); ccmSource = "colorMatrix"
        } else {
            colorMatrix = .identity; ccmSource = "identity"
        }

        var whiteLevel = sensor?.whiteLevel ?? 16383 // 14-bit sensor fallback
        var black = sensor?.blackLevel ?? SIMD4(repeating: 0)
        let haveDNGBlack = (black.x + black.y + black.z + black.w) >= 1
        var blackSource = haveDNGBlack ? "dng" : "estimated"

        let (mn, mx, mean) = sampleStats(samples)

        // 1. Reconcile a bit-depth scale mismatch: Apple can report black/white at the sensor's native
        //    depth (e.g. 12-bit 528/4095) while the pixel buffer is 14-bit (the same data runs to
        //    ~16383). Subtracting the un-scaled black leaves most of the pedestal in → white balance
        //    turns the residual purple. Scale the DNG levels up to the buffer. See RawLevelScale.
        let scale = RawLevelScale.factor(dngWhite: whiteLevel, sampleMax: Int(mx))
        if scale > 1 {
            whiteLevel *= scale
            if haveDNGBlack { black *= scale } // an estimated black is already at buffer scale
            blackSource += "×\(Int(scale))"
        }

        // 2. If the DNG carried no usable black level, estimate the pedestal directly from the buffer
        //    rather than subtracting zero (which would leave the full pedestal → pink). See
        //    BlackLevelEstimator.
        if !haveDNGBlack {
            let est = BlackLevelEstimator.estimate(samples: samples, width: width, height: height, cfa: cfa)
            let cap = max(whiteLevel, Float(mx)) * 0.25 // a real pedestal is a small fraction of full scale
            black = SIMD4(min(est.x, cap), min(est.y, cap), min(est.z, cap), min(est.w, cap))
        }

        if diagnostics {
            log.log("""
            raw ingest \(width, privacy: .public)x\(height, privacy: .public) \
            cfa=\(String(describing: cfa), privacy: .public) \
            black=[\(black.x, privacy: .public),\(black.y, privacy: .public),\
            \(black.z, privacy: .public),\(black.w, privacy: .public)](\(blackSource, privacy: .public)) \
            white=\(whiteLevel, privacy: .public) \
            wb=(R\(wb.red, privacy: .public) G\(wb.green, privacy: .public) B\(wb.blue, privacy: .public)) \
            asShotNeutral=\(sensor?.asShotNeutral != nil ? "yes" : "no", privacy: .public) \
            ccm=\(ccmSource, privacy: .public) \
            samples[min=\(mn, privacy: .public) max=\(mx, privacy: .public) mean=\(Int(mean), privacy: .public)] \
            iso=\(Int(iso), privacy: .public)
            """)
        }

        let metadata = RawImageMetadata(
            cfa: cfa,
            blackLevel: black,
            whiteLevel: whiteLevel,
            iso: iso,
            exposureDuration: exposure,
            timestamp: photo.timestamp.seconds.isFinite ? photo.timestamp.seconds : 0,
            whiteBalance: wb,
            colorMatrix: colorMatrix,
            noise: NoiseModel.estimated(iso: iso)
        )
        return RawFrame(width: width, height: height, samples: samples, metadata: metadata)
    }

    /// Min / max / mean of a (subsampled) raw frame — a cheap sanity read for the diagnostics log.
    /// A `min` far above zero is the sensor's black pedestal; if `black` ends up below it, the
    /// pedestal is being left in (→ pink).
    private static func sampleStats(_ s: [UInt16]) -> (min: UInt16, max: UInt16, mean: Double) {
        guard !s.isEmpty else { return (0, 0, 0) }
        var mn = UInt16.max, mx = UInt16.min
        var sum = 0.0, n = 0
        var i = 0
        while i < s.count { let v = s[i]; if v < mn { mn = v }; if v > mx { mx = v }; sum += Double(v); n += 1; i += 64 }
        return (mn, mx, sum / Double(max(n, 1)))
    }

    private static func cfaPattern(for format: OSType) -> CFAPattern {
        switch format {
        case kCVPixelFormatType_14Bayer_RGGB: return .rggb
        case kCVPixelFormatType_14Bayer_GRBG: return .grbg
        case kCVPixelFormatType_14Bayer_BGGR: return .bggr
        case kCVPixelFormatType_14Bayer_GBRG: return .gbrg
        default: return .rggb
        }
    }
}
