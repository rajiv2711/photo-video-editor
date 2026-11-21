import ImageCaptureCore
import SwiftUI

/// Cameras and SD cards connected to the iPad (ImageCaptureCore): lists them and the photos on them, and
/// downloads the ones to import into a folder of the app's. iPadOS shows a camera on USB, and an SD card
/// in a card reader, as a camera with photos. Tethered capture: while it is on, every photo a connected
/// camera adds (a shot taken on it, or fired from the app over USB with PTP) is copied in and handed over
/// at once. The simulator has neither (check on the iPad).
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
    /// Cameras whose full list of files has arrived: files they add after that are new shots.
    private var readyCameras: Set<ObjectIdentifier> = []
    private let lock = NSLock()
    /// PTP transaction numbers (each command has its own).
    private var transaction: UInt32 = 1000

    /// Tethered capture: photos the cameras add from now on are copied in and given to `onNewPhotos`.
    var tethered = false {
        didSet {
            guard tethered, !oldValue else { return }
            start()
            // Firing the shutter needs control of the camera, not only its contents.
            browser.requestControlAuthorization { _ in }
        }
    }

    /// Gets the files of new shots while tethered (on the main queue).
    var onNewPhotos: (([URL]) -> Void)?

    /// How many cameras or cards are connected.
    var count: Int { devices.count }

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

    /// Fires the first connected camera's shutter over USB (PTP InitiateCapture, for cameras that let the
    /// iPad control them); the shot then arrives as any new photo does. False when no camera is connected.
    @discardableResult
    func takePicture(done: @escaping (String?) -> Void) -> Bool {
        guard let camera = devices.first?.camera else { return false }
        transaction += 1
        // A PTP command container: length, type 1 (command), code 0x100E, transaction, storage 0 and format 0 (the camera's own).
        var command = Data()
        func put(_ value: UInt32, _ bytes: Int) {
            var v = value.littleEndian
            command.append(Data(bytes: &v, count: bytes))
        }
        put(20, 4)
        put(1, 2)
        put(0x100E, 2)
        put(transaction, 4)
        put(0, 4)
        put(0, 4)
        camera.requestSendPTPCommand(command, outData: nil) { _, response, error in
            // The response's code (bytes 6–7): 0x2001 is OK.
            let code = response.count >= 8 ? UInt16(response[response.startIndex + 6]) | UInt16(response[response.startIndex + 7]) << 8 : 0
            let problem = error?.localizedDescription ?? (code == 0x2001 || code == 0 ? nil : String(format: "the camera answered 0x%04X", code))
            DispatchQueue.main.async { done(problem) }
        }
        return true
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
        // Tethered: a file added after the camera listed its own is a new shot.
        lock.lock()
        let ready = readyCameras.contains(ObjectIdentifier(camera))
        lock.unlock()
        guard tethered, ready else { return }
        let shots = items.compactMap { $0 as? ICCameraFile }.filter { file in
            Self.photoExtensions.contains(((file.name ?? "") as NSString).pathExtension.lowercased())
        }
        guard !shots.isEmpty else { return }
        download(shots) { urls in self.onNewPhotos?(urls) }
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
        lock.lock()
        readyCameras.insert(ObjectIdentifier(device))
        lock.unlock()
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
