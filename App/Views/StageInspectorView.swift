import SwiftUI
import CoreGraphics
import simd
import RawloomCore

/// The "how it was made" inspector (显影). A dark, glassy walk-through of the pipeline: a hero preview
/// of the selected stage (with the alignment motion field / merge ghost-rejection heatmap drawn on
/// top), a drag-to-wipe A/B against the previous stage, and a filmstrip of every stage at the bottom.
///
/// It consumes the `StagePreview`s produced opt-in by `IndigoPipeline.process(captureStages: true)`,
/// so it adds no cost to a normal capture.
struct StageInspectorView: View {
    let stages: [StagePreview]
    let orientation: Image.Orientation
    var onClose: () -> Void
    /// Optional — when set, the top bar shows a ▶ that replays the cinematic reveal.
    var onReplay: (() -> Void)? = nil

    @State private var selectedKind: StagePreview.Kind
    @State private var wipe: CGFloat = 0          // 0 = all selected, 1 = all previous revealed
    @State private var showHeatmap = true
    @Namespace private var filmstrip

    init(stages: [StagePreview], orientation: Image.Orientation,
         initialStage: StagePreview.Kind? = nil,
         onReplay: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        self.stages = stages
        self.orientation = orientation
        self.onReplay = onReplay
        self.onClose = onClose
        let start = initialStage.flatMap { k in stages.first { $0.kind == k }?.kind }
        _selectedKind = State(initialValue: start ?? stages.last?.kind ?? .result)
    }

