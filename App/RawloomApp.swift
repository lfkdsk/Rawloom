import SwiftUI

@main
struct RawloomApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
