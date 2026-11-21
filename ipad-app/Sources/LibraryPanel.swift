import CommandEngine
import PhotosUI
import SwiftUI

/// The Library panel: import photos (from Photos, Files, or a camera or SD card), the photos the library
/// shows as a grid of thumbnails (tap one to edit it; it comes back with its own edit), previous / next
/// photo, the stars, flag and colour label of the photo being edited, and the filter.
struct LibraryPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var expanded: Set<String>
    @State private var albumName = ""
    @State private var keyword = ""

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
                if !library.photos.isEmpty {
                    filterRow.padding(.horizontal, 10)
                }
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
                if let photo = library.photo(library.current) {
                    rateRow(photo).padding(.horizontal, 10)
                }
                DisclosureGroup(isExpanded: isOpen("library/Albums")) {
                    albumsSection
                } label: {
                    Text("Albums").font(.subheadline.weight(.semibold))
                }
                if let photo = library.photo(library.current) {
                    DisclosureGroup(isExpanded: isOpen("library/Info")) {
                        infoSection(photo)
                    } label: {
                        Text("Keywords & info").font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Library").font(.headline)
        }
    }

    /// Stars (tap the one it has again for none), pick / reject, and the colour labels, for the photo being edited.
    private func rateRow(_ photo: LibraryPhoto) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { n in
                    Button { model.apply([.run("rate", value: Double(photo.rating == n ? 0 : n))]) } label: {
                        Image(systemName: n <= photo.rating ? "star.fill" : "star")
                    }
                }
                Spacer()
                Button { model.apply([.run(photo.flag == 1 ? "unflag" : "pick")]) } label: {
                    Image(systemName: photo.flag == 1 ? "flag.fill" : "flag")
                }
                .tint(.green)
                Button { model.apply([.run(photo.flag == -1 ? "unflag" : "reject")]) } label: {
                    Image(systemName: photo.flag == -1 ? "xmark.circle.fill" : "xmark.circle")
                }
                .tint(.red)
            }
            .buttonStyle(.borderless)
            HStack(spacing: 6) {
                ForEach(Array(Library.labels.enumerated()), id: \.offset) { item in
                    Button {
                        // Tapping the label it has takes it off.
                        model.apply([.run("colorLabel", value: Double(photo.label == item.element ? Library.labels.count : item.offset))])
                    } label: {
                        Circle()
                            .fill(LibraryThumb.color(item.element))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.primary, lineWidth: photo.label == item.element ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Label " + item.element)
                }
            }
        }
    }

    /// The albums: tap one to show it (again: all photos), a long press adds the photo being edited to it,
    /// takes it out or deletes the album; a new album starts with the photo being edited.
    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("New album name", text: $albumName)
                    .textFieldStyle(.roundedBorder)
                Button("New") {
                    model.apply([.run("newAlbum", text: albumName.trimmingCharacters(in: .whitespaces))])
                    albumName = ""
                }
                .buttonStyle(.bordered)
            }
            ForEach(library.albums, id: \.name) { album in
                let showing = library.filter.album == album.name
                let has = library.current.map { album.photos.contains($0) } ?? false
                Button {
                    model.apply([showing ? Command.run("showAllPhotos") : Command.run("album", text: album.name)])
                } label: {
                    HStack {
                        Image(systemName: showing ? "rectangle.stack.fill" : "rectangle.stack")
                        Text(album.name)
                        Spacer()
                        if has { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        Text("\(album.photos.count)").foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    if has {
                        Button("Take this photo out") { model.apply([.run("removeFromAlbum", text: album.name)]) }
                    } else {
                        Button("Add this photo") { model.apply([.run("addToAlbum", text: album.name)]) }
                    }
                    Button("Delete album", role: .destructive) { model.apply([.run("deleteAlbum", text: album.name)]) }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    /// The photo being edited: its camera data, title, caption, copyright and keywords (tap one to take it
    /// off), and whether exports leave out where it was taken.
    private func infoSection(_ photo: LibraryPhoto) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.photoInfo)
                .font(.footnote)
                .foregroundStyle(.secondary)
            MetadataField(title: "Title", value: photo.title) { model.apply([.run("photoTitle", text: $0.isEmpty ? "none" : $0)]) }
            MetadataField(title: "Caption", value: photo.caption) { model.apply([.run("photoCaption", text: $0.isEmpty ? "none" : $0)]) }
            MetadataField(title: "Copyright", value: photo.copyright) { model.apply([.run("photoCopyright", text: $0.isEmpty ? "none" : $0)]) }
            HStack {
                TextField("Add keywords (comma between)", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addKeyword)
                Button("Add", action: addKeyword).buttonStyle(.bordered)
            }
            if !photo.keywords.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(photo.keywords, id: \.self) { word in
                            Button { model.apply([.run("removeKeyword", text: word)]) } label: {
                                Label(word, systemImage: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }
            }
            if let strip = model.registry.control(id: "removeLocation") {
                ControlRow(model: model, control: strip)
            }
        }
        .padding(.horizontal, 10)
    }

    private func addKeyword() {
        let words = keyword.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        model.apply([.run("addKeyword", text: words)])
        keyword = ""
    }

    /// The filter: at least N stars, a flag, a colour label; Clear shows every photo.
    private var filterRow: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(0...5, id: \.self) { n in
                    Button(n == 0 ? "Any rating" : "\(n)+ stars") { model.apply([.run("showRating", value: Double(n))]) }
                }
            } label: {
                Label(library.filter.minRating == 0 ? "Stars" : "\(library.filter.minRating)+", systemImage: "star")
            }
            Menu {
                Button("Picks") { model.apply([.run("showPicks")]) }
                Button("Rejected") { model.apply([.run("showRejects")]) }
                Button("Unflagged") { model.apply([.run("showUnflagged")]) }
            } label: {
                Label(library.filter.flag == "all" ? "Flag" : library.filter.flag.capitalized, systemImage: "flag")
            }
            Menu {
                ForEach(Array(Library.labels.enumerated()), id: \.offset) { item in
                    Button(item.element.capitalized) { model.apply([.run("showLabel", value: Double(item.offset))]) }
                }
                Button("Any label") { model.apply([.run("showLabel", value: Double(Library.labels.count))]) }
            } label: {
                Label(library.filter.label.isEmpty ? "Label" : library.filter.label.capitalized, systemImage: "circle.fill")
            }
            if !library.filter.isEmpty {
                Button("Clear") { model.apply([.run("showAllPhotos")]) }
            }
        }
        .font(.footnote)
        .buttonStyle(.bordered)
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
            // Stars, flag and colour label.
            HStack(spacing: 2) {
                if photo.rating > 0 { Text(String(repeating: "★", count: photo.rating)).font(.system(size: 9)) }
                Spacer(minLength: 0)
                if photo.flag == 1 { Image(systemName: "flag.fill").foregroundStyle(.green) }
                if photo.flag == -1 { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            }
            .font(.system(size: 10))
            .foregroundStyle(.yellow)
            .padding(3)
            .background(photo.rating > 0 || photo.flag != 0 ? Color.black.opacity(0.5) : Color.clear)
        }
        .overlay(alignment: .top) {
            if !photo.label.isEmpty { Self.color(photo.label).frame(height: 4) }
        }
        .frame(height: 88)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 3))
        .contentShape(Rectangle())
        .opacity(photo.flag == -1 ? 0.5 : 1)
        .accessibilityLabel(photo.name)
    }

    /// A colour label's colour.
    static func color(_ label: String) -> Color {
        switch label {
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        default: return .clear
        }
    }
}

/// A title, caption or copyright: edited in place, applied when Return is pressed.
private struct MetadataField: View {
    let title: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.roundedBorder)
            .onAppear { text = value }
            .onChange(of: value) { _, new in text = new }
            .onSubmit { onCommit(text.trimmingCharacters(in: .whitespaces)) }
    }
}
