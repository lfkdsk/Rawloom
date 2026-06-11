import Foundation

/// A parsed 3D `.cube` LUT, ready to hand to Core Image's `CIColorCubeWithColorSpace`.
///
/// Both the `.cube` format and Core Image order entries red-fastest, then green, then blue, so the
/// table maps across directly (we just append alpha = 1 to each RGB triple).
struct CubeLUT: Equatable {
    let title: String
    let size: Int
    /// `size³ · 4` little-endian Float32 values (RGBA), red varying fastest.
    let data: Data

    static func == (a: CubeLUT, b: CubeLUT) -> Bool { a.title == b.title && a.size == b.size }

    static func parse(_ text: String, title: String) -> CubeLUT? {
        var size = 0
        var floats: [Float] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last.map(String.init) ?? "") ?? 0
                floats.reserveCapacity(size * size * size * 4)
            } else if upper.hasPrefix("TITLE") || upper.hasPrefix("DOMAIN_")
                       || upper.hasPrefix("LUT_1D_SIZE") {
                continue
            } else {
                let comps = line.split(separator: " ").compactMap { Float($0) }
                if comps.count == 3 { floats.append(contentsOf: [comps[0], comps[1], comps[2], 1]) }
            }
        }
        guard size > 1, floats.count == size * size * size * 4 else { return nil }
        return CubeLUT(title: title, size: size,
                       data: floats.withUnsafeBytes { Data($0) })
    }

    static func load(from url: URL) -> CubeLUT? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, title: url.deletingPathExtension().lastPathComponent)
    }
}