    private var selected: StagePreview { stages.first { $0.kind == selectedKind } ?? stages[0] }
    private var previous: StagePreview? {
        guard let i = stages.firstIndex(where: { $0.kind == selectedKind }), i > 0 else { return nil }
        return stages[i - 1]
    }

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                hero
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                caption
                filmstripBar
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("显影").font(.inkDisplay(22)).foregroundStyle(Ink.paper)
                Text("How it was made").font(.caption2).foregroundStyle(Ink.muted)
            }
            Spacer()
            HStack(spacing: 8) {
                if let onReplay {
                    Button(action: onReplay) {
                        Label("重放", systemImage: "play.fill").labelStyle(.iconOnly)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Ink.faint)
                            .padding(8)
                            .background(Ink.panel, in: RoundedRectangle(cornerRadius: Ink.radius))
                    }
                    .accessibilityLabel("Replay reveal")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.headline.weight(.semibold))
                        .foregroundStyle(Ink.faint)
                        .padding(8)
                        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Ink.radius))
                }
            }
        }
        .foregroundStyle(Ink.paper)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    // MARK: Hero preview

    private var hero: some View {
        GeometryReader { geo in
            let fit = fittedSize(for: selected.image, in: geo.size)
            ZStack(alignment: .topLeading) {
                // Base: the selected stage, full.
                stageImage(selected.image)
                    .frame(width: fit.width, height: fit.height)

                // Selected-stage overlay (motion field / heatmap), clipped to the un-wiped region.
                overlay(for: selected, size: fit)
                    .frame(width: fit.width, height: fit.height)
                    .mask(splitMask(width: fit.width, leadingFraction: wipe, keepTrailing: true))

                // Previous stage revealed from the left as you drag.
                if let previous {
                    stageImage(previous.image)
                        .frame(width: fit.width, height: fit.height)
                        .mask(splitMask(width: fit.width, leadingFraction: wipe, keepTrailing: false))
                    if wipe > 0.001 { divider(at: fit.width * wipe, height: fit.height) }
                }
            }
            .frame(width: fit.width, height: fit.height)
            .clipShape(RoundedRectangle(cornerRadius: Ink.radius))
            .overlay(RoundedRectangle(cornerRadius: Ink.radius).stroke(Ink.line))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(previous == nil ? nil : wipeGesture(width: fit.width, originX: (geo.size.width - fit.width) / 2))
        }
    }

    private func stageImage(_ img: PreviewImage) -> some View {
        Group {
            if let cg = img.cgImage {
                Image(decorative: cg, scale: 1, orientation: orientation)
                    .resizable().interpolation(.high).scaledToFill()
            } else {
                Color.gray.opacity(0.2)
            }
        }
    }

    @ViewBuilder
    private func overlay(for stage: StagePreview, size: CGSize) -> some View {
        switch stage.overlay {
        case .motionField(let vectors, let cols, let rows, _):
            MotionFieldCanvas(vectors: vectors, cols: cols, rows: rows, orientation: orientation)
        case .heatmap(let map, _):
            if showHeatmap, let cg = map.cgImage {
                // Matte overlay (no screen-blend glow — InkType forbids gloss).
                Image(decorative: cg, scale: 1, orientation: orientation)
                    .resizable().interpolation(.high).scaledToFill()
                    .opacity(0.58)
            }
        case nil:
            EmptyView()
        }
    }

    private func divider(at x: CGFloat, height: CGFloat) -> some View {
        Rectangle().fill(Ink.paper).frame(width: 1.5, height: height)
            .overlay(
                Circle().fill(Ink.paper).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.ground))
                    .position(x: 0.75, y: height / 2)
            )
            .offset(x: x - 0.75)
    }

    private func splitMask(width: CGFloat, leadingFraction: CGFloat, keepTrailing: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(keepTrailing ? Color.clear : Color.black).frame(width: width * leadingFraction)
            Rectangle().fill(keepTrailing ? Color.black : Color.clear)
        }
    }

    private func wipeGesture(width: CGFloat, originX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let local = v.location.x - originX
                wipe = min(max(local / max(width, 1), 0), 1)
            }
    }

    // MARK: Caption

    private var caption: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(selected.title).font(.inkDisplay(17)).foregroundStyle(Ink.paper)
                Text(selected.detail).font(.caption.monospaced()).foregroundStyle(Ink.muted)
                Spacer()
                if case .heatmap(_, _)? = selected.overlay {
                    Toggle(isOn: $showHeatmap) { Text("热力图").font(.caption2) }
                        .toggleStyle(.button).tint(Ink.clay).controlSize(.mini)
                }
            }
            if let previous {
                Text(wipe < 0.02
                     ? "← 拖动画面，对比上一步「\(previous.title)」"
                     : "\(previous.title)  ◁ 拖动 ▷  \(selected.title)")
                    .font(.caption2).foregroundStyle(Ink.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .heatmap(_, let legend)? = selected.overlay, showHeatmap {
                Text(legend).font(.caption2).foregroundStyle(Ink.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(Ink.paper)
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    // MARK: Filmstrip

    private var filmstripBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(stages) { stage in
                        filmstripCell(stage)
                            .id(stage.kind)
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    selectedKind = stage.kind
                                    wipe = 0
                                }
                            }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .onChange(of: selectedKind) { kind in
                withAnimation { proxy.scrollTo(kind, anchor: .center) }
            }
        }
        .background(Ink.panel)
    }

    private func filmstripCell(_ stage: StagePreview) -> some View {
        let isSel = stage.kind == selectedKind
        return VStack(spacing: 5) {
            Group {
                if let cg = stage.image.cgImage {
                    Image(decorative: cg, scale: 1, orientation: orientation)
                        .resizable().scaledToFill()
                } else { Color.gray.opacity(0.2) }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Ink.radius))
            .overlay(RoundedRectangle(cornerRadius: Ink.radius)
                .stroke(isSel ? Ink.clay : Ink.line, lineWidth: isSel ? 2 : 1))
            Text(stage.title)
                .font(.caption2)
                .foregroundStyle(isSel ? Ink.paper : Ink.muted)
        }
        .scaleEffect(isSel ? 1.0 : 0.94)
    }

    // MARK: Geometry

    /// Orientation-corrected display aspect; all stages share the same scene aspect so the wipe aligns.
    private func fittedSize(for img: PreviewImage, in avail: CGSize) -> CGSize {
        let rotated = orientation == .left || orientation == .right
            || orientation == .leftMirrored || orientation == .rightMirrored
        let w = CGFloat(rotated ? img.height : img.width)
        let h = CGFloat(rotated ? img.width : img.height)
        guard w > 0, h > 0, avail.width > 0, avail.height > 0 else { return .zero }
        let scale = min(avail.width / w, avail.height / h)
        return CGSize(width: w * scale, height: h * scale)
    }
}

