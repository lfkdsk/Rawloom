import Foundation
import SwiftUI
import Metal
import CoreGraphics
import RawloomCore

/// Drives the camera screen. A shutter press captures a burst, then hands it to a **serial background
/// queue** for processing — the viewfinder stays live and responsive (you can keep shooting), and each
/// finished frame lands in the bottom-left thumbnail. Processing is serialised so concurrent bursts
/// don't race on the GPU or pile up memory.
@MainActor
final class CameraViewModel: ObservableObject {
    @Published var mode: CaptureMode = .photo
    @Published var isCapturing = false          // shutter→frames in flight (brief); blocks re-shoot
    @Published var processingCount = 0          // background jobs still running
    @Published var statusText = "Ready"
    @Published var latestResult: CGImage?       // newest finished image (thumbnail + tap-to-view)
    @Published var resultOrientation: Image.Orientation = .up
    @Published var showingResult = false        // full-screen view of `latestResult`
    @Published var debugText = ""
    @Published var lastJPEGURL: URL?
    @Published var lastDNGURL: URL?
    @Published private(set) var usingSyntheticSource = false

    let captureSource: CaptureSource
    private let pipeline: IndigoPipeline?
    /// Serialises GPU processing across bursts — one `process()` at a time.
    private let processingQueue = DispatchQueue(label: "com.rawloom.processing", qos: .userInitiated)

    init() {
        captureSource = CaptureSourceFactory.make()
        usingSyntheticSource = captureSource is SyntheticCaptureSource
        pipeline = try? IndigoPipeline()
    }

    func onAppear() async {
        guard pipeline != nil else { statusText = "No Metal GPU available"; return }
        await captureSource.start()
        if usingSyntheticSource { statusText = "Simulator: synthetic capture" }
        // Used by scripts/screenshots.sh to capture a processed result automatically.
        let env = ProcessInfo.processInfo
        if env.arguments.contains("-autoshoot") || env.environment["RAWLOOM_AUTOSHOOT"] != nil {
            await shutter()
        }
    }

    func onDisappear() { captureSource.stop() }

    /// Capture a burst, then return to the viewfinder immediately and process in the background.
    func shutter() async {
        guard pipeline != nil, !isCapturing else { return }
        isCapturing = true
        statusText = mode == .night ? "Capturing night burst…" : "Capturing…"
        let mode = self.mode
        do {
            let frames = try await captureSource.captureBurst(mode: mode)
            isCapturing = false
            enqueueProcessing(frames: frames, mode: mode)
        } catch {
            isCapturing = false
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: Background processing

    private func enqueueProcessing(frames: [RawFrame], mode: CaptureMode) {
        guard let pipeline else { return }
        processingCount += 1
        statusText = "Processing…"
        let synthetic = usingSyntheticSource
        processingQueue.async { [weak self] in
            do {
                let processed = try pipeline.process(frames: frames, config: .preset(for: mode))
                let (image, means) = Self.makeCGImage(from: processed.displayImage, context: pipeline.context)
                let debug = Self.debugReadout(processed: processed, outputMeans: means)
                let urls = try? Self.save(processed: processed, context: pipeline.context)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.latestResult = image
                    self.resultOrientation = synthetic ? .up : .right
                    self.debugText = debug
                    self.lastJPEGURL = urls?.jpeg
                    self.lastDNGURL = urls?.dng
                    self.processingCount -= 1
                    self.statusText = self.processingCount > 0 ? "Processing \(self.processingCount)…" : "Done"
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.processingCount -= 1
                    self.statusText = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Output

    private static func save(processed: ProcessedImage, context: MetalContext) throws -> (jpeg: URL?, dng: URL?) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = Int(Date().timeIntervalSince1970)
        var jpegURL: URL?
        if let jpeg = JPEGEncoder.encode(displayTexture: processed.displayImage, context: context) {
            let url = dir.appendingPathComponent("rawloom_\(stamp).jpg")
            try jpeg.write(to: url)
            jpegURL = url
        }
        let dng = DNGWriter.write(mergedBayer: processed.mergedBayer, context: context,
                                  metadata: processed.referenceMetadata)
        let dngURL = dir.appendingPathComponent("rawloom_\(stamp).dng")
        try dng.write(to: dngURL)
        return (jpegURL, dngURL)
    }

    // MARK: Display

    /// Builds the display `CGImage` and, in the same pass, the mean R/G/B of the finished image.
    static func makeCGImage(from texture: MTLTexture, context: MetalContext) -> (image: CGImage?, means: SIMD3<Double>) {
        let w = texture.width, h = texture.height
        let rgba = context.readRGBA(texture)
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        var sum = SIMD3<Double>(0, 0, 0)
        for i in 0..<(w * h) {
            bytes[i * 4 + 0] = quant(rgba[i * 4 + 0])
            bytes[i * 4 + 1] = quant(rgba[i * 4 + 1])
            bytes[i * 4 + 2] = quant(rgba[i * 4 + 2])
            sum += SIMD3(Double(rgba[i * 4 + 0]), Double(rgba[i * 4 + 1]), Double(rgba[i * 4 + 2]))
        }
        let means = sum / Double(max(w * h, 1))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return (nil, means) }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: w * 4, space: cs, bitmapInfo: info,
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        return (image, means)
    }

    /// One-glance diagnostic for the colour/exposure investigation: the actual black/white levels, CFA,
    /// CCM source and WB gains that were applied, plus the output channel means.
    private static func debugReadout(processed: ProcessedImage, outputMeans m: SIMD3<Double>) -> String {
        let md = processed.referenceMetadata
        let b = md.blackLevel, wb = md.whiteBalance
        let ccm = md.colorMatrix.m == ColorMatrix.identity.m ? "identity" : "matrix"
        return String(format: """
        cfa %@   white %.0f   ccm %@
        black [%.0f %.0f %.0f %.0f]
        wb  R%.2f G%.2f B%.2f
        out R%.2f G%.2f B%.2f
        """, "\(md.cfa)", md.whiteLevel, ccm, b.x, b.y, b.z, b.w,
        wb.red, wb.green, wb.blue, m.x, m.y, m.z)
    }

    private static func quant(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 1) * 255 + 0.5) }
}
