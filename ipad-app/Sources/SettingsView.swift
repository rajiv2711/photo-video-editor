import SwiftUI

/// Voice server address and token. The token is stored in the Keychain on this iPad only.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = VoiceServerClient.baseURL
    @State private var token = VoiceServerClient.token
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-name.ngrok-free.app", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token (optional for now)", text: $token)
                } header: {
                    Text("Voice server")
                } footer: {
                    Text("The laptop turns speech into text during development. The address is built in; the token is optional until security is added.")
                }
                Section {
                    Button(checking ? "Checking…" : "Test connection") {
                        Task { await check() }
                    }
                    .disabled(checking)
                    if let status {
                        Text(status).font(.callout)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() {
        VoiceServerClient.baseURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        VoiceServerClient.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func check() async {
        save()
        checking = true
        status = await VoiceServerClient.checkConnection()
        checking = false
    }
}
