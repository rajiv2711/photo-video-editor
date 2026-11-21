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
/// system keeps the window upright, the editor is laid out at landscape size and drawn turned instead.
struct DemoLandscape: ViewModifier {
    @State private var turned = false

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .frame(width: turned ? geo.size.height : geo.size.width, height: turned ? geo.size.width : geo.size.height)
                .rotationEffect(.degrees(turned ? 90 : 0))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in
                Task { @MainActor in turned = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if scene?.interfaceOrientation.isPortrait ?? true { turned = true }
            }
        }
    }
}
