import SwiftUI
import RawloomCore

/// The camera screen: a live viewfinder + Photo/Night mode + shutter. Captures stay snappy — the
/// shutter returns to the viewfinder immediately and each burst processes in the background, landing
/// in the bottom-left thumbnail (with a spinner while it works).
struct CameraScreen: View {
    @StateObject private var viewModel = CameraViewModel()

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            viewfinder.ignoresSafeArea()

            VStack {
                header
                Spacer()
                controls
            }
            .padding()

            if viewModel.showingResult, let result = viewModel.latestResult {
                resultPreview(result)
            }
        }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        // One cover, presented while a surface is set; the inner switch swaps sequence↔inspector in
        // place (changing a `fullScreenCover(item:)` id mid-present doesn't reliably re-render).
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

    // MARK: Viewfinder (always live — results go to the thumbnail, not here)

    @ViewBuilder
    private var viewfinder: some View {
        if let session = (viewModel.captureSource as? AVFoundationCaptureSource)?.session {
            CameraPreviewView(session: session)
        } else {
            Ink.raised
                .overlay(
                    VStack(spacing: 10) {
                        Image(systemName: "camera.aperture").font(.system(size: 46, weight: .light))
                        Text("Tap the shutter to capture").font(.callout)
                    }.foregroundStyle(Ink.muted)
                )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Rawloom").font(.inkDisplay(24)).foregroundStyle(Ink.paper)
            Spacer()
            if viewModel.usingSyntheticSource {
                Label("Synthetic", systemImage: "cpu")
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(Ink.muted)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: Ink.radius))
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 16) {
            Text(viewModel.statusText)
                .font(.footnote.monospaced())
                .foregroundStyle(Ink.faint)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Ink.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: Ink.radius))

            if !viewModel.debugText.isEmpty {
                Text(viewModel.debugText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Ink.faint)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: Ink.radius))
            }

            modeSelector

            revealToggle

            HStack {
                resultThumbnail
                Spacer()
                shutterButton
                Spacer()
                revealEntry // mirrors the thumbnail; opens the last result's stage inspector
            }
        }
    }

    /// InkType Photo/Night selector (custom — flat, near-sharp, clay selection).
    private var modeSelector: some View {
        HStack(spacing: 0) {
            modeButton(.photo, "Photo")
            modeButton(.night, "Night")
        }
        .padding(3)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Ink.radius))
        .overlay(RoundedRectangle(cornerRadius: Ink.radius).stroke(Ink.line))
        .frame(maxWidth: 240)
    }

    private func modeButton(_ mode: CaptureMode, _ title: String) -> some View {
        let on = viewModel.mode == mode
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { viewModel.mode = mode }
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .foregroundStyle(on ? Ink.ground : Ink.faint)
                .background(on ? Ink.clay : Color.clear,
                            in: RoundedRectangle(cornerRadius: max(Ink.radius - 1, 1)))
        }
        .buttonStyle(.plain)
    }

    /// Arms per-stage capture for the next shot. Opt-in: off by default, so normal capture stays fast.
    private var revealToggle: some View {
        Button {
            viewModel.revealMode.toggle()
        } label: {
            Label("显影", systemImage: viewModel.revealMode ? "rectangle.stack.fill" : "rectangle.stack")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(viewModel.revealMode ? Ink.clay : Ink.panel,
                            in: RoundedRectangle(cornerRadius: Ink.radius))
                .foregroundStyle(viewModel.revealMode ? Ink.ground : Ink.paper)
                .overlay(RoundedRectangle(cornerRadius: Ink.radius)
                    .stroke(Ink.line, lineWidth: viewModel.revealMode ? 0 : 1))
        }
        .accessibilityLabel("Reveal pipeline stages")
    }

    /// Bottom-right entry: replays the cinematic reveal of the most recent capture (→ inspector inside).
    @ViewBuilder
    private var revealEntry: some View {
        if !viewModel.stages.isEmpty {
            Button { viewModel.revealSurface = .sequence } label: {
                VStack(spacing: 3) {
                    Image(systemName: "rectangle.stack").font(.system(size: 20))
                    Text("显影").font(.caption2)
                }
                .frame(width: 56, height: 56)
                .foregroundStyle(Ink.paper)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: Ink.radius))
                .overlay(RoundedRectangle(cornerRadius: Ink.radius).stroke(Ink.line))
            }
        } else {
            Color.clear.frame(width: 56, height: 56) // keeps the shutter centred
        }
    }

    private var shutterButton: some View {
        Button {
            Task { await viewModel.shutter() }
        } label: {
            ZStack {
                Circle().strokeBorder(Ink.paper, lineWidth: 4).frame(width: 76, height: 76)
                Circle().fill(viewModel.mode == .night ? Ink.clay : Ink.paper).frame(width: 62, height: 62)
            }
        }
        .disabled(viewModel.isCapturing)
        .opacity(viewModel.isCapturing ? 0.5 : 1)
    }

    /// Bottom-left thumbnail: a spinner while the burst processes in the background, then the finished
    /// image (tap to view full-screen).
    private var resultThumbnail: some View {
        ZStack {
            if let result = viewModel.latestResult {
                Image(decorative: result, scale: 1.0, orientation: viewModel.resultOrientation)
                    .resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: Ink.radius).fill(Ink.panel)
            }
            if viewModel.processingCount > 0 {
                RoundedRectangle(cornerRadius: Ink.radius).fill(Ink.ground.opacity(0.55))
                ProgressView().controlSize(.small).tint(Ink.paper)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: Ink.radius))
        .overlay(RoundedRectangle(cornerRadius: Ink.radius).stroke(Ink.line))
        .overlay(alignment: .topTrailing) {
            if viewModel.processingCount > 1 {
                Text("\(viewModel.processingCount)")
                    .font(.caption2.bold()).foregroundStyle(Ink.ground)
                    .padding(4).background(Circle().fill(Ink.clay)).offset(x: 6, y: -6)
            }
        }
        .onTapGesture { if viewModel.latestResult != nil { viewModel.showingResult = true } }
    }

    private func resultPreview(_ result: CGImage) -> some View {
        ZStack {
            Ink.ground.opacity(0.97).ignoresSafeArea()
            Image(decorative: result, scale: 1.0, orientation: viewModel.resultOrientation)
                .resizable().scaledToFit().ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button { viewModel.showingResult = false } label: {
                        Image(systemName: "xmark").font(.headline.weight(.semibold))
                            .foregroundStyle(Ink.faint).padding(10)
                            .background(Ink.panel, in: RoundedRectangle(cornerRadius: Ink.radius))
                    }.padding()
                }
                Spacer()
            }
        }
        .onTapGesture { viewModel.showingResult = false }
    }
}
