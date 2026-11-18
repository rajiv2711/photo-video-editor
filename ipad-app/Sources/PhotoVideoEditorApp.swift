import SwiftUI

@main
struct PhotoVideoEditorApp: App {
    var body: some Scene {
        WindowGroup {
            EditorView()
                .preferredColorScheme(.dark)
        }
    }
}
