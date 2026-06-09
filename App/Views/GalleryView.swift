import SwiftUI
import ImageIO

/// Browse the JPEGs the app has saved to its Documents folder. Tap one to open the editor.
struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [URL] = []
    @State private var editing: IdentifiableURL?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        NavigationStack {
            Group {
                if urls.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44))
                        Text("No shots yet").font(.callout)
                    }.foregroundStyle(.white.opacity(0.5))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(urls, id: \.self) { url in
                                Button { editing = IdentifiableURL(url: url) } label: { GalleryThumb(url: url) }
                            }
                        }.padding(3)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
        .sheet(item: $editing, onDismiss: load) { EditorView(imageURL: $0.url) }
    }

    private func load() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        urls = files.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { modified($0) > modified($1) }
    }

    private func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

struct IdentifiableURL: Identifiable { let url: URL; var id: URL { url } }

/// A square, downsampled thumbnail loaded off the main thread.
struct GalleryThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .task { image = await Task.detached { Self.thumbnail(url) }.value }
    }

    static func thumbnail(_ url: URL, maxPixel: CGFloat = 240) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
