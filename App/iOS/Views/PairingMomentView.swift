import SwiftUI
import WatchRemoteCore

struct PairingMomentView: View {
    @EnvironmentObject private var store: RemoteStore
    @State private var celebrate = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch store.pairingMoment {
                    case .ask:
                        ask
                    case .working:
                        working
                    case .ready:
                        ready
                    case .problem(let message):
                        problem(message)
                    case .none:
                        EmptyView()
                    }
                }
                .padding(24)
            }
            .background(LojoTheme.pageBackground)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 18) {
            IconTile(systemImage: "desktopcomputer", size: 64)
            Text("Is this your computer?")
                .font(.title.weight(.bold))
            Text(store.offer?.label ?? "Computer")
                .font(.title2.weight(.semibold))
            if let fingerprint = store.offer?.fingerprint {
                Text("Confirm this host key before connecting.")
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.secondaryText)
                Text(fingerprint)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            } else {
                Text("This code has no host key fingerprint. The next connection shows the key the computer presents.")
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.secondaryText)
            }
            Button("Yes, this is my computer") {
                Task { await store.acceptOffer() }
            }
            .buttonStyle(PrimaryButtonStyle(prominent: true))
            Button("Cancel") { store.dismissMoment() }
                .buttonStyle(QuietButtonStyle())
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView()
            Text("Connecting")
                .font(.title.weight(.bold))
            Text("Authorizing this iPhone and opening the computer.")
                .font(.body)
                .foregroundStyle(LojoTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(LojoTheme.online)
                .scaleEffect(celebrate ? 1 : 0.6)
                .opacity(celebrate ? 1 : 0)
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: celebrate)
            Text("Connected")
                .font(.largeTitle.weight(.bold))
            Text("The Watch is ready.")
                .font(.title3)
                .foregroundStyle(LojoTheme.secondaryText)
            Text(store.host.label)
                .font(.headline)
            Button("Done") { store.dismissMoment() }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
        }
        .onAppear { celebrate = true }
    }

    private func problem(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(LojoTheme.danger)
            Text("Not connected")
                .font(.title.weight(.bold))
            Text(message)
                .font(.body)
                .foregroundStyle(LojoTheme.danger)
            Button("Close") { store.dismissMoment() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }
}
