import Foundation

/// Deterministic SplitMix64 PRNG. Used by the synthetic burst generator so that test fixtures and
/// the simulator demo source are perfectly reproducible (no `Date`/`Math.random`-style nondeterminism).
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Float in [0, 1).
    public mutating func nextUniform() -> Float {
        Float(next() >> 40) * (1.0 / 16_777_216.0) // 24-bit mantissa worth of entropy
    }

    /// Standard-normal Float via Box–Muller.
    public mutating func nextGaussian() -> Float {
        let u1 = max(nextUniform(), 1e-7)
        let u2 = nextUniform()
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
    }
}
