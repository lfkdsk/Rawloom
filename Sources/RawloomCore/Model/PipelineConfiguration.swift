import Foundation

/// Capture/processing mode. Mirrors Indigo's Photo vs Night behaviour (`docs/PIPELINE.md` §1.2).
public enum CaptureMode: String, Sendable, Codable {
    /// Short burst, highlight-protected exposure, ZSL from the ring buffer.
    case photo
    /// Long motion-metered burst, harder merge, optional super-resolution.
    case night
}

/// Distance metric for block-matching alignment.
public enum BlockMatchMetric: String, Sendable, Codable {
    case l1
    case l2
}

/// All tunables for one run of the pipeline. The two presets (`.photo`, `.night`) reproduce the
/// defaults table at the end of `docs/PIPELINE.md`.
public struct PipelineConfiguration: Sendable, Codable {
    public var mode: CaptureMode

    // MARK: Capture
    /// Target number of frames in the burst.
    public var burstLength: Int
    /// Fraction of white the highlight metering aims to keep the bright tones below (highlight
    /// protection). 0.8 ⇒ keep the 95th-percentile highlight ≤ 0.8·white.
    public var highlightHeadroom: Float

    // MARK: Alignment
    public var pyramidLevels: Int
    /// Tile edge length (px) at the finest pyramid level for block matching and merge.
    public var tileSize: Int
    /// Search radius (± px) per pyramid level.
    public var searchRadius: Int
    public var metric: BlockMatchMetric
    /// Regularisation weight λ favouring small/smooth motion vectors.
    public var motionRegularization: Float

    // MARK: Merge
    /// Robustness constant `c` in the Wiener shrinkage `A = D/(D + c·σ²)`. Higher = more denoise.
    public var mergeRobustness: Float
    /// Use the frequency-domain (DFT) merge. `false` ⇒ the cheaper spatial robust merge.
    public var useFrequencyMerge: Bool

    // MARK: Super-resolution
    /// Drizzle upsample factor (1 = off / plain demosaic, 2 = 2× super-res).
    public var superResolutionFactor: Int

    // MARK: Finishing
    /// Strength of local-Laplacian local tone mapping (0 = off … 1 = strong shadow lift).
    public var localToneStrength: Float
    /// Capture-sharpening amount (unsharp-mask gain on luma).
    public var sharpenAmount: Float
    /// Global saturation multiplier applied at the end of finishing.
    public var saturation: Float

    public init(
        mode: CaptureMode,
        burstLength: Int,
        highlightHeadroom: Float,
        pyramidLevels: Int,
        tileSize: Int,
        searchRadius: Int,
        metric: BlockMatchMetric,
        motionRegularization: Float,
        mergeRobustness: Float,
        useFrequencyMerge: Bool,
        superResolutionFactor: Int,
        localToneStrength: Float,
        sharpenAmount: Float,
        saturation: Float
    ) {
        self.mode = mode
        self.burstLength = burstLength
        self.highlightHeadroom = highlightHeadroom
        self.pyramidLevels = pyramidLevels
        self.tileSize = tileSize
        self.searchRadius = searchRadius
        self.metric = metric
        self.motionRegularization = motionRegularization
        self.mergeRobustness = mergeRobustness
        self.useFrequencyMerge = useFrequencyMerge
        self.superResolutionFactor = superResolutionFactor
        self.localToneStrength = localToneStrength
        self.sharpenAmount = sharpenAmount
        self.saturation = saturation
    }

    /// Photo mode: 8-frame ZSL burst, balanced merge, no super-res.
    public static let photo = PipelineConfiguration(
        mode: .photo,
        burstLength: 8,
        highlightHeadroom: 0.8,
        pyramidLevels: 4,
        tileSize: 16,
        searchRadius: 4,
        metric: .l1,
        motionRegularization: 0.1,
        mergeRobustness: 8,
        useFrequencyMerge: true,
        superResolutionFactor: 1,
        localToneStrength: 0.6,
        sharpenAmount: 0.8,
        saturation: 1.2
    )

    /// Night mode: long burst, harder merge, optional 2× super-res.
    public static let night = PipelineConfiguration(
        mode: .night,
        burstLength: 32,
        highlightHeadroom: 0.85,
        pyramidLevels: 4,
        tileSize: 16,
        searchRadius: 4,
        metric: .l1,
        motionRegularization: 0.1,
        mergeRobustness: 12,
        useFrequencyMerge: true,
        superResolutionFactor: 1, // enable 2 to drizzle
        localToneStrength: 0.8,
        sharpenAmount: 0.6,
        saturation: 1.2
    )

    public static func preset(for mode: CaptureMode) -> PipelineConfiguration {
        mode == .night ? .night : .photo
    }
}
