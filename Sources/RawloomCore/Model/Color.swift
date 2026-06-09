import Foundation

/// As-shot white-balance gains. Green is the reference channel (gain 1); red and blue are scaled to
/// neutralise the illuminant. Applied in the finishing stage (`docs/PIPELINE.md` §6.3) and recorded
/// `AsShotNeutral` in the DNG.
public struct WhiteBalanceGains: Sendable, Codable, Equatable {
    public var red: Float
    public var green: Float
    public var blue: Float

    public init(red: Float, green: Float = 1, blue: Float) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let neutral = WhiteBalanceGains(red: 1, green: 1, blue: 1)

    public var simd: SIMD3<Float> { SIMD3(red, green, blue) }
}

/// A 3×3 colour transform stored row-major. Used for the camera-native-RGB → linear-sRGB conversion
/// (the "CCM" step, `docs/PIPELINE.md` §6.5).
public struct ColorMatrix: Sendable, Codable, Equatable {
    /// Row-major 9 elements: `[m00,m01,m02, m10,m11,m12, m20,m21,m22]`.
    public var m: [Float]

    public init(_ m: [Float]) {
        precondition(m.count == 9, "ColorMatrix requires 9 elements")
        self.m = m
    }

    public func transform(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            m[0] * v.x + m[1] * v.y + m[2] * v.z,
            m[3] * v.x + m[4] * v.y + m[5] * v.z,
            m[6] * v.x + m[7] * v.y + m[8] * v.z
        )
    }

    /// Identity (camera primaries already assumed ≈ sRGB). A real device supplies its own matrix via
    /// DNG metadata; this keeps the pipeline correct-by-default for synthetic/test input.
    public static let identity = ColorMatrix([1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// Build the camera-native → linear-sRGB matrix (the **CCM**) from a DNG **ForwardMatrix**
    /// (white-balanced camera → XYZ D50). Folds in the Bradford D50→D65 chromatic adaptation and the
    /// XYZ→linear-sRGB primaries.
    ///
    /// Neutral-preserving *by construction*: a DNG ForwardMatrix maps the camera neutral to the D50
    /// white point, which the folded matrix maps back to sRGB white — so wiring this in corrects
    /// saturation/hue (the flat, washed-out look) **without** introducing any global colour cast.
    /// See `docs/PIPELINE.md` §6.5. Falls back to ``identity`` when the DNG carries no ForwardMatrix.
    public static func cameraToLinearSRGB(forwardMatrixD50 fm: [Float]) -> ColorMatrix {
        guard fm.count == 9 else { return .identity }
        // XYZ(D50) → linear sRGB(D65), Bradford-adapted (Lindbloom's published constants).
        let xyzD50ToSRGB: [Float] = [
             3.1338561, -1.6168667, -0.4906146,
            -0.9787684,  1.9161415,  0.0334540,
             0.0719453, -0.2289914,  1.4052427,
        ]
        return ColorMatrix(mat3Mul(xyzD50ToSRGB, fm))
    }

    /// Build the camera-native → linear-sRGB matrix (the **CCM**) from a DNG **ColorMatrix**
    /// (XYZ → camera, for the calibration illuminant). Used when the DNG carries no ForwardMatrix
    /// (Apple's Bayer-raw DNGs include only the required ColorMatrix). This is dcraw's method:
    /// form sRGB→camera = ColorMatrix · (sRGB→XYZ), **normalise each row to sum to 1** so sRGB white
    /// maps to the camera neutral, then invert. The row-normalisation makes it neutral-preserving (no
    /// cast); white balance is applied separately upstream. Falls back to ``identity`` if not invertible.
    public static func cameraToLinearSRGB(colorMatrixXYZtoCam cm: [Float]) -> ColorMatrix {
        guard cm.count == 9 else { return .identity }
        // linear sRGB(D65) → XYZ.
        let srgbToXYZ: [Float] = [
            0.4124564, 0.3575761, 0.1804375,
            0.2126729, 0.7151522, 0.0721750,
            0.0193339, 0.1191920, 0.9503041,
        ]
        var rgb2cam = mat3Mul(cm, srgbToXYZ)                  // sRGB → camera
        for i in 0..<3 {                                       // normalise rows ⇒ white → neutral
            let s = rgb2cam[i * 3] + rgb2cam[i * 3 + 1] + rgb2cam[i * 3 + 2]
            if abs(s) > 1e-6 { for j in 0..<3 { rgb2cam[i * 3 + j] /= s } }
        }
        guard let cam2rgb = mat3Inverse(rgb2cam) else { return .identity }
        return ColorMatrix(cam2rgb)
    }

    /// Row-major elements suitable for uploading to a Metal `float3x3` (column-major) — see
    /// ``columnMajor``.
    public var rowMajor: [Float] { m }

    /// Metal/`simd` matrices are column-major; transpose for upload.
    public var columnMajor: [Float] {
        [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]
    }
}

// Row-major 3×3 helpers for the CCM factories.
private func mat3Mul(_ a: [Float], _ b: [Float]) -> [Float] {
    var r = [Float](repeating: 0, count: 9)
    for i in 0..<3 { for j in 0..<3 {
        r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
    } }
    return r
}

private func mat3Inverse(_ m: [Float]) -> [Float]? {
    let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
    let A = e * i - f * h, B = f * g - d * i, C = d * h - e * g
    let det = a * A + b * B + c * C
    guard abs(det) > 1e-9 else { return nil }
    let inv = 1 / det
    return [
        A * inv,             (c * h - b * i) * inv, (b * f - c * e) * inv,
        B * inv,             (a * i - c * g) * inv, (c * d - a * f) * inv,
        C * inv,             (b * g - a * h) * inv, (a * e - b * d) * inv,
    ]
}
