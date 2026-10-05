import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import WatchRemoteCore

struct ComputerView: View {
    @EnvironmentObject private var store: RemoteStore
    @State private var label = ""
    @State private var address = ""
    @State private var username = ""
    @State private var port = ""
    @State private var hostError: String?
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.keys.key == nil {
                        firstRunCard
                    }
                    computersCard
                    if let notice = store.pairingNotice {
                        pairingNoticeCard(notice)
                    }
                    hostCard
                    keyCard
                    NavigationLink {
                        KeyView()
                    } label: {
                        HStack {
                            Text("Key and authorize command")
                                .font(.body.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LojoTheme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .lojoCard()
                    Text("The Watch reaches the active computer through this iPhone. Scan the pairing QR from that computer, then authorize this iPhone’s key.")
                        .font(.footnote)
                        .foregroundStyle(LojoTheme.secondaryText)
                        .padding(.bottom, 12)
                }
                .padding(20)
            }
            .background(LojoTheme.pageBackground)
            .navigationTitle("Computer")
            .onAppear(perform: syncHostFields)
            .onChange(of: store.host) { _, _ in syncHostFields() }
            .sheet(isPresented: $store.showPairing) {
                PairingImportView()
                    .presentationDetents([.large])
            }
            .confirmationDialog("Remove this computer?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { store.removeActiveComputer() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The saved host key and the agent secret for this computer are removed from this iPhone.")
            }
        }
    }

    private var computersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved computers")
                .font(.headline)
            ForEach(store.computers) { computer in
                Button {
                    store.selectComputer(id: computer.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: computer.id == store.host.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(computer.id == store.host.id ? LojoTheme.accent : LojoTheme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(computer.label)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(computer.username)@\(computer.address)")
                                .font(.caption.monospaced())
                                .foregroundStyle(LojoTheme.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(computer.id == store.host.id ? "\(computer.label), active" : computer.label)
            }
            Button("Scan pairing QR") { store.showPairing = true }
                .buttonStyle(PrimaryButtonStyle())
            Button("Paste pairing code") { store.showPairing = true }
                .buttonStyle(QuietButtonStyle())
            Button("Add computer") { store.addComputer() }
                .buttonStyle(QuietButtonStyle())
            if canRemove {
                Button("Remove this computer") { confirmRemove = true }
                    .buttonStyle(DestructiveButtonStyle())
            }
        }
        .lojoCard()
    }

    private var canRemove: Bool {
        store.computers.count > 1 || store.host != .placeholder
    }

    private func pairingNoticeCard(_ notice: PairingNotice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confirm \(notice.label)")
                .font(.headline)
            if let fingerprint = notice.fingerprint {
                Text("Pinned host key. The next connection still shows this fingerprint before it is trusted.")
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.secondaryText)
                Text(fingerprint)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            } else {
                Text("No host key fingerprint was in the pairing code. The next connection asks you to check the one the computer presents.")
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.secondaryText)
            }
            Text(notice.storedSecret ? "Agent secret saved in the Keychain." : "No agent secret was in the code. You can save one in Settings.")
                .font(.footnote)
                .foregroundStyle(LojoTheme.secondaryText)
            Button("Fingerprint noted") { store.dismissPairingNotice() }
                .buttonStyle(QuietButtonStyle())
        }
        .lojoCard()
    }

    private var hostCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(systemImage: "desktopcomputer", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.host.label)
                        .font(.headline)
                    Text("\(store.host.username) · port \(store.host.port)")
                        .font(.subheadline)
                        .foregroundStyle(LojoTheme.secondaryText)
                    Text(store.host.address)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(LojoTheme.secondaryText)
                }
            }
            Text("Name")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LojoTheme.secondaryText)
            TextField("example-host", text: $label)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("100.64.0.2", text: $address)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
            TextField("user", text: $username)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("22", text: $port)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
            if let fingerprint = store.host.pinnedFingerprint {
                Text("Pinned host key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LojoTheme.secondaryText)
                Text(fingerprint)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Text("Connecting still shows this fingerprint so you can confirm it.")
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.secondaryText)
            }
            Text("Only an address in 100.64.0.0/10 is contacted. The values above are placeholders until you save the computer you paired.")
                .font(.footnote)
                .foregroundStyle(LojoTheme.secondaryText)
            if let hostError {
                Text(hostError)
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.danger)
            }
            Button("Save computer") {
                hostError = store.updateHost(label: label, address: address, portText: port, username: username)
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Refresh sessions") {
                Task { await store.refresh() }
            }
            .buttonStyle(QuietButtonStyle())
        }
        .lojoCard()
    }

    private func syncHostFields() {
        label = store.host.label
        address = store.host.address
        username = store.host.username
        port = String(store.host.port)
    }

    private var firstRunCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pair this iPhone")
                .font(.headline)
            Text("Scan the pairing QR, generate a key, then run watch-remote-authorize on that computer.")
                .font(.footnote)
                .foregroundStyle(LojoTheme.secondaryText)
        }
        .lojoCard()
        .accessibilityElement(children: .combine)
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusMark(status: store.keys.key == nil ? .unknown : .idle)
                Text(store.keys.key == nil ? "No key yet" : "Key in the Keychain")
                    .font(.subheadline.weight(.semibold))
            }
            Text("The private key stays on this iPhone. The computer only receives the public half, through the authorize command you run there.")
                .font(.footnote)
                .foregroundStyle(LojoTheme.secondaryText)
        }
        .lojoCard()
    }
}

