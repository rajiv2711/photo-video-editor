import ImageCaptureCore
import SwiftUI

/// Cameras and SD cards connected to the iPad (ImageCaptureCore): lists them and the photos on them, and
/// downloads the ones to import into a folder of the app's. iPadOS shows a camera on USB, and an SD card
/// in a card reader, as a camera with photos. The simulator has neither (check on the iPad).
final class CameraImporter: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    /// A connected camera or card and the photo files on it.
    struct Device: Identifiable {
        let id: ObjectIdentifier
        let camera: ICCameraDevice
        var name: String
        var photos: [ICCameraFile]
        /// Its full list of files has arrived.
        var ready: Bool
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var status = "Looking for cameras and SD cards…"
    @Published private(set) var downloading = false
    private let browser = ICDeviceBrowser()
    private var started = false

    /// Picture files the library can import (raws included).
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng", "cr2", "cr3", "crw", "nef", "nrw",
                                               "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "mos", "rwl"]

    /// Starts looking for cameras and cards (asks once for access to their contents).
    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.requestContentsAuthorization { _ in
            DispatchQueue.main.async { self.browser.start() }
        }
    }

    func stop() {
        browser.stop()
        started = false
    }

    /// Downloads photo files into a folder of the app's; `done` gets their files (on the main queue).
    func download(_ files: [ICCameraFile], done: @escaping ([URL]) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("camera-import", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        DispatchQueue.main.async { self.downloading = true }
        for file in files {
            group.enter()
            let options: [ICDownloadOption: Any] = [.downloadsDirectoryURL: folder, .overwrite: true]
            file.requestDownload(options: options) { name, _ in
                if let name {
                    let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : folder.appendingPathComponent(name)
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.downloading = false
            done(urls)
        }
    }

    /// The photo files a camera has, oldest first as the camera lists them.
    private func photos(of camera: ICCameraDevice) -> [ICCameraFile] {
        (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.filter { file in
            Self.photoExtensions.contains(((file.name ?? "") as NSString).pathExtension.lowercased())
        }
    }

    /// Lists a camera's photos again (files added or removed), and says what is connected.
    private func refresh(_ camera: ICCameraDevice, ready: Bool? = nil) {
        let list = photos(of: camera)
        DispatchQueue.main.async {
            if let i = self.devices.firstIndex(where: { $0.camera === camera }) {
                self.devices[i].photos = list
                if let ready { self.devices[i].ready = ready }
            }
            self.describe()
        }
    }

    private func describe() {
        status = devices.isEmpty ? "No camera or SD card connected: connect one by USB (a card in a card reader)."
            : devices.map { "\($0.name): \($0.ready ? "\($0.photos.count) photos" : "reading…")" }.joined(separator: " · ")
    }

    // MARK: - ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        camera.delegate = self
        camera.requestOpenSession()
        DispatchQueue.main.async {
            self.devices.append(Device(id: ObjectIdentifier(camera), camera: camera, name: camera.name ?? "Camera", photos: [], ready: false))
            self.describe()
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        DispatchQueue.main.async {
            self.devices.removeAll { $0.camera === device }
            self.describe()
        }
    }

    // MARK: - ICDeviceDelegate

    func didRemove(_ device: ICDevice) {
        DispatchQueue.main.async {
            self.devices.removeAll { $0.camera === device }
            self.describe()
        }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            DispatchQueue.main.async { self.status = "\(device.name ?? "Camera"): \(error.localizedDescription)" }
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    // MARK: - ICCameraDeviceDelegate

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        refresh(camera)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        refresh(camera)
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        refresh(device, ready: true)
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// The Import From Camera sheet: each camera or SD card connected and how many photos it has; Import
/// copies them into the library (the first one opens).
struct CameraImportView: View {
    @ObservedObject var importer: CameraImporter
    let onImport: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(importer.status).foregroundStyle(.secondary)
                }
                ForEach(importer.devices) { device in
                    Section(device.name) {
                        if device.photos.isEmpty {
                            Text(device.ready ? "No photos on it." : "Reading its photos…").foregroundStyle(.secondary)
                        } else {
                            Button("Import all \(device.photos.count) photos") { take(device.photos) }
                            Button("Import the last 10") { take(Array(device.photos.suffix(10))) }
                        }
                    }
                }
                if importer.downloading {
                    ProgressView("Copying photos…")
                }
            }
            .navigationTitle("Import from camera or card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .onAppear { importer.start() }
    }

    private func take(_ files: [ICCameraFile]) {
        importer.download(files) { urls in
            onImport(urls)
            dismiss()
        }
    }
}
