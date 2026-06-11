import Foundation
import simd

/// A small, platform-agnostic snapshot of one pipeline stage, produced **only when a caller opts in**
/// via `IndigoPipeline.process(..., captureStages: true)`. It carries a downscaled RGBA8 thumbnail and,
/// for the two stages where it tells the story best, an overlay the UI draws on top (the alignment
/// motion field, the merge robustness/ghost-rejection heatmap).
///
/// RawloomCore stays free of any UI framework: the app turns these value types into views. The stages
/// mirror `docs/PIPELINE.md` — capture → reference → align → merge → demosaic → colour → result.
public struct StagePreview: Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case capture     // the underexposed raw burst
        case reference   // the sharpest frame, chosen as the merge base
        case align       // per-tile motion estimated against the reference
        case merge       // robust multi-frame merge (denoise + ghost rejection)
        case demosaic    // Bayer → camera-native RGB
        case color       // white balance · CCM · exposure
        case result      // tone map · sRGB — the finished image
    }

    public var id: Kind { kind }
    public let kind: Kind
    /// Short stage name for the filmstrip (e.g. "Merge").
    public let title: String
    /// One-line description of what this step did (e.g. "16px tiles · ±4px search").
    public let detail: String
    /// Downscaled RGBA8 preview (≤256px long edge).
    public let image: PreviewImage
    /// Optional data the UI draws over `image`.
    public let overlay: PreviewOverlay?

    public init(kind: Kind, title: String, detail: String,
                image: PreviewImage, overlay: PreviewOverlay? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.image = image
        self.overlay = overlay
    }
}

/// A tiny RGBA8 image (row-major, `width*height*4`, alpha = 255). Cheap to ship to the UI and turn
/// into a `CGImage`.
public struct PreviewImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgba8: [UInt8]

    public init(width: Int, height: Int, rgba8: [UInt8]) {
        precondition(rgba8.count == width * height * 4, "rgba8 must be width*height*4")
        self.width = width
        self.height = height
        self.rgba8 = rgba8
    }
}

/// Extra per-stage data the UI renders over the thumbnail.
public enum PreviewOverlay: Sendable {
    /// Per-tile motion vectors (in half-resolution plane pixels), laid out row-major over a
    /// `cols × rows` tile grid. The UI draws one arrow per tile.
    case motionField(vectors: [SIMD2<Float>], cols: Int, rows: Int, tileSize: Int)
    /// A pre-colourised heatmap the UI blends over the base image, with a legend caption.
    case heatmap(PreviewImage, caption: String)
}
