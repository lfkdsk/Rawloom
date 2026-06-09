import SwiftUI
import RawloomCore

/// The camera screen: a live viewfinder + Photo/Night mode + shutter. Captures stay snappy — the
/// shutter returns to the viewfinder immediately and each burst processes in the background, landing
/// in the bottom-left thumbnail (with a spinner while it works).
struct CameraScreen: View {
    @StateObject private var viewModel = CameraViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
    }

    // MARK: Viewfinder (always live — results go to the thumbnail, not here)

    @ViewBuilder
    private var viewfinder: some View {
        if let session = (viewModel.captureSource as? AVFoundationCaptureSource)?.session {
            CameraPreviewView(session: session)
        } else {
            LinearGradient(colors: [.gray.opacity(0.25), .black], startPoint: .top, endPoint: .bottom)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "camera.aperture").font(.system(size: 48))
                        Text("Tap the shutter to capture").font(.callout)
                    }.foregroundStyle(.white.opacity(0.7))
                )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Rawloom").font(.title2.bold()).foregroundStyle(.white)
            Spacer()
            if viewModel.usingSyntheticSource {
                Label("Synthetic", systemImage: "cpu")
                    .font(.caption).padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 16) {
            Text(viewModel.statusText)
                .font(.footnote.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.35), in: Capsule())

            if !viewModel.debugText.isEmpty {
                Text(viewModel.debugText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            Picker("Mode", selection: $viewModel.mode) {
                Text("Photo").tag(CaptureModeTag.photo.mode)
                Text("Night").tag(CaptureModeTag.night.mode)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            HStack {
                resultThumbnail
                Spacer()
                shutterButton
                Spacer()
                Color.clear.frame(width: 56, height: 56) // keeps the shutter centred
            }
        }
    }

    private var shutterButton: some View {
        Button {
            Task { await viewModel.shutter() }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                Circle().fill(viewModel.mode == .night ? Color.indigo : .white).frame(width: 62, height: 62)
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
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1))
            }
            if viewModel.processingCount > 0 {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.45))
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.5)))
        .overlay(alignment: .topTrailing) {
            if viewModel.processingCount > 1 {
                Text("\(viewModel.processingCount)")
                    .font(.caption2.bold()).foregroundStyle(.white)
                    .padding(4).background(Circle().fill(.indigo)).offset(x: 6, y: -6)
            }
        }
        .onTapGesture { if viewModel.latestResult != nil { viewModel.showingResult = true } }
    }

    private func resultPreview(_ result: CGImage) -> some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
            Image(decorative: result, scale: 1.0, orientation: viewModel.resultOrientation)
                .resizable().scaledToFit().ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button { viewModel.showingResult = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white)
                    }.padding()
                }
                Spacer()
            }
        }
        .onTapGesture { viewModel.showingResult = false }
    }
}

/// Tiny helper so the segmented picker tags are unambiguous `CaptureMode` values.
private enum CaptureModeTag {
    case photo, night
    var mode: CaptureMode {
        switch self {
        case .photo: return .photo
        case .night: return .night
        }
    }
}
