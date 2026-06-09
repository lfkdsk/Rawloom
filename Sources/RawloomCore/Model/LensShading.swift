import Foundation

/// Per-channel lens-shading (vignetting / flat-field) gain map.
///
/// Stored as a low-resolution grid of multiplicative gains that is bilinearly upsampled to full
/// resolution and multiplied into the raw *before* white balance (`docs/PIPELINE.md` §6.2), so that
/// both luminance falloff and colour shading toward the frame edges are corrected.
///
/// iOS supplies this directly via `AVCapturePhoto`'s lens-shading map; when absent we synthesise a
/// gentle radial model so the pipeline still behaves sensibly.
public struct LensShadingMap: Sendable {
    public let columns: Int
    public let rows: Int
    /// `rows*columns` gains per channel, row-major. Channel order R, G, B (greens share G).
    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]

    public init(columns: Int, rows: Int, red: [Float], green: [Float], blue: [Float]) {
        precondition(red.count == columns * rows)
        precondition(green.count == columns * rows)
        precondition(blue.count == columns * rows)
        self.columns = columns
        self.rows = rows
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A smooth radial vignetting model: gain rises toward the corners to undo falloff.
    /// `cornerGain` is the multiplier applied at the extreme corner (≈ 1/transmission).
    public static func radial(columns: Int = 17, rows: Int = 13, cornerGain: Float = 1.6) -> LensShadingMap {
        var r = [Float](repeating: 1, count: columns * rows)
        let cx = Float(columns - 1) / 2
        let cy = Float(rows - 1) / 2
        let maxR2 = cx * cx + cy * cy
        for y in 0..<rows {
            for x in 0..<columns {
                let dx = Float(x) - cx
                let dy = Float(y) - cy
                let t = (dx * dx + dy * dy) / maxR2 // 0 at centre → 1 at corner
                r[y * columns + x] = 1 + (cornerGain - 1) * t
            }
        }
        // Colour shading is usually mild; reuse the luminance falloff for all channels by default.
        return LensShadingMap(columns: columns, rows: rows, red: r, green: r, blue: r)
    }
}
