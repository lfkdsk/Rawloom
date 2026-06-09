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
    private var device: AVCaptureDevice?
    private var configured = false

    /// In-flight burst collector (one capture at a time, awaited sequentially).
    private var pendingContinuation: CheckedContinuation<RawFrame, Error>?

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

    private func configureIfPossible() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }
        self.device = device

        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
        configured = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
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

    func captureBurst(mode: CaptureMode) async throws -> [RawFrame] {
        guard isAvailable, let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first else {
            throw CaptureError.rawUnsupported
        }
        try? configureExposure(mode: mode)
        currentWhiteBalance = readWhiteBalance()

        // NOTE: held at 8 even for Night. The merge currently encodes *all* frames' GPU textures into
        // one command buffer, so memory grows with the burst — 16 frames at 12 MP exhausts memory and
        // the GPU watchdog kills the app ("Night hang"). Raising this needs the incremental merge
        // (commit per frame) — see docs/PIPELINE.md §4. Night still differs via exposure/merge presets.
        let count = 8
        var frames: [RawFrame] = []
        frames.reserveCapacity(count)
        for _ in 0..<count {
            let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            settings.photoQualityPrioritization = .speed
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
        guard let device else { return }
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
