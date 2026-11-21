import CommandEngine
import MapKit
import SwiftUI

/// The Map (Library panel): the photos shown that say where they were taken (GPS in their EXIF), each as
/// its thumbnail at that place; tap one to edit it.
struct LibraryMapView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let region = model.library.mapRegion {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
                        span: MKCoordinateSpan(latitudeDelta: region.latitudeSpan, longitudeDelta: region.longitudeSpan)))) {
                        ForEach(model.library.located) { photo in
                            Annotation(photo.name, coordinate: CLLocationCoordinate2D(latitude: photo.latitude ?? 0, longitude: photo.longitude ?? 0)) {
                                pin(photo)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No places", systemImage: "map",
                                           description: Text("None of the photos shown says where it was taken."))
                }
            }
            .navigationTitle("Map · \(model.library.located.count) photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    /// A photo on the map: its thumbnail, framed when it is the one being edited.
    private func pin(_ photo: LibraryPhoto) -> some View {
        Group {
            if let thumb = model.thumbnail(photo.id) {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(photo.id == model.library.current ? Color.accentColor : Color.white, lineWidth: 2))
        .shadow(radius: 3)
        .onTapGesture {
            model.openLibraryPhoto(photo.id)
            dismiss()
        }
    }
}
