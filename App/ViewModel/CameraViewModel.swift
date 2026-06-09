import Foundation
import SwiftUI
import Metal
import CoreGraphics
import CoreImage
import CoreMotion
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
    @Published var latestResult: CGImage?       // newest finished image (thumbnail → gallery)
    @Published var resultOrientation: Image.Orientation = .up
    @Published var debugText = ""
    @Published var lastJPEGURL: URL?
    @Published var lastDNGURL: URL?
    @Published private(set) var usingSyntheticSource = false

    // Lens / zoom / format
    @Published private(set) var lenses: [CameraLens] = []
    @Published var selectedLensID: String?
    @Published var zoom: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 1
    @Published var outputFormat: OutputFormat = .rawAndJpeg
    @Published var proRAWMode = false
    var proRAWSupported: Bool { captureSource.proRAWSupported }
    @Published var flashMode: FlashMode = .off { didSet { captureSource.flashMode = flashMode } }
    @Published var aspect: AspectRatio = .full

    func cycleFlash() {
        let all = FlashMode.allCases
        flashMode = all[((all.firstIndex(of: flashMode) ?? 0) + 1) % all.count]
    }
    func cycleAspect() {
        let all = AspectRatio.allCases
        aspect = all[((all.firstIndex(of: aspect) ?? 0) + 1) % all.count]
    }

    // Manual controls
    @Published private(set) var manualCaps = ManualCapabilities()
    @Published var exposureFocusLocked = false
    @Published var ev: Float = 0
    @Published var iso: Float = 100
    @Published var shutter: Double = 1.0 / 120
    @Published var kelvin: Float = 5200
    @Published var lensPosition: Float = 0.5
    @Published var exposureManual = false
    @Published var wbManual = false
    @Published var focusManual = false
    /// Transient tap-to-focus reticle position (normalised 0…1), shown briefly.
    @Published var focusReticle: CGPoint?
    var supportsManual: Bool { manualCaps.supportsManual }

    // Viewfinder aids
    @Published var showGrid = false
    @Published var showLevel = false
    @Published var showHistogram = false
    @Published var histogram: [Float] = []
    @Published var rollRadians = 0.0
    private let motion = CMMotionManager()

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
        lenses = captureSource.lenses
        selectedLensID = captureSource.selectedLensID
        zoom = captureSource.zoomFactor
        maxZoom = captureSource.maxZoomFactor
        manualCaps = captureSource.manualCapabilities
        iso = manualCaps.currentISO
        shutter = manualCaps.currentShutter
        lensPosition = manualCaps.currentLensPosition
        if usingSyntheticSource { statusText = "Simulator: synthetic capture" }
        // Used by scripts/screenshots.sh to capture a processed result automatically.
        let env = ProcessInfo.processInfo
        if env.arguments.contains("-autoshoot") || env.environment["RAWLOOM_AUTOSHOOT"] != nil {
            await shutter()
        }
    }

    func onDisappear() {
        captureSource.stop()
        stopMotion()
        captureSource.onHistogram = nil
    }

    /// Capture a burst, then return to the viewfinder immediately and process in the background.
    func shutter() async {
        guard !isCapturing else { return }
        if proRAWMode { await captureProRAW(); return }
        guard pipeline != nil else { statusText = "No Metal GPU available"; return }
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

    /// Single Apple ProRAW capture: save the DNG straight to Documents (no merge), thumbnail from it.
    private func captureProRAW() async {
        isCapturing = true
        statusText = "Capturing ProRAW…"
        do {
            let data = try await captureSource.captureProRAW()
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("rawloom_proraw_\(Int(Date().timeIntervalSince1970)).dng")
            try data.write(to: url)
            lastDNGURL = url
            latestResult = Self.thumbnail(fromDNG: data)
            resultOrientation = .up // CIImage applies the DNG's orientation tag
            debugText = "ProRAW DNG · \(data.count / 1_048_576) MB"
            statusText = "Saved ProRAW"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
        isCapturing = false
    }

    private static func thumbnail(fromDNG data: Data) -> CGImage? {
        guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let scale = min(1, 1200 / max(ci.extent.width, ci.extent.height))
        let small = ci.transformed(by: .init(scaleX: scale, y: scale))
        return PhotoEditor.context.createCGImage(small, from: small.extent)
    }

    // MARK: Lens & zoom

    func selectLens(_ id: String) {
        guard id != selectedLensID else { return }
        Task {
            await captureSource.select(lensID: id)
            selectedLensID = captureSource.selectedLensID
            zoom = captureSource.zoomFactor
            maxZoom = captureSource.maxZoomFactor
        }
    }

    func setZoom(_ factor: CGFloat) {
        let minZoom = lenses.map(\.displayZoom).min() ?? 1   // 0.5 when an ultra-wide is present
        let clamped = min(max(factor, minZoom), maxZoom)
        zoom = clamped
        captureSource.setZoom(clamped)
    }

    // MARK: Manual controls

    func focusExpose(at point: CGPoint) {
        focusReticle = point
        exposureManual = false
        captureSource.focusAndExpose(at: point)
        // Hide the reticle after a moment.
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); if focusReticle == point { focusReticle = nil } }
    }

    func toggleAEAFLock() {
        exposureFocusLocked.toggle()
        captureSource.setExposureFocusLocked(exposureFocusLocked)
    }

    func setEV(_ value: Float) {
        ev = value
        captureSource.setExposureBias(value)
    }

    func applyManualExposure() {
        exposureManual = true
        captureSource.setManualExposure(iso: iso, shutter: shutter)
    }

    func resetExposure() {
        exposureManual = false
        ev = 0
        captureSource.resetAutoExposure()
        captureSource.setExposureBias(0)
    }

    func setKelvin(_ k: Float) {
        kelvin = k
        wbManual = true
        captureSource.setManualWhiteBalance(kelvin: k)
    }

    func resetWhiteBalance() {
        wbManual = false
        captureSource.resetAutoWhiteBalance()
    }

    func setLensPosition(_ p: Float) {
        lensPosition = p
        focusManual = true
        captureSource.setManualFocus(p)
    }

    func resetFocus() {
        focusManual = false
        captureSource.resetAutoFocus()
    }

    // MARK: Viewfinder aids

    func toggleGrid() { showGrid.toggle() }

    func toggleHistogram() {
        showHistogram.toggle()
        if showHistogram {
            captureSource.onHistogram = { [weak self] bins in self?.histogram = bins }
        } else {
            captureSource.onHistogram = nil
            histogram = []
        }
    }

    func toggleLevel() {
        showLevel.toggle()
        if showLevel { startMotion() } else { stopMotion() }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            // Roll about the device's long axis → horizon tilt.
            self.rollRadians = atan2(g.x, g.y) - .pi
        }
    }

    private func stopMotion() { motion.stopDeviceMotionUpdates() }

    // MARK: Background processing

    private func enqueueProcessing(frames: [RawFrame], mode: CaptureMode) {
        guard let pipeline else { return }
        processingCount += 1
        statusText = "Processing…"
        let synthetic = usingSyntheticSource
        let format = outputFormat
        processingQueue.async { [weak self] in
            do {
                let processed = try pipeline.process(frames: frames, config: .preset(for: mode))
                let (image, means) = Self.makeCGImage(from: processed.displayImage, context: pipeline.context)
                let debug = Self.debugReadout(processed: processed, outputMeans: means)
                let urls = try? Self.save(processed: processed, context: pipeline.context, format: format)
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

    private static func save(processed: ProcessedImage, context: MetalContext,
                             format: OutputFormat) throws -> (jpeg: URL?, dng: URL?) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = Int(Date().timeIntervalSince1970)
        var jpegURL: URL?
        var dngURL: URL?
        if format.contains(.jpeg) {
            // Ultra HDR (hybrid SDR+HDR gain map) when requested; plain SDR JPEG otherwise. Both are
            // ordinary .jpg files — the Ultra HDR one degrades to its SDR base in non-HDR viewers.
            let jpeg = format.contains(.hdr)
                ? JPEGEncoder.encodeUltraHDR(sdr: processed.displayImage, hdr: processed.hdrImage, context: context)
                : JPEGEncoder.encode(displayTexture: processed.displayImage, context: context)
            if let jpeg {
                let url = dir.appendingPathComponent("rawloom_\(stamp).jpg")
                try jpeg.write(to: url)
                jpegURL = url
            }
        }
        if format.contains(.dng) {
            let dng = DNGWriter.write(mergedBayer: processed.mergedBayer, context: context,
                                      metadata: processed.referenceMetadata,
                                      exposureGain: processed.exposureGain)
            let url = dir.appendingPathComponent("rawloom_\(stamp).dng")
            try dng.write(to: url)
            dngURL = url
        }
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
