import SwiftUI

@main
struct PhotoVideoEditorApp: App {
    var body: some Scene {
        WindowGroup {
            // `-renderGallery` is the cloud build's test mode (see RenderGallery.swift).
            if RenderGallery.isRequested {
                RenderGalleryView()
            } else {
                EditorView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}
