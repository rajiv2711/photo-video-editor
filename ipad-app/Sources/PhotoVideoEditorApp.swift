import SwiftUI
import UIKit

@main
struct PhotoVideoEditorApp: App {
    var body: some Scene {
        WindowGroup {
            // `-renderGallery` is the cloud build's test mode (see RenderGallery.swift).
            if RenderGallery.isRequested {
                RenderGalleryView()
            } else if UserDefaults.standard.string(forKey: "orientation") == "landscape" {
                // The cloud build's landscape screenshots.
                EditorView()
                    .preferredColorScheme(.dark)
                    .modifier(DemoLandscape())
            } else {
                EditorView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}

/// Launch argument `-orientation landscape` (cloud build screenshots): turns the iPad to landscape. When the
/// system keeps the window upright, the window itself is laid out at landscape size and turned a quarter
/// (so the toolbar and safe areas are laid out as in landscape).
struct DemoLandscape: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in
                Task { @MainActor in Self.turn(scene) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if scene?.interfaceOrientation.isPortrait ?? false { Self.turn(scene) }
            }
        }
    }

    /// Lays the window out at landscape size, turned a quarter (once).
    @MainActor static func turn(_ scene: UIWindowScene?) {
        guard let window = scene?.windows.first, window.transform == .identity else { return }
        let size = window.bounds.size
        guard size.height > size.width else { return }
        window.bounds = CGRect(x: 0, y: 0, width: size.height, height: size.width)
        window.transform = CGAffineTransform(rotationAngle: .pi / 2)
    }
}
