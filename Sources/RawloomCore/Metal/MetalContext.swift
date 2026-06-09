import Foundation
import Metal

public enum MetalError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case shaderSourceMissing
    case libraryCompilation(String)
    case functionNotFound(String)
    case textureAllocationFailed
    case encodingFailed

    public var description: String {
        switch self {
        case .noDevice: return "No Metal device is available (headless host or unsupported GPU)."
        case .noCommandQueue: return "Could not create a Metal command queue."
        case .shaderSourceMissing: return "No .metal shader sources were found in the bundle."
        case .libraryCompilation(let m): return "Metal shader compilation failed: \(m)"
        case .functionNotFound(let n): return "Metal function '\(n)' not found in the library."
        case .textureAllocationFailed: return "Failed to allocate a Metal texture."
        case .encodingFailed: return "Failed to create a Metal command/compute encoder."
        }
    }
}

/// Owns the Metal device, command queue, and the runtime-compiled shader library, and hands out
/// cached compute pipeline states by function name.
///
/// The shader library is built by concatenating every `Shaders/*.metal` source shipped in the
/// package bundle and compiling it once with `makeLibrary(source:)` (see ``loadLibrary``). This keeps
/// the package buildable without the offline `metal` compiler and is a valid on-device strategy — the
/// compile happens once at first use and Metal caches the result.
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary

    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let cacheLock = NSLock()

    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw MetalError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalError.noCommandQueue }
        self.device = device
        self.commandQueue = queue
        self.library = try MetalContext.loadLibrary(device: device)
    }

    /// Convenience that returns `nil` instead of throwing when there is no GPU — handy for tests and
    /// for code paths that want to fall back to a CPU implementation.
    public static func makeIfAvailable() -> MetalContext? {
        try? MetalContext()
    }

    // MARK: Pipeline states

    /// Cached compute pipeline state for a kernel function.
    public func pipeline(_ name: String) throws -> MTLComputePipelineState {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = pipelineCache[name] { return cached }
        guard let function = library.makeFunction(name: name) else {
            throw MetalError.functionNotFound(name)
        }
        let state = try device.makeComputePipelineState(function: function)
        pipelineCache[name] = state
        return state
    }

    // MARK: Command buffers

    public func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let cb = commandQueue.makeCommandBuffer() else { throw MetalError.encodingFailed }
        return cb
    }

    /// Encodes one compute pass over a 2-D grid and (optionally) commits + waits.
    public func run(
        _ pipelineName: String,
        gridWidth: Int,
        gridHeight: Int,
        in commandBuffer: MTLCommandBuffer,
        _ configure: (MTLComputeCommandEncoder) -> Void
    ) throws {
        let state = try pipeline(pipelineName)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.encodingFailed
        }
        encoder.setComputePipelineState(state)
        configure(encoder)
        dispatch(encoder, state: state, width: gridWidth, height: gridHeight)
        encoder.endEncoding()
    }

    /// Standard 2-D threadgroup sizing. Kernels must bounds-check against the real image size.
    public func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        state: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let w = state.threadExecutionWidth
        let h = max(1, state.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(
            width: (width + w - 1) / w,
            height: (height + h - 1) / h,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    // MARK: Library loading

    private static func loadLibrary(device: MTLDevice) throws -> MTLLibrary {
        let urls = shaderSourceURLs()
        guard !urls.isEmpty else { throw MetalError.shaderSourceMissing }

        // `Common.metal` defines the shared structs/helpers and MUST be concatenated first; the
        // remaining kernels reference it but not each other, so their order is irrelevant.
        let ordered = urls.sorted { a, b in
            let an = a.lastPathComponent, bn = b.lastPathComponent
            if an.hasPrefix("Common") != bn.hasPrefix("Common") { return an.hasPrefix("Common") }
            return an < bn
        }

        var combined = ""
        for url in ordered {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            combined += "\n// ===== \(url.lastPathComponent) =====\n"
            combined += text
        }
        guard !combined.isEmpty else { throw MetalError.shaderSourceMissing }

        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        do {
            return try device.makeLibrary(source: combined, options: options)
        } catch {
            throw MetalError.libraryCompilation(error.localizedDescription)
        }
    }

    private static func shaderSourceURLs() -> [URL] {
        // Resources are copied under "Shaders/" in the package bundle.
        if let urls = Bundle.module.urls(forResourcesWithExtension: "metal", subdirectory: "Shaders"),
           !urls.isEmpty {
            return urls
        }
        // Fallback: some toolchains flatten the copied directory.
        if let urls = Bundle.module.urls(forResourcesWithExtension: "metal", subdirectory: nil) {
            return urls
        }
        return []
    }
}
