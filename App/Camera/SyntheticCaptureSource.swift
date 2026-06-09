import Foundation
import RawloomCore

/// A `CaptureSource` that synthesises a raw burst with `SyntheticBurstGenerator`. Used in the
/// Simulator (no camera) and in SwiftUI previews, so the entire process-and-display path is
/// exercisable without hardware. It deliberately models Indigo-like capture: underexposed frames,
/// sub-pixel hand tremor, signal-dependent noise — so the merge has real work to do.
final class SyntheticCaptureSource: CaptureSource {
    var isAvailable: Bool { true }

    private var shotCounter: UInt64 = 0

    func start() async {}
    func stop() {}

    func captureBurst(mode: CaptureMode) async throws -> [RawFrame] {
        shotCounter &+= 1
        let scene = SyntheticScene.gradientBlobs(width: 512, height: 512)
        let spec = SyntheticBurstSpec(
            frameCount: mode == .night ? 16 : 8,
            iso: mode == .night ? 3200 : 800,
            tremorSigma: 0.7,
            underexposure: mode == .night ? 0.35 : 0.5,
            addNoise: true,
            seed: 0xC0FFEE &+ shotCounter
        )
        // A little latency so the UI's processing state is visible, like a real capture.
        try? await Task.sleep(nanoseconds: 120_000_000)
        return SyntheticBurstGenerator.generate(scene: scene, spec: spec).frames
    }
}