/// Draws one motion arrow per alignment tile, coloured by displacement magnitude. Tile positions and
/// vectors are transformed by the display `orientation` so the field overlays the (possibly rotated)
/// hero exactly. `progress` (0→1) grows the arrows in for the cinematic reveal.
struct MotionFieldCanvas: View {
    let vectors: [SIMD2<Float>]
    let cols: Int
    let rows: Int
    var orientation: Image.Orientation = .up
    var progress: CGFloat = 1

    /// texture-normalised point → display-normalised point.
    private func mapPoint(_ nx: Double, _ ny: Double) -> (Double, Double) {
        switch orientation {
        case .down, .downMirrored: return (1 - nx, 1 - ny)
        case .left, .leftMirrored: return (ny, 1 - nx)
        case .right, .rightMirrored: return (1 - ny, nx)
        default: return (nx, ny)
        }
    }
    /// vector → display-space vector (same rotation, length preserved).
    private func mapVec(_ vx: Double, _ vy: Double) -> (Double, Double) {
        switch orientation {
        case .down, .downMirrored: return (-vx, -vy)
        case .left, .leftMirrored: return (vy, -vx)
        case .right, .rightMirrored: return (-vy, vx)
        default: return (vx, vy)
        }
    }

    var body: some View {
        Canvas { ctx, size in
            guard cols > 0, rows > 0, vectors.count == cols * rows, progress > 0.01 else { return }
            let maxMag = max(Double(vectors.map { hypot($0.x, $0.y) }.max() ?? 0), 1e-3)
            let rotated = orientation == .left || orientation == .right
                || orientation == .leftMirrored || orientation == .rightMirrored
            let dCols = rotated ? rows : cols, dRows = rotated ? cols : rows
            let arrowCap = 0.42 * min(size.width / CGFloat(dCols), size.height / CGFloat(dRows))
            for r in 0..<rows {
                for c in 0..<cols {
                    let v = vectors[r * cols + c]
                    let mag = hypot(Double(v.x), Double(v.y))
                    let t = mag / maxMag
                    let (px, py) = mapPoint((Double(c) + 0.5) / Double(cols),
                                            (Double(r) + 0.5) / Double(rows))
                    let cx = px * size.width, cy = py * size.height
                    // slate blue (small motion) → clay (large motion), per InkType.
                    let col = Color(red: 0.42 + 0.43 * t, green: 0.55 - 0.08 * t, blue: 0.64 - 0.30 * t)
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - 1.1, y: cy - 1.1, width: 2.2, height: 2.2)),
                             with: .color(col.opacity(0.9 * Double(progress))))
                    guard mag > 1e-3 else { continue }
                    let (dx, dy) = mapVec(Double(v.x) / mag, Double(v.y) / mag)
                    let len = arrowCap * CGFloat(t) * progress
                    let tip = CGPoint(x: cx + dx * len, y: cy + dy * len)
                    var line = Path()
                    line.move(to: CGPoint(x: cx, y: cy)); line.addLine(to: tip)
                    ctx.stroke(line, with: .color(col), lineWidth: 1.4)
                    let ah: CGFloat = 3.2
                    let n = (x: -dy, y: dx)
                    var head = Path()
                    head.move(to: tip)
                    head.addLine(to: CGPoint(x: tip.x - dx * ah + n.x * ah * 0.6,
                                             y: tip.y - dy * ah + n.y * ah * 0.6))
                    head.addLine(to: CGPoint(x: tip.x - dx * ah - n.x * ah * 0.6,
                                             y: tip.y - dy * ah - n.y * ah * 0.6))
                    head.closeSubpath()
                    ctx.fill(head, with: .color(col))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

extension PreviewImage {
    /// Build a `CGImage` from the RGBA8 buffer (alpha ignored — buffers are opaque).
    var cgImage: CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba8) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: cs, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
