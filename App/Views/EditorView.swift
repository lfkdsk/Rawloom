import SwiftUI
import CoreImage
import UniformTypeIdentifiers

/// Non-destructive editor for a saved JPEG: live Core Image adjustments + a 3D `.cube` LUT, saved as a
/// new file. The live preview runs on a downscaled image; Save renders the original at full resolution.
struct EditorView: View {
    let imageURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var adj = PhotoAdjustments()
    @State private var preview: CIImage?
    @State private var rendered: CGImage?
    @State private var importingLUT = false
    @State private var savedURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                imageArea
                controls
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(savedURL == nil ? "Save" : "Saved ✓") { save() }
                        .disabled(adj.isIdentity || savedURL != nil)
                }
            }
            .fileImporter(isPresented: $importingLUT,
                          allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .data]) {
                if case .success(let url) = $0 { loadLUT(url) }
            }
        }
        .preferredColorScheme(.dark)
        .task { preview = PhotoEditor.previewImage(from: imageURL); rerender() }
        .onChange(of: adj) { _ in savedURL = nil; rerender() }
    }

    private var imageArea: some View {
        ZStack {
            if let rendered {
                Image(decorative: rendered, scale: 1).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            adjustmentSlider("Exposure", systemImage: "sun.max", value: $adj.exposure, range: -2...2)
            adjustmentSlider("Contrast", systemImage: "circle.lefthalf.filled", value: $adj.contrast, range: 0.5...1.5)
            adjustmentSlider("Saturation", systemImage: "drop", value: $adj.saturation, range: 0...2)
            adjustmentSlider("Temp", systemImage: "thermometer.medium", value: $adj.temperature, range: 4000...9000)

            HStack {
                Button {
                    importingLUT = true
                } label: {
                    Label(adj.lut?.title ?? "Import LUT", systemImage: "camera.filters")
                        .font(.footnote.bold()).lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                if adj.lut != nil {
                    Button { adj.lut = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Button("Reset") { adj = PhotoAdjustments() }
                    .font(.footnote.bold()).foregroundStyle(.yellow)
                    .disabled(adj.isIdentity)
            }
            .foregroundStyle(.white)
        }
        .padding()
        .background(.black.opacity(0.6))
    }

    private func adjustmentSlider(_ title: String, systemImage: String,
                                  value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 13)).frame(width: 20)
            Text(title).font(.caption2).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).tint(.yellow)
        }
        .foregroundStyle(.white)
    }

    private func rerender() {
        guard let preview else { return }
        rendered = PhotoEditor.renderCGImage(adj, from: preview)
    }

    private func loadLUT(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let lut = CubeLUT.load(from: url) { adj.lut = lut }
    }

    private func save() {
        guard let data = PhotoEditor.renderJPEG(adj, fromFile: imageURL) else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("rawloom_edit_\(Int(Date().timeIntervalSince1970)).jpg")
        if (try? data.write(to: url)) != nil { savedURL = url }
    }
}
