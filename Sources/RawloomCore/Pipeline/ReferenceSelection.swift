import Foundation

/// Picks the burst's reference frame. Per HDR+/Indigo (`docs/PIPELINE.md` §2): consider only the
/// first few frames (closest to the shutter intent / freshest from the ZSL ring) and choose the
/// *sharpest* — sharper frames are less likely to carry motion blur and merge better.
public enum ReferenceSelector {

    /// Index of the chosen reference within `frames`.
    /// - Parameter candidatePool: how many leading frames to consider (HDR+ uses ~3).
    public static func selectIndex(from frames: [RawFrame], candidatePool: Int = 3) -> Int {
        precondition(!frames.isEmpty, "cannot select a reference from an empty burst")
        let pool = min(max(candidatePool, 1), frames.count)
        var bestIndex = 0
        var bestScore = -Double.infinity
        for i in 0..<pool {
            let score = frames[i].greenSharpness()
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        return bestIndex
    }
}
