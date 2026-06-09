import Foundation
import simd

/// A clean, noise-free linear-RGB image used as ground truth for the synthetic burst generator and
/// as the content of the simulator demo capture source. Values are linear `[0,1]`, row-major.
public struct SyntheticScene: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [SIMD3<Float>]

    public init(width: Int, height: Int, pixels: [SIMD3<Float>]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Bilinear sample at fractional `(x, y)` with clamp-to-edge — lets the generator apply
    /// sub-pixel shifts (simulated hand tremor).
    public func sample(x: Float, y: Float) -> SIMD3<Float> {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ax = x - fx, ay = y - fy
        let x0 = min(max(Int(fx), 0), width - 1)
        let y0 = min(max(Int(fy), 0), height - 1)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let v00 = pixels[y0 * width + x0]
        let v10 = pixels[y0 * width + x1]
        let v01 = pixels[y1 * width + x0]
        let v11 = pixels[y1 * width + x1]
        let top = mix(v00, v10, t: ax)
        let bot = mix(v01, v11, t: ax)
        return mix(top, bot, t: ay)
    }

    @inline(__always)
    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
}

// MARK: - Procedural patterns

public extension SyntheticScene {

    /// Smooth gradients + a few soft colour blobs + a couple of sharp bars. A good general scene:
    /// large flat-ish regions make denoising gains easy to measure, the bars give edges to align on.
    static func gradientBlobs(width: Int = 256, height: Int = 256) -> SyntheticScene {
        var px = [SIMD3<Float>](repeating: .zero, count: width * height)
        let blobs: [(cx: Float, cy: Float, r: Float, c: SIMD3<Float>)] = [
            (Float(width) * 0.30, Float(height) * 0.35, Float(width) * 0.18, SIMD3(0.9, 0.4, 0.3)),
            (Float(width) * 0.70, Float(height) * 0.60, Float(width) * 0.22, SIMD3(0.3, 0.6, 0.9)),
            (Float(width) * 0.55, Float(height) * 0.25, Float(width) * 0.12, SIMD3(0.4, 0.85, 0.4)),
        ]
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) / Float(width - 1)
                let v = Float(y) / Float(height - 1)
                var c = SIMD3<Float>(0.18 + 0.5 * u, 0.18 + 0.5 * v, 0.5 - 0.3 * u)
                for b in blobs {
                    let dx = Float(x) - b.cx, dy = Float(y) - b.cy
                    let g = exp(-(dx * dx + dy * dy) / (2 * b.r * b.r))
                    c += b.c * g * 0.6
                }
                // a couple of sharp vertical/horizontal bars for edges
                if (x % 64) < 3 || (y % 80) < 3 { c = SIMD3(repeating: 0.95) }
                px[y * width + x] = clamp(c, min: SIMD3(repeating: 0), max: SIMD3(repeating: 1))
            }
        }
        return SyntheticScene(width: width, height: height, pixels: px)
    }

    /// High-contrast checkerboard — an alignment / ghosting stress pattern (lots of identical edges).
    static func checker(width: Int = 256, height: Int = 256, square: Int = 16) -> SyntheticScene {
        var px = [SIMD3<Float>](repeating: .zero, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let on = ((x / square) + (y / square)) % 2 == 0
                px[y * width + x] = SIMD3(repeating: on ? 0.9 : 0.1)
            }
        }
        return SyntheticScene(width: width, height: height, pixels: px)
    }

    /// Siemens star — radial spokes with frequency rising toward the centre; exercises demosaic /
    /// super-resolution and aliasing handling.
    static func siemensStar(width: Int = 256, height: Int = 256, spokes: Int = 36) -> SyntheticScene {
        var px = [SIMD3<Float>](repeating: .zero, count: width * height)
        let cx = Float(width) / 2, cy = Float(height) / 2
        for y in 0..<height {
            for x in 0..<width {
                let dx = Float(x) - cx, dy = Float(y) - cy
                let angle = atan2(dy, dx)
                let s = 0.5 + 0.5 * cos(Float(spokes) * angle)
                let r = (dx * dx + dy * dy).squareRoot()
                let vignette = max(0, 1 - r / (0.5 * Float(width)))
                px[y * width + x] = SIMD3(repeating: (s > 0.5 ? 0.9 : 0.12) * (0.4 + 0.6 * vignette))
            }
        }
        return SyntheticScene(width: width, height: height, pixels: px)
    }
}
