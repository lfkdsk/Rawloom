import Photos

/// Saves finished captures to the system Photos library (camera roll), requesting add-only access the
/// first time. A capture's JPEG is the viewable asset; on the ProRAW path the DNG is saved instead.
enum PhotoLibrary {
    static func save(jpeg jpegURL: URL?, dng dngURL: URL?) {
        // Prefer the JPEG as the camera-roll asset; fall back to the DNG (e.g. ProRAW, JPEG disabled).
        let primary = jpegURL ?? dngURL
        guard let url = primary else { return }
        let resource: PHAssetResourceType = (jpegURL != nil) ? .photo : .photo

        func commit() {
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: resource, fileURL: url, options: nil)
                // Attach the computed-raw DNG as the raw alternate so "RAW+JPEG" lands as one asset.
                if jpegURL != nil, let dngURL {
                    req.addResource(with: .alternatePhoto, fileURL: dngURL, options: nil)
                }
            } completionHandler: { _, _ in }
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            commit()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited { commit() }
            }
        default:
            break
        }
    }
}
