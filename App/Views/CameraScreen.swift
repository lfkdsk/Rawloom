import SwiftUI
import RawloomCore

/// The camera screen. Live viewfinder with a pro-style top toolbar (aspect / format / flash + aids),
/// a lens pill, a Chinese manual-readout row, and a thumbnail · shutter · filters bottom bar. Captures
/// stay snappy — the shutter returns immediately and each burst processes in the background.
struct CameraScreen: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var baseZoom: CGFloat = 1
    @State private var showGallery = false
    @State private var showSettings = false
    @State private var showDebug = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            viewfinder
                .ignoresSafeArea()
                .gesture(
                    MagnificationGesture()
                        .onChanged { viewModel.setZoom(baseZoom * $0) }
                        .onEnded { _ in baseZoom = viewModel.zoom }
                )
            if viewModel.supportsManual { focusLayer.ignoresSafeArea() }
            if viewModel.showGrid { GridOverlay().ignoresSafeArea() }
            if viewModel.showLevel { LevelOverlay(roll: viewModel.rollRadians) }
            AspectMaskOverlay(ratio: viewModel.aspect.portraitRatio).ignoresSafeArea()
            scrims

            VStack(spacing: 8) {
                topRow          // histogram + gear — flanks the Dynamic Island
                chipBar         // sits just below the island, like the reference
                Spacer()
                bottomControls
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .ignoresSafeArea(edges: .top)
        }
        .sheet(isPresented: $showGallery) { GalleryView() }
        .sheet(isPresented: $showSettings) { SettingsSheet(vm: viewModel) }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        // 显影 — the "how it was made" reveal. One cover, presented while a surface is set; the inner
        // switch swaps sequence↔inspector in place (changing a `fullScreenCover(item:)` id mid-present
        // doesn't reliably re-render).
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.revealSurface != nil },
            set: { if !$0 { viewModel.revealSurface = nil } }
        )) {
            Group {
                if viewModel.stages.isEmpty {
                    Ink.ground.ignoresSafeArea().onAppear { viewModel.revealSurface = nil }
                } else if viewModel.revealSurface == .inspector {
                    StageInspectorView(
                        stages: viewModel.stages, orientation: viewModel.resultOrientation,
                        initialStage: viewModel.initialRevealStage,
                        onReplay: { viewModel.revealSurface = .sequence },
                        onClose: { viewModel.revealSurface = nil })
                } else {
                    RevealSequenceView(
                        stages: viewModel.stages, orientation: viewModel.resultOrientation,
                        pinnedStage: viewModel.revealSeqPinned,
                        onFinish: { viewModel.revealSurface = nil },
                        onInspect: { viewModel.revealSurface = .inspector })
                }
            }
        }
    }

    // MARK: Viewfinder

    @ViewBuilder
    private var viewfinder: some View {
        if let session = (viewModel.captureSource as? AVFoundationCaptureSource)?.session {
            CameraPreviewView(session: session)
        } else {
            LinearGradient(colors: [.gray.opacity(0.22), .black], startPoint: .top, endPoint: .bottom)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "camera.aperture").font(.system(size: 46))
                        Text("Tap the shutter to capture").font(.callout)
                    }.foregroundStyle(.white.opacity(0.6))
                )
        }
    }

    private var focusLayer: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { e in
                        viewModel.focusExpose(at: CGPoint(x: e.location.x / geo.size.width,
                                                          y: e.location.y / geo.size.height))
                    })
                if let r = viewModel.focusReticle {
                    FocusReticle().position(x: r.x * geo.size.width, y: r.y * geo.size.height)
                }
            }
        }
    }

    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 300)
        }
        .ignoresSafeArea().allowsHitTesting(false)
    }

    // MARK: Top toolbar

    private var topRow: some View {
        HStack {
            if viewModel.showHistogram {
                HistogramView(bins: viewModel.histogram).frame(width: 96, height: 30)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 17))
                    .foregroundStyle(.white).frame(width: 38, height: 38)
                    .background(.black.opacity(0.4), in: Circle())
            }
        }
    }

    private var chipBar: some View {
        HStack(spacing: 8) {
            chip(viewModel.aspect.rawValue) { viewModel.cycleAspect() }
            formatChip
            iconChip(viewModel.flashMode.icon, active: viewModel.flashMode != .off) { viewModel.cycleFlash() }
            Spacer()
            // 显影: arm per-stage capture for the next shot (opt-in — normal capture stays fast); the
            // play chip re-runs the cinematic reveal of the last reveal capture.
            iconChip("rectangle.stack", active: viewModel.revealMode) { viewModel.revealMode.toggle() }
            if !viewModel.stages.isEmpty {
                iconChip("play.rectangle", active: false) { viewModel.revealSurface = .sequence }
            }
            iconChip("grid", active: viewModel.showGrid) { viewModel.toggleGrid() }
            iconChip("level", active: viewModel.showLevel) { viewModel.toggleLevel() }
            iconChip("chart.bar.xaxis", active: viewModel.showHistogram) { viewModel.toggleHistogram() }
        }
    }

    private var formatChip: some View {
        Menu {
            ForEach(OutputFormat.presets, id: \.rawValue) { fmt in
                Button { viewModel.proRAWMode = false; viewModel.outputFormat = fmt } label: {
                    if !viewModel.proRAWMode, fmt == viewModel.outputFormat { Label(fmt.label, systemImage: "checkmark") }
                    else { Text(fmt.label) }
                }
            }
            if viewModel.proRAWSupported {
                Button { viewModel.proRAWMode = true } label: {
                    if viewModel.proRAWMode { Label("ProRAW", systemImage: "checkmark") } else { Text("ProRAW") }
                }
            }
        } label: {
            Text(viewModel.proRAWMode ? "ProRAW" : viewModel.outputFormat.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(viewModel.proRAWMode ? Color.rawloomAccent : .white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.4), in: Capsule())
        }
    }

    private func chip(_ text: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.rawloomAccent : .white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.4), in: Capsule())
        }
    }

    private func iconChip(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.rawloomAccent : .white)
                .frame(width: 34, height: 34).background(.black.opacity(0.4), in: Circle())
        }
    }

    // MARK: Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 16) {
            if viewModel.maxZoom > 1.01 || viewModel.lenses.count > 1 { lensPill }
            if viewModel.supportsManual { ManualControlPanel(vm: viewModel) }
            statusLine
            shutterBar
        }
    }

    private var lensPill: some View {
        HStack(spacing: 4) {
            ForEach(viewModel.lenses) { lens in
                let active = lens.id == viewModel.selectedLensID
                Button {
                    viewModel.selectLens(lens.id); baseZoom = lens.displayZoom
                } label: {
                    Text(active ? zoomText(viewModel.zoom) : lens.label)
                        .font(.system(size: active ? 13 : 12, weight: .bold))
                        .foregroundStyle(active ? Color.rawloomAccent : .white)
                        .frame(width: active ? 46 : 34, height: active ? 46 : 34)
                        .background(Circle().fill(.black.opacity(active ? 0.55 : 0.0)))
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.black.opacity(0.35), in: Capsule())
    }

    /// "1×" at integer zooms, "1.4×" between.
    private func zoomText(_ z: CGFloat) -> String {
        abs(z - z.rounded()) < 0.05 ? "\(Int(z.rounded()))×" : String(format: "%.1f×", z)
    }

    @ViewBuilder
    private var statusLine: some View {
        Text(viewModel.statusText)
            .font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .onTapGesture { showDebug.toggle() }
        if showDebug, !viewModel.debugText.isEmpty {
            Text(viewModel.debugText).font(.caption2.monospaced()).foregroundStyle(.white)
                .padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var shutterBar: some View {
        HStack {
            thumbnail
            Spacer()
            shutterButton
            Spacer()
            Button { showGallery = true } label: {
                Image(systemName: "camera.filters").font(.system(size: 22))
                    .foregroundStyle(.white).frame(width: 56, height: 56)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var shutterButton: some View {
        Button { Task { await viewModel.shutter() } } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(shutterFill).frame(width: 64, height: 64)
            }
        }
        .disabled(viewModel.isCapturing)
        .opacity(viewModel.isCapturing ? 0.5 : 1)
    }

    private var shutterFill: Color {
        if viewModel.proRAWMode { return Color.rawloomAccent }
        return viewModel.mode == .night ? .indigo : .white
    }

    private var thumbnail: some View {
        ZStack {
            if let result = viewModel.latestResult {
                Image(decorative: result, scale: 1, orientation: viewModel.resultOrientation)
                    .resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1))
            }
            if viewModel.processingCount > 0 {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.45))
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.4)))
        .onTapGesture { showGallery = true }
    }
}

/// Black letterbox bars cropping the preview to the chosen aspect ratio (raw stays full-sensor).
private struct AspectMaskOverlay: View {
    let ratio: CGFloat?
    var body: some View {
        GeometryReader { geo in
            if let ratio {
                let frameH = min(geo.size.height, geo.size.width / ratio)
                let bar = max(0, (geo.size.height - frameH) / 2)
                VStack(spacing: 0) {
                    Color.black.frame(height: bar)
                    Spacer(minLength: 0)
                    Color.black.frame(height: bar)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct FocusReticle: View {
    @State private var scale: CGFloat = 1.35
    @State private var opacity: Double = 0
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.rawloomAccent, lineWidth: 1.5)
            .frame(width: 74, height: 74)
            .scaleEffect(scale).opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { scale = 1; opacity = 1 }
                withAnimation(.easeOut(duration: 0.4).delay(0.9)) { opacity = 0 }
            }
    }
}
