import SwiftUI
import RawloomCore

/// The cinematic "显影" reveal: after an opt-in capture, the finished photo is shown *developing*
/// through every pipeline stage — capture → reference → align → merge → demosaic → colour → result —
/// as one image resolving, not a slideshow. Each step cross-dissolves into the next; the alignment
/// motion field draws itself in, the merge ghost-rejection heatmap breathes in then settles. At the
/// end you can dismiss or open the inspector to scrub the stages by hand.
///
/// Styled to [[InkType]]: warm-espresso ground, cream serif captions, clay/slate accents, flat & matte.
struct RevealSequenceView: View {
    let stages: [StagePreview]
    let orientation: Image.Orientation
    /// When set, the sequence opens parked on this stage with no auto-advance (deterministic capture).
    var pinnedStage: StagePreview.Kind?
    var onFinish: () -> Void
    var onInspect: () -> Void

    @State private var index: Int
    @State private var finished: Bool
    @State private var motionProgress: CGFloat = 0   // align arrows grow-in
    @State private var heatOpacity: Double = 0       // merge heatmap fade-in
    @State private var runID = 0                      // bump to replay the sequence from the start

    init(stages: [StagePreview], orientation: Image.Orientation,
         pinnedStage: StagePreview.Kind? = nil,
         onFinish: @escaping () -> Void, onInspect: @escaping () -> Void) {
        self.stages = stages
        self.orientation = orientation
        self.pinnedStage = pinnedStage
        self.onFinish = onFinish
        self.onInspect = onInspect
        let start = pinnedStage.flatMap { k in stages.firstIndex { $0.kind == k } } ?? 0
        _index = State(initialValue: start)
        _finished = State(initialValue: pinnedStage != nil)
    }

    private var current: StagePreview { stages[min(index, stages.count - 1)] }

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                hero
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity)
                caption
                controls
            }
        }
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .onTapGesture { if !finished { skipToEnd() } }
        .task(id: runID) { await play() }   // re-runs whenever `runID` bumps → replay
    }

    // MARK: Header — wordmark + a progress track that fills as it develops

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("显影").font(.inkDisplay(20)).foregroundStyle(Ink.paper)
                Spacer()
                Text("\(index + 1) / \(stages.count)")
                    .font(.caption2.monospaced()).foregroundStyle(Ink.muted)
            }
            HStack(spacing: 4) {
                ForEach(stages.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i <= index ? Ink.clay : Ink.line)
                        .frame(height: 3)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 10)
    }

    // MARK: Hero — the developing image + per-stage overlay

    private var hero: some View {
        GeometryReader { geo in
            let fit = fittedSize(for: current.image, in: geo.size)
            ZStack {
                stageImage(current.image)
                    .frame(width: fit.width, height: fit.height)
                    .id(index)   // changing id → cross-dissolve between stages
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
                currentOverlay
                    .frame(width: fit.width, height: fit.height)
            }
            .frame(width: fit.width, height: fit.height)
            .clipShape(RoundedRectangle(cornerRadius: Ink.radius))
            .overlay(RoundedRectangle(cornerRadius: Ink.radius).stroke(Ink.line))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stageImage(_ img: PreviewImage) -> some View {
        Group {
            if let cg = img.cgImage {
                Image(decorative: cg, scale: 1, orientation: orientation)
                    .resizable().interpolation(.high).scaledToFill()
            } else { Ink.panel }
        }
    }

    @ViewBuilder
    private var currentOverlay: some View {
        switch current.overlay {
        case .motionField(let vectors, let cols, let rows, _):
            MotionFieldCanvas(vectors: vectors, cols: cols, rows: rows,
                              orientation: orientation, progress: motionProgress)
        case .heatmap(let map, _):
            if let cg = map.cgImage {
                Image(decorative: cg, scale: 1, orientation: orientation)
                    .resizable().interpolation(.high).scaledToFill()
                    .opacity(heatOpacity)
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: Caption

    private var caption: some View {
        VStack(spacing: 4) {
            Text(current.title).font(.inkDisplay(19)).foregroundStyle(Ink.paper)
                .id("t\(index)").transition(.opacity)
            Text(current.detail).font(.caption.monospaced()).foregroundStyle(Ink.muted)
                .id("d\(index)").transition(.opacity)
            if case .heatmap(_, let legend)? = current.overlay {
                Text(legend).font(.caption2).foregroundStyle(Ink.faint).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.4), value: index)
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            if finished {
                Button(action: replay) {
                    Label("重放", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .foregroundStyle(Ink.paper)
                        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Ink.radius))
                        .overlay(RoundedRectangle(cornerRadius: Ink.radius).stroke(Ink.line))
                }
                Button(action: onInspect) {
                    Label("查看细节", systemImage: "rectangle.stack")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .foregroundStyle(Ink.paper)
                        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Ink.radius))
                        .overlay(RoundedRectangle(cornerRadius: Ink.radius).stroke(Ink.line))
                }
                Spacer()
                Button(action: onFinish) {
                    Text("完成").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .foregroundStyle(Ink.ground)
                        .background(Ink.clay, in: RoundedRectangle(cornerRadius: Ink.radius))
                }
            } else {
                Spacer()
                Button(action: skipToEnd) {
                    Text("跳过").font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .foregroundStyle(Ink.muted)
                        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Ink.radius))
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 4)
        .animation(.easeInOut(duration: 0.3), value: finished)
    }

    /// Restart the cinematic reveal from the first stage (same view instance — no rebuild).
    private func replay() {
        withAnimation(.easeInOut(duration: 0.4)) { index = 0; finished = false }
        motionProgress = 0; heatOpacity = 0
        runID += 1   // re-triggers .task(id:) → play() from the top
    }

    // MARK: Playback

    private func play() async {
        if pinnedStage != nil {                       // parked for screenshots — show overlays settled
            motionProgress = 1; heatOpacity = 0.58
            return
        }
        animateOverlay(for: current.kind)
        while index < stages.count - 1 {
            try? await Task.sleep(nanoseconds: duration(for: current.kind))
            if finished || Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.55)) { index += 1 }
            animateOverlay(for: current.kind)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if !finished { withAnimation(.easeInOut(duration: 0.3)) { finished = true } }
    }

    /// Reset then animate this stage's overlay into view.
    private func animateOverlay(for kind: StagePreview.Kind) {
        motionProgress = 0; heatOpacity = 0
        if kind == .align { withAnimation(.easeOut(duration: 0.7)) { motionProgress = 1 } }
        if kind == .merge { withAnimation(.easeIn(duration: 0.7)) { heatOpacity = 0.58 } }
    }

    private func skipToEnd() {
        withAnimation(.easeInOut(duration: 0.4)) {
            index = stages.count - 1
            finished = true
        }
        animateOverlay(for: current.kind)
    }

    private func duration(for kind: StagePreview.Kind) -> UInt64 {
        switch kind {
        case .align: return 1_400_000_000
        case .merge: return 1_600_000_000
        case .demosaic, .color: return 1_100_000_000
        default: return 1_000_000_000
        }
    }

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
