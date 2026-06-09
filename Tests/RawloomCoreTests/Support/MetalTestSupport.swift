import XCTest
import Metal
@testable import RawloomCore

/// Returns a `MetalContext`, or throws `XCTSkip` when the host has no GPU (e.g. a Command-Line-Tools
/// macOS CI box). On the iOS Simulator (Apple Silicon) and on device this returns a real context, so
/// the GPU tests run there. Run them with `make test-sim`.
func requireMetal() throws -> MetalContext {
    guard let context = MetalContext.makeIfAvailable() else {
        throw XCTSkip("No Metal device on this host — run the GPU tests on the iOS Simulator (make test-sim).")
    }
    return context
}

extension MetalContext {
    /// Runs a single-output ingest+readback synchronously: normalise `frame` and return the
    /// row-major float image. Convenience for tests.
    func ingestAndRead(_ frame: RawFrame) throws -> [Float] {
        let cb = try makeCommandBuffer()
        let tex = try RawIngest.normalize(frame, context: self, in: cb)
        cb.commit()
        cb.waitUntilCompleted()
        return readFloats(tex)
    }
}
