import Foundation
import AVFoundation
import CoreVideo
import os
import RawloomCore

/// Real-device capture: a burst of **underexposed Bayer-raw** frames via `AVCapturePhotoOutput`,
/// converted to `RawFrame`s for the pipeline (`docs/PIPELINE.md` §1).
///
/// Note on ZSL: true negative-shutter-lag needs a continuous raw ring buffer, which AVFoundation does
/// not expose for raw. We approximate it by issuing a tight back-to-back raw burst at a fixed short
/// exposure on shutter press (Night mode uses a longer per-frame exposure and more frames). The
/// `RingBuffer` type is wired for the streaming design when a raw video path is available.
final class AVFoundationCaptureSource: NSObject, CaptureSource {

    private static let log = Logger(subsystem: "com.rawloom", category: "capture")

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.rawloom.capture.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.rawloom.capture.video")
    private var device: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var configured = false

    /// Live luma-histogram sink (preview stream). Set by the UI only while the histogram is shown.
    var onHistogram: (([Float]) -> Void)?
    private var frameCounter = 0
    var flashMode: FlashMode = .off

    /// Discovers the back ultra-wide / wide / tele cameras the device actually has.
    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
        mediaType: .video, position: .back)

    private struct LensInfo { let type: AVCaptureDevice.DeviceType; let rel: CGFloat; let maxZoom: CGFloat }
    private var lensInfos: [LensInfo] = []
    /// Native zoom (relative to the main wide camera) of the *currently selected* physical lens.
    private var currentLensRel: CGFloat = 1
    private var currentDeviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
    private(set) var lenses: [CameraLens] = []
    /// Cap on the displayed (wide-relative) zoom so pinch has a sane top end.
    private let maxDisplayZoom: CGFloat = 15

    /// In-flight burst collector (one capture at a time, awaited sequentially).
    private var pendingContinuation: CheckedContinuation<RawFrame, Error>?
    /// In-flight single ProRAW capture (returns DNG bytes instead of a `RawFrame`).
    private var pendingProRAW: CheckedContinuation<Data, Error>?

    /// As-shot white balance read from the device at the start of the burst, applied in finishing so
    /// real raw doesn't come out green. (CCM is still identity — see docs/PIPELINE.md §6.5.)
    private var currentWhiteBalance: WhiteBalanceGains = .neutral

    /// Real sensor parameters (black/white level, CFA, as-shot neutral) parsed once from a frame's
    /// DNG. Critical: the true black level must be used or real raw comes out magenta.
    private var sensorInfo: SensorRawInfo?

    override init() {
        super.init()
        configureIfPossible()
    }

    var isAvailable: Bool {
        configured && !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
    }

    // MARK: Session

    /// Active preset = whichever zoom preset is nearest the current displayed zoom (so the pill
    /// highlights correctly while pinching).
    var selectedLensID: String? {
        let z = zoomFactor
        return lenses.min(by: { abs($0.displayZoom - z) < abs($1.displayZoom - z) })?.id
    }

    private func configureIfPossible() {
        let devices = discovery.devices
        // Default to the wide camera (the "1×" reference).
        guard let device = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first,
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }
        self.device = device
        self.currentDeviceType = device.deviceType
        self.currentLensRel = 1

        // Each lens's native zoom relative to the wide camera, from its field of view.
        let wideFOV = (devices.first { $0.deviceType == .builtInWideAngleCamera } ?? device).activeFormat.videoFieldOfView
        lensInfos = devices.map { d in
            let rel = d.deviceType == .builtInWideAngleCamera ? 1
                    : Self.relativeZoom(d.activeFormat.videoFieldOfView, wideFOV: wideFOV)
            return LensInfo(type: d.deviceType, rel: rel, maxZoom: min(d.maxAvailableVideoZoomFactor, 30))
        }
        lenses = Self.buildPresets(lensInfos)

        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input); currentInput = input }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = true }
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        }
        session.commitConfiguration()
        configured = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
    }

    /// Native zoom of a lens relative to the wide camera, from horizontal FOV:
    /// `tan(wideFOV/2) / tan(lensFOV/2)` — < 1 for ultra-wide, > 1 for tele.
    private static func relativeZoom(_ lensFOV: Float, wideFOV: Float) -> CGFloat {
        let w = tan(Double(wideFOV) * .pi / 360), l = tan(Double(lensFOV) * .pi / 360)
        return l > 1e-4 ? CGFloat(w / l) : 1
    }

    /// 0.5× / 1× / 2× / 5× presets: for each target pick the widest optical lens whose native zoom is
    /// ≤ the target, then crop digitally on top. Skips targets the hardware can't reach.
    private static func buildPresets(_ infos: [LensInfo]) -> [CameraLens] {
        let targets: [CGFloat] = [0.5, 1, 2, 5]
        return targets.compactMap { t in
            guard let lens = infos.filter({ $0.rel <= t + 0.08 }).max(by: { $0.rel < $1.rel }) else { return nil }
            let vzf = t / lens.rel
            guard vzf >= 0.99, vzf <= lens.maxZoom else { return nil }
            return CameraLens(id: "z\(t)", label: CameraLens.label(displayZoom: t),
                              deviceType: lens.type, videoZoomFactor: vzf, displayZoom: t)
        }
    }

    // MARK: Lens & zoom

    func select(lensID: String) async {
        guard let preset = lenses.first(where: { $0.id == lensID }) else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if preset.deviceType != self.currentDeviceType,
                   let dev = self.discovery.devices.first(where: { $0.deviceType == preset.deviceType }),
                   let input = try? AVCaptureDeviceInput(device: dev) {
                    self.session.beginConfiguration()
                    if let cur = self.currentInput { self.session.removeInput(cur) }
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.currentInput = input
                        self.device = dev
                        self.currentDeviceType = preset.deviceType
                        self.currentLensRel = self.lensInfos.first { $0.type == preset.deviceType }?.rel ?? 1
                        self.sensorInfo = nil       // per-lens sensor params differ — re-parse next frame
                    } else if let cur = self.currentInput {
                        self.session.addInput(cur)  // revert if the lens can't be added
                    }
                    self.session.commitConfiguration()
                }
                self.applyZoom(preset.videoZoomFactor)
                cont.resume()
            }
        }
    }

    /// Displayed zoom = the active lens's native zoom × its digital zoom factor (wide-relative).
    var zoomFactor: CGFloat { (device?.videoZoomFactor ?? 1) * currentLensRel }
    var maxZoomFactor: CGFloat { min((device?.maxAvailableVideoZoomFactor ?? 1) * currentLensRel, maxDisplayZoom) }

    func setZoom(_ displayZoom: CGFloat) {
        sessionQueue.async { self.applyZoom(min(displayZoom, self.maxDisplayZoom) / self.currentLensRel) }
    }

    /// Sets the device's per-lens zoom factor, clamped. Must run on the session queue.
    private func applyZoom(_ factor: CGFloat) {
        guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, min(factor, device.maxAvailableVideoZoomFactor))
        device.unlockForConfiguration()
    }

    // MARK: Manual controls

    /// When true, the burst keeps the user's locked ISO/shutter instead of applying the auto EV bias.
    private var manualExposureActive = false

    /// Runs `body` with the device locked for configuration, on the session queue.
    private func configureDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            body(device)
            device.unlockForConfiguration()
        }
    }

    var manualCapabilities: ManualCapabilities {
        guard let d = device else { return ManualCapabilities() }
        let f = d.activeFormat
        return ManualCapabilities(
            supportsManual: true,
            isoRange: f.minISO...f.maxISO,
            shutterRange: f.minExposureDuration.seconds...f.maxExposureDuration.seconds,
            evRange: d.minExposureTargetBias...d.maxExposureTargetBias,
            kelvinRange: 2800...8000,
            currentISO: d.iso,
            currentShutter: d.exposureDuration.seconds,
            currentLensPosition: d.lensPosition)
    }

    func focusAndExpose(at point: CGPoint) {
        manualExposureActive = false
        configureDevice { d in
            if d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = point
                if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
            }
            if d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = point
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            }
        }
    }

    func setExposureFocusLocked(_ locked: Bool) {
        if !locked { manualExposureActive = false }
        configureDevice { d in
            if locked {
                if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
            } else {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            }
        }
    }

    func setExposureBias(_ ev: Float) {
        configureDevice { d in
            d.setExposureTargetBias(min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias))
        }
    }

    func setManualExposure(iso: Float, shutter: Double) {
        manualExposureActive = true
        configureDevice { d in
            let iso = min(max(iso, d.activeFormat.minISO), d.activeFormat.maxISO)
            let lo = d.activeFormat.minExposureDuration.seconds, hi = d.activeFormat.maxExposureDuration.seconds
            let dur = CMTime(seconds: min(max(shutter, lo), hi), preferredTimescale: 1_000_000)
            d.setExposureModeCustom(duration: dur, iso: iso)
        }
    }

    func resetAutoExposure() {
        manualExposureActive = false
        configureDevice { d in
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        }
    }

    func setManualWhiteBalance(kelvin: Float) {
        configureDevice { d in
            guard d.isWhiteBalanceModeSupported(.locked) else { return }
            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
            var g = d.deviceWhiteBalanceGains(for: tt)
            let maxG = d.maxWhiteBalanceGain
            g.redGain = min(max(g.redGain, 1), maxG)
            g.greenGain = min(max(g.greenGain, 1), maxG)
            g.blueGain = min(max(g.blueGain, 1), maxG)
            d.setWhiteBalanceModeLocked(with: g)
        }
    }

    func resetAutoWhiteBalance() {
        configureDevice { d in
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                d.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    func setManualFocus(_ lensPosition: Float) {
        configureDevice { d in
            guard d.isFocusModeSupported(.locked) else { return }
            d.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1))
        }
    }

    func resetAutoFocus() {
        configureDevice { d in
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        }
    }

    func start() async {
        // Request permission *before* starting. Letting `startRunning` implicitly prompt is what
        // leaves the first-launch viewfinder black (the session runs but delivers no frames until the
        // user grants access, and doesn't reliably kick afterwards).
        let granted = await Self.ensureCameraAccess()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if granted, self.configured, !self.session.isRunning { self.session.startRunning() }
                cont.resume()
            }
        }
    }

    private static func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    // MARK: Burst capture

    var proRAWSupported: Bool { photoOutput.isAppleProRAWSupported }

    /// Capture a single Apple ProRAW frame and return its DNG bytes (no burst, no merge).
    func captureProRAW() async throws -> Data {
        guard let fmt = photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
            AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
        }) else { throw CaptureError.rawUnsupported }
        return try await withCheckedThrowingContinuation { cont in
            self.pendingProRAW = cont
            let settings = AVCapturePhotoSettings(rawPixelFormatType: fmt)
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func captureBurst(mode: CaptureMode) async throws -> [RawFrame] {
        // Use a *Bayer* raw format for the merge even when ProRAW is enabled on the output.
        guard isAvailable, let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
            !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
        }) else {
            throw CaptureError.rawUnsupported
        }
        try? configureExposure(mode: mode)
        currentWhiteBalance = readWhiteBalance()

        // The merge now commits one command buffer per frame (bounded memory), so Night can use a long
        // burst again without OOM / GPU-watchdog kills. See Merger.merge.
        let count = mode == .night ? 16 : 8
        var frames: [RawFrame] = []
        frames.reserveCapacity(count)
        for _ in 0..<count {
            let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            settings.photoQualityPrioritization = .speed
            let flash = flashMode.avFlashMode
            if photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }
            let frame = try await withCheckedThrowingContinuation { cont in
                self.pendingContinuation = cont
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
            frames.append(frame)
        }
        return frames
    }

    /// Underexpose to protect highlights (Indigo's capture strategy). We bias exposure down rather
    /// than hard-coding an EV; metering picks the rest.
    private func configureExposure(mode: CaptureMode) throws {
        guard let device, !manualExposureActive else { return } // honour the user's locked exposure
        try device.lockForConfiguration()
        let bias: Float = mode == .night ? -0.5 : -1.0
        let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
        device.setExposureTargetBias(clamped)
        device.unlockForConfiguration()
    }

    /// The current device AWB gains, normalised to green = 1 (the form finishing expects).
    private func readWhiteBalance() -> WhiteBalanceGains {
        guard let device else { return .neutral }
        let g = device.deviceWhiteBalanceGains
        guard g.greenGain > 0, g.redGain > 0, g.blueGain > 0 else { return .neutral }
        return WhiteBalanceGains(red: g.redGain / g.greenGain, green: 1, blue: g.blueGain / g.greenGain)
    }
}

