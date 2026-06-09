import SwiftUI

/// Rule-of-thirds grid.
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.32), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Electronic level: a center bar that rotates with the device roll and snaps green when level.
struct LevelOverlay: View {
    let roll: Double
    private var isLevel: Bool { abs(roll) < 0.025 }
    var body: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.25)).frame(width: 180, height: 1)      // reference
            Rectangle().fill(isLevel ? .green : .yellow).frame(width: 120, height: 1.5)
                .rotationEffect(.radians(roll))
            if isLevel { Circle().fill(.green).frame(width: 5, height: 5) }
        }
        .animation(.easeOut(duration: 0.1), value: isLevel)
        .allowsHitTesting(false)
    }
}

/// Live luma histogram (64 bins, normalised to the tallest bin). Shadow-clipping bins are tinted blue
/// and highlight-clipping bins red so blown highlights / crushed shadows are obvious at a glance.
struct HistogramView: View {
    let bins: [Float]
    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(bins.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(color(for: i))
                    .frame(height: max(1, CGFloat(bins[i]) * 40))
            }
        }
        .frame(width: 132, height: 40, alignment: .bottom)
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }

    private func color(for bin: Int) -> Color {
        if bin <= 1 { return .blue.opacity(0.9) }       // crushed shadows
        if bin >= 62 { return .red.opacity(0.9) }       // clipped highlights
        return .white.opacity(0.85)
    }
}
