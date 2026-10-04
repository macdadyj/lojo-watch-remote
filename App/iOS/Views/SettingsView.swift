import SwiftUI
import WatchRemoteCore

struct SettingsView: View {
    @EnvironmentObject private var store: RemoteStore
    @State private var agentSecret = ""
    @State private var relayToken = ""
    @State private var relayPin = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Connection", selection: Binding(
                        get: { store.mode },
                        set: { store.setMode($0) }
                    )) {
                        Text("SSH").tag(ConnectionMode.ssh)
                        Text("Relay").tag(ConnectionMode.relay)
                        Text("Demo").tag(ConnectionMode.demo)
                    }
                    .pickerStyle(.segmented)

                    Text(modeCopy)
                        .font(.footnote)
                        .foregroundStyle(LojoTheme.secondaryText)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Working directory")
                            .font(.headline)
                        TextField("/home/user/src", text: Binding(
                            get: { store.cwd },
                            set: { store.setCwd($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    .lojoCard()

                    if store.mode == .ssh { sshSecret }
                    if store.mode == .relay { relayFields }

                    Picker("Appearance", selection: Binding(
                        get: { store.appearance },
                        set: { store.setAppearance($0) }
                    )) {
                        ForEach(AppearanceChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button("Forget saved host key") { store.forgetHostKey() }
                        .buttonStyle(DestructiveButtonStyle())

                    Text("Demo stays on this iPhone. SSH is how the Watch reaches the computer.")
                        .font(.footnote)
                        .foregroundStyle(LojoTheme.secondaryText)
                        .padding(.bottom, 12)
                }
                .padding(20)
            }
            .background(LojoTheme.pageBackground)
            .navigationTitle("Settings")
        }
    }

    private var modeCopy: String {
        switch store.mode {
        case .ssh:
            return "The iPhone holds an SSH connection to your computer. Approvals use the agent server through that connection. Your Grok login stays on the computer."
        case .relay:
            return "Optional. The phone talks to the relay on the overlay. The relay holds the agent secret. Pin its certificate before connecting."
        case .demo:
            return "Sample sessions on this iPhone. Nothing is sent to the computer."
        }
    }

    private var sshSecret: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent server secret")
                .font(.headline)
            Text(store.hasAgentSecret ? "Saved in the Keychain." : "Not saved yet.")
                .font(.subheadline)
                .foregroundStyle(LojoTheme.secondaryText)
            SecureField("From the computer, not stored in git", text: $agentSecret)
                .textFieldStyle(.roundedBorder)
            Button("Save secret") {
                store.saveAgentSecret(agentSecret)
                agentSecret = ""
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(agentSecret.isEmpty)
        }
        .lojoCard()
    }

    private var relayFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relay")
                .font(.headline)
            TextField("https://100.64.0.2:2479", text: Binding(
                get: { store.relayURL },
                set: { store.setRelayURL($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            SecureField("Device token", text: $relayToken)
                .textFieldStyle(.roundedBorder)
            TextField("Certificate SHA-256", text: $relayPin)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save relay credentials") {
                if !relayToken.isEmpty { store.saveRelayToken(relayToken) }
                if !relayPin.isEmpty { store.saveRelayPin(relayPin) }
                relayToken = ""
                relayPin = ""
            }
            .buttonStyle(PrimaryButtonStyle())
            Text(store.hasRelayToken && store.hasRelayPin ? "Token and pin are in the Keychain." : "Both the token and the pin are required.")
                .font(.footnote)
                .foregroundStyle(LojoTheme.secondaryText)
        }
        .lojoCard()
    }
}