extension AVFoundationCaptureSource: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // Single ProRAW capture: hand back the DNG bytes directly.
        if let proRAW = pendingProRAW {
            pendingProRAW = nil
            if let error { proRAW.resume(throwing: CaptureError.captureFailed(error.localizedDescription)) }
            else if let data = photo.fileDataRepresentation() { proRAW.resume(returning: data) }
            else { proRAW.resume(throwing: CaptureError.captureFailed("no ProRAW data")) }
            return
        }
        guard let cont = pendingContinuation else { return }
        pendingContinuation = nil
        if let error { cont.resume(throwing: CaptureError.captureFailed(error.localizedDescription)); return }
        // Parse the real sensor parameters once from the frame's own DNG (black level etc.). Log the
        // outcome: a nil DNG or a nil/zero-black parse is the path that ends in a pink cast.
        let firstFrame = sensorInfo == nil
        if firstFrame {
            let dng = photo.fileDataRepresentation()
            let info = dng.flatMap(DNGMetadata.parse)
            sensorInfo = info
            let bytes = dng?.count ?? -1
            let parsed = info != nil ? "yes" : "NO"
            let black = info.map { "[\($0.blackLevel.x),\($0.blackLevel.y),\($0.blackLevel.z),\($0.blackLevel.w)]" } ?? "nil"
            let white = info?.whiteLevel ?? -1
            let cfa = info?.cfa.map { String(describing: $0) } ?? "nil"
            Self.log.log("""
            DNG metadata: bytes=\(bytes, privacy: .public) parsed=\(parsed, privacy: .public) \
            black=\(black, privacy: .public) white=\(white, privacy: .public) cfa=\(cfa, privacy: .public)
            """)
        }
        if let frame = RawPhotoConverter.convert(photo, whiteBalance: currentWhiteBalance,
                                                 sensor: sensorInfo, diagnostics: firstFrame) {
            cont.resume(returning: frame)
        } else {
            cont.resume(throwing: CaptureError.captureFailed("could not read raw pixel buffer"))
        }
    }
}

private extension FlashMode {
    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self { case .auto: return .auto; case .on: return .on; case .off: return .off }
    }
}

// MARK: - Live histogram from the preview stream

extension AVFoundationCaptureSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard onHistogram != nil else { return }      // only sample while the histogram is shown
        frameCounter &+= 1
        guard frameCounter % 5 == 0,                   // ~throttle to a few Hz
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let bins = Self.lumaHistogram(pixels)
        DispatchQueue.main.async { self.onHistogram?(bins) }
    }

    /// 64-bin luma histogram of a BGRA pixel buffer, subsampled and normalised to the tallest bin.
    private static func lumaHistogram(_ pixels: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return [] }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var bins = [Float](repeating: 0, count: 64)
        let step = 4 // sample every 4th pixel/row
        var y = 0
        while y < h {
            let row = ptr + y * stride
            var x = 0
            while x < w {
                let p = row + x * 4                    // BGRA
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                let luma = (r * 54 + g * 183 + b * 19) >> 8   // ~Rec.709
                bins[min(63, luma >> 2)] += 1
                x += step
            }
            y += step
        }
        let peak = max(bins.max() ?? 1, 1)
        return bins.map { $0 / peak }
    }
}
