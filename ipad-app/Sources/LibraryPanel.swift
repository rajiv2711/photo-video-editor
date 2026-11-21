import CommandEngine
import PhotosUI
import SwiftUI

/// The Library panel: import photos (from Photos, Files, or a camera or SD card), the photos the library
/// shows as a grid of thumbnails (tap one to edit it; it comes back with its own edit), and previous /
/// next photo.
struct LibraryPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>

    private var library: Library { model.library }

    var body: some View {
        DisclosureGroup(isExpanded: isOpen("library")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.apply([.run("importPhotos")]) } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                    Button { model.apply([.run("importFiles")]) } label: { Label("Files", systemImage: "folder") }
                    Button { model.apply([.run("importCamera")]) } label: { Label("Card", systemImage: "sdcard") }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .padding(.horizontal, 10)
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 4)], spacing: 4) {
                    ForEach(library.shown) { photo in
                        LibraryThumb(model: model, photo: photo, isCurrent: photo.id == library.current)
                            .onTapGesture { model.openLibraryPhoto(photo.id) }
                    }
                }
                .padding(.horizontal, 10)
                if !library.photos.isEmpty {
                    HStack {
                        Button { model.apply([.run("previousPhoto")]) } label: { Label("Previous", systemImage: "chevron.left") }
                        Spacer()
                        Button { model.apply([.run("nextPhoto")]) } label: { Label("Next", systemImage: "chevron.right") }
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 10)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Library").font(.headline)
        }
    }

    private var status: String {
        let total = library.photos.count, shown = library.shown.count
        if total == 0 { return "No photos yet: import some from Photos, Files or a camera / SD card." }
        let at = library.currentIndex.map { "editing \($0) of \(shown)" } ?? "\(shown) shown"
        return "\(total) photo\(total == 1 ? "" : "s")" + (shown < total ? " · \(shown) shown" : "") + " · " + at
    }

    private func isOpen(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { open in
                if open { expanded.insert(key) } else { expanded.remove(key) }
            }
        )
    }
}

/// One photo of the library's grid: its thumbnail, framed when it is the one being edited.
struct LibraryThumb: View {
    @ObservedObject var model: EditorModel
    let photo: LibraryPhoto
    let isCurrent: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.4)
            if let thumb = model.thumbnail(photo.id) {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(height: 88)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 3))
        .contentShape(Rectangle())
        .accessibilityLabel(photo.name)
    }
}
