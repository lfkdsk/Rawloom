import SwiftUI

extension Color {
    /// Rawloom's accent — a warm amber/orange, used for active controls and highlights.
    static let rawloomAccent = Color(red: 1.0, green: 0.55, blue: 0.10)
}

extension View {
    /// Standard pill chip background used across the camera chrome.
    func chipBackground() -> some View {
        self.background(.black.opacity(0.45), in: Capsule())
    }
}
