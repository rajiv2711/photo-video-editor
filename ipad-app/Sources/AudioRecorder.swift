import AVFoundation

/// Records one spoken command as 16 kHz mono 16-bit WAV — the format the voice server expects.
@MainActor
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noPermission
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .noPermission: return "Microphone access is off. Turn it on in Settings › Privacy › Microphone."
            case .couldNotStart: return "Couldn't start recording."
            }
        }
    }

    private var recorder: AVAudioRecorder?
    private let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("command.wav")

    /// Starts recording; stops by itself after `maxSeconds`.
    func start(maxSeconds: TimeInterval = 10) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.noPermission }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        guard recorder.record(forDuration: maxSeconds) else { throw RecorderError.couldNotStart }
        self.recorder = recorder
    }

    /// Stops and returns the WAV file's bytes.
    func stop() throws -> Data {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return try Data(contentsOf: fileURL)
    }
}
