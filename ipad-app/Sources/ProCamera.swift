import AVFoundation
import CommandEngine
import SwiftUI

/// The Pro camera (Camera panel): the iPad's back camera through AVFoundation, with manual ISO, shutter
/// speed, focus and white balance (0 = automatic for each) and raw capture where the iPad can (Bayer raw
/// as DNG; Apple ProRAW where supported). Each photo taken joins the library and opens for editing.
/// The simulator has no camera (check on the iPad).
final class ProCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published private(set) var status = "Starting the camera…"
    @Published private(set) var running = false
    /// The iPad can capture raw photos.
    @Published private(set) var rawAvailable = false
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private let queue = DispatchQueue(label: "pro-camera")
    private var configured = false
    /// Gets each photo taken: its bytes and file extension ("dng", "heic", "jpg"), on the main queue.
    var onPhoto: ((Data, String) -> Void)?

    /// Starts the camera (asks for access the first time).
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                self.publish("The app may not use the camera: allow it in Settings › Privacy › Camera.", running: false)
                return
            }
            self.queue.async { self.configure() }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.publish("Camera stopped.", running: false)
        }
    }

    private func publish(_ text: String, running: Bool) {
        DispatchQueue.main.async {
            self.status = text
            self.running = running
        }
    }

    /// The back camera into the session, photos out of it (raw where the iPad allows).
    private func configure() {
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                publish("This iPad has no camera the app can use.", running: false)
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = true }
            session.commitConfiguration()
            self.device = device
            configured = true
        }
        if !session.isRunning { session.startRunning() }
        let raw = !output.availableRawPhotoPixelFormatTypes.isEmpty
        DispatchQueue.main.async { self.rawAvailable = raw }
        publish(raw ? "Ready · raw capture available" : "Ready · this iPad captures no raw photos (HEIC instead)", running: session.isRunning)
    }

    /// Manual settings, 0 = automatic: ISO, shutter speed as 1/N s, focus 1…100 (near to far), white
    /// balance in kelvin. Values outside what the camera can do are brought inside.
    func apply(iso: Double, shutter: Double, focus: Double, kelvin: Double) {
        queue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            let format = device.activeFormat
            if (iso > 0 || shutter > 0) && device.isExposureModeSupported(.custom) {
                let chosenISO = iso > 0 ? Float(min(max(iso, Double(format.minISO)), Double(format.maxISO))) : AVCaptureDevice.currentISO
                var duration = AVCaptureDevice.currentExposureDuration
                if shutter > 0 {
                    duration = CMTime(seconds: 1 / shutter, preferredTimescale: 1_000_000)
                    if duration < format.minExposureDuration { duration = format.minExposureDuration }
                    if duration > format.maxExposureDuration { duration = format.maxExposureDuration }
                }
                device.setExposureModeCustom(duration: duration, iso: chosenISO, completionHandler: nil)
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if focus > 0 && device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: Float(min(focus, 100) / 100), completionHandler: nil)
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if kelvin > 0 && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                let wanted = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(min(max(kelvin, 2500), 9000)), tint: 0)
                var gains = device.deviceWhiteBalanceGains(for: wanted)
                let top = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), top)
                gains.greenGain = min(max(gains.greenGain, 1), top)
                gains.blueGain = min(max(gains.blueGain, 1), top)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    /// Takes a photo: raw (DNG) when asked and the iPad can, else HEIC (JPEG where HEIC isn't offered).
    func capture(raw: Bool) {
        queue.async {
            guard self.session.isRunning else { return }
            let settings: AVCapturePhotoSettings
            let formats = self.output.availableRawPhotoPixelFormatTypes
            let proRAW = formats.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
            if raw, let format = proRAW ?? formats.first {
                settings = AVCapturePhotoSettings(rawPixelFormatType: format)
            } else if self.output.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            publish("The photo couldn't be taken: \(error?.localizedDescription ?? "no picture")", running: session.isRunning)
            return
        }
        let ext = photo.isRawPhoto ? "dng" : (LibraryStore.describe(data).type == "public.heic" ? "heic" : "jpg")
        DispatchQueue.main.async { self.onPhoto?(data, ext) }
    }
}

/// What the camera sees, live.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer?.session = session
        view.previewLayer?.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// The Pro camera screen: the live picture, the Camera panel's manual settings (the same controls voice
/// reaches: "iso 400", "shutter 250", "camera focus 30", "camera white balance 5600", "capture raw") and
/// the shutter button ("take photo").
struct ProCameraView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var camera: ProCamera
    @Environment(\.dismiss) private var dismiss
    /// A photo asked for before the camera was running.
    @State private var pending = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Color.black
                CameraPreview(session: camera.session)
                Text(camera.status)
                    .font(.footnote)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.registry.controls(inGroup: "camera").filter { $0.section == "Pro camera" && $0.kind != .action }) { control in
                        ControlRow(model: model, control: control)
                    }
                    Text("0 = automatic").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 10)
                    Button {
                        model.apply([.run("takePhoto")])
                    } label: {
                        Label("Take Photo", systemImage: "camera.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!camera.running)
                    .padding(10)
                    Button("Close") { dismiss() }.padding(.horizontal, 10)
                }
                .padding(.vertical)
            }
            .frame(width: 300)
            .background(.regularMaterial)
        }
        .onAppear {
            camera.start()
            applySettings()
        }
        .onDisappear { camera.stop() }
        .onChange(of: model.cameraSettings) { _, _ in applySettings() }
        .onChange(of: model.cameraShots) { _, _ in shoot() }
        .onChange(of: camera.running) { _, running in
            if running {
                applySettings()
                if pending { shoot() }
            }
        }
    }

    private func applySettings() {
        let v = model.cameraSettings
        guard v.count == 4 else { return }
        camera.apply(iso: v[0], shutter: v[1], focus: v[2], kelvin: v[3])
    }

    private func shoot() {
        guard camera.running else {
            pending = true
            return
        }
        pending = false
        camera.capture(raw: model.capturesRaw)
    }
}
