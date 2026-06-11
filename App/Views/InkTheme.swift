import SwiftUI

/// The **InkType** editorial design language Rawloom follows: flat, matte, letterpress restraint —
/// no gradients, no glow, no gloss. Warm "ink on paper", near-sharp corners. Tokens from
/// inktype.lfkdsk.org. Type maps to system serif (Fraunces-like) / mono (JetBrains-like) until the
/// real faces are bundled.
enum Ink {
    // Ink / ground (warm espresso)
    static let ground = rgb(0x14110F)
    static let raised = rgb(0x1A1614)
    static let panel  = rgb(0x211C19)
    static let panel2 = rgb(0x2A241F)
    static let line   = rgb(0x342D27)
    // Paper (cream) + warm neutrals
    static let paper  = rgb(0xEDE4D3)
    static let neutral = rgb(0x5A5147)
    static let muted  = rgb(0x8A7F6F)
    static let faint  = rgb(0xB3A896)
    // Earthy accents
    static let clay       = rgb(0xD97757)
    static let terracotta = rgb(0xC8553D)
    static let ochre      = rgb(0xD4A04A)
    static let sage       = rgb(0x8BA668)
    static let slate      = rgb(0x6B8CA3)

    /// Near-sharp corner radius — letterpress, not skeuomorphic.
    static let radius: CGFloat = 3

    static func rgb(_ hex: Int) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

extension Font {
    /// Fraunces-like serif display (falls back to the system serif until Fraunces is bundled).
    static func inkDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}
