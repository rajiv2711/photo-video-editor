import Foundation
import Security

/// Talks to the laptop voice server (voice-server/) during development: sends a WAV clip,
/// gets back the text Whisper heard. The CommandEngine on the iPad then parses that text.
enum VoiceServerClient {
    /// The laptop's ngrok address, built into the app. Can be changed in Settings.
    static let defaultURL = ""

    struct Transcription: Decodable {
        let text: String
        let elapsed_ms: Double?
    }

    enum ClientError: LocalizedError {
        case notConfigured
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Set the voice server address and token in Settings."
            case .server(let code, let detail): return "Voice server error \(code): \(detail)"
            }
        }
    }

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "voiceServerURL") ?? defaultURL }
        set { UserDefaults.standard.set(newValue, forKey: "voiceServerURL") }
    }

    /// Kept in the Keychain, never in the app bundle (the repo and its builds are public).
    static var token: String {
        get { Keychain.read(account: "token") ?? "" }
        set { Keychain.write(newValue, account: "token") }
    }

    static var isConfigured: Bool {
        URL(string: baseURL)?.host != nil && !token.isEmpty
    }

    static func transcribe(wav: Data) async throws -> Transcription {
        var request = try makeRequest(path: "transcribe")
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: wav)
        try check(response, data)
        return try JSONDecoder().decode(Transcription.self, from: data)
    }

    /// A one-line status for Settings, e.g. "Connected · Whisper large-v3-turbo on cuda".
    static func checkConnection() async -> String {
        struct Info: Decodable { let model: String; let device: String }
        do {
            let (data, response) = try await URLSession.shared.data(for: try makeRequest(path: "info"))
            try check(response, data)
            let info = try JSONDecoder().decode(Info.self, from: data)
            return "Connected · Whisper \(info.model) on \(info.device)"
        } catch {
            return "Not connected: \(error.localizedDescription)"
        }
    }

    private static func makeRequest(path: String) throws -> URLRequest {
        guard isConfigured, let base = URL(string: baseURL) else { throw ClientError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        return request
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.server(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }
}

/// Minimal Keychain wrapper for the voice server token.
enum Keychain {
    private static let service = "io.github.rajiv2711.photovideoeditor.voice-server"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