struct KeyView: View {
    @EnvironmentObject private var store: RemoteStore
    @State private var keyError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let key = store.keys.key {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(key.kind == .secureEnclaveP256 ? "Secure Enclave" : "Ed25519 in the Keychain")
                            .font(.headline)
                        Text(key.fingerprint)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        Text(key.publicKey)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .lojoCard()
                    if let image = QRCode.image(key.publicKey) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("QR code of the public key")
                    }
                    Button("Copy public key") {
                        UIPasteboard.general.string = key.publicKey
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Copy authorize command") {
                        UIPasteboard.general.string = AuthorizeCommand.text(publicKey: key.publicKey)
                    }
                    .buttonStyle(QuietButtonStyle())
                    Text(AuthorizeCommand.text(publicKey: key.publicKey))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("On the computer, as \(store.host.username), run that command once. It adds this public key and does not print the private key.")
                        .font(.footnote)
                        .foregroundStyle(LojoTheme.secondaryText)
                } else {
                    Text("Generate a key on this iPhone. It is stored in the Keychain and is not part of the backup.")
                        .font(.subheadline)
                        .foregroundStyle(LojoTheme.secondaryText)
                }
                Button("Generate Ed25519 key") {
                    keyError = nil
                    do {
                        try store.keys.generateEd25519()
                    } catch {
                        keyError = error.localizedDescription
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                if store.keys.secureEnclaveAvailable {
                    Button("Generate Secure Enclave key") {
                        keyError = nil
                        do {
                            try store.keys.generateSecureEnclave()
                        } catch {
                            keyError = error.localizedDescription
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                if let keyError {
                    Text(keyError)
                        .font(.footnote)
                        .foregroundStyle(LojoTheme.danger)
                }
            }
            .padding(20)
        }
        .background(LojoTheme.pageBackground)
        .navigationTitle("Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct TrustView: View {
    var prompt: TrustPrompt
    @EnvironmentObject private var store: RemoteStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        StatusMark(status: prompt.changed ? .failed : .unknown, size: 14)
                        Text(prompt.changed ? "Host key changed" : (prompt.matchesPin ? "Host key from pairing" : "New host key"))
                            .font(.title3.weight(.semibold))
                    }
                    Text(trustCopy)
                        .font(.subheadline)
                        .foregroundStyle(LojoTheme.secondaryText)
                    Text(prompt.key.fingerprint)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .lojoCard()
                    if let previous = prompt.previousFingerprint {
                        Text("Saved fingerprint")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LojoTheme.secondaryText)
                        Text(previous)
                            .font(.footnote.monospaced())
                    }
                    if prompt.changed {
                        Button("Close") { store.rejectTrust() }
                            .buttonStyle(QuietButtonStyle())
                    } else {
                        Button("Trust and connect") { store.acceptTrust() }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Don’t trust") { store.rejectTrust() }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
                .padding(20)
            }
            .background(LojoTheme.pageBackground)
            .navigationTitle(prompt.host.label)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(prompt.changed)
    }

    private var trustCopy: String {
        if prompt.changed {
            if let pinned = prompt.host.pinnedFingerprint, prompt.previousFingerprint == pinned {
                return "This is not the host key from the pairing code. The connection is refused."
            }
            return "The computer’s key does not match the one this iPhone saved. The connection is refused."
        }
        if prompt.matchesPin {
            return "This fingerprint matches the pairing code. Confirm it before connecting."
        }
        return "Check this fingerprint against the computer before trusting it."
    }
}
