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
    @State private var showAdvanced = false
    @State private var copyNote: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusBanner
                    if store.host.paired {
                        pairedContent
                    } else {
                        firstComputer
                    }
                    advancedSection
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
            .fullScreenCover(isPresented: Binding(
                get: { store.pairingMoment != .none },
                set: { if !$0 { store.dismissMoment() } }
            )) {
                PairingMomentView()
                    .environmentObject(store)
            }
            .confirmationDialog("Remove this computer?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { store.removeActiveComputer() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The saved host key and the agent secret for this computer are removed from this iPhone.")
            }
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(bannerColor)
                .frame(width: 12, height: 12)
            Text(store.pairingBanner.title)
                .font(.title3.weight(.bold))
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LojoTheme.cornerRadius, style: .continuous)
                .fill(bannerFill)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(store.pairingBanner.title)
    }

    private var bannerColor: Color {
        switch store.pairingBanner {
        case .notPaired:
            return LojoTheme.warning
        case .waiting:
            return LojoTheme.warning
        case .connected:
            return LojoTheme.online
        }
    }

    private var bannerFill: Color {
        switch store.pairingBanner {
        case .notPaired, .waiting:
            return LojoTheme.warning.opacity(0.16)
        case .connected:
            return LojoTheme.online.opacity(0.18)
        }
    }

    private var firstComputer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                store.beginScan()
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(PrimaryButtonStyle(prominent: true))
            .accessibilityHint("Opens the camera to scan the pairing code from the computer")
            Text("Pair your first computer")
                .font(.title2.weight(.bold))
            Text(PairingHelpCopy.headline)
                .font(.body)
                .foregroundStyle(LojoTheme.secondaryText)
            step(1, "On the computer, run your pair command") {
                Text(PairingHelpCopy.leaveOpen)
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.secondaryText)
                Text(PairingHelpCopy.publicCommand)
                    .font(.body.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityLabel("Public pair command")
                Text(PairingHelpCopy.aliasNote)
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.secondaryText)
                Text("Add --relay-url only if you host a direct relay. There is no built-in relay address.")
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pair.help")
            .accessibilityLabel(PairingHelpCopy.instructions())
            step(2, "Scan the QR") {
                Text("Use the Scan QR code button at the top of this screen.")
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.secondaryText)
            }
            step(3, "Confirm the computer") {
                Text("The phone asks if it is your computer, then connects. The Watch is ready when you see Connected.")
                    .font(.subheadline)
                    .foregroundStyle(LojoTheme.secondaryText)
            }
        }
    }

    private var pairedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.host.label)
                .font(.title2.weight(.bold))
            if store.computers.count > 1 {
                ForEach(store.computers) { computer in
                    Button {
                        store.selectComputer(id: computer.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: computer.id == store.host.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(computer.id == store.host.id ? LojoTheme.accent : LojoTheme.secondaryText)
                            Text(computer.label)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            fingerprintBody
            authorizeBody
            testBody
            if store.pairingBanner == .connected {
                Text(store.snapshot.directReady ? "The Watch can connect on its own, or through this iPhone." : "The Watch uses this iPhone. A direct relay was not in the pairing QR.")
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.secondaryText)
                Button("Disconnect") { store.disconnectLink() }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("computer.disconnect")
            }
        }
        .lojoCard()
    }

    @ViewBuilder
    private var fingerprintBody: some View {
        if let fingerprint = store.host.pinnedFingerprint {
            Text("Host key fingerprint. The next connection still asks you to confirm it.")
                .font(.subheadline)
                .foregroundStyle(LojoTheme.secondaryText)
            Text(fingerprint)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            if store.pairingNotice != nil {
                Button("Confirm fingerprint") { store.dismissPairingNotice() }
                    .buttonStyle(QuietButtonStyle())
            }
        } else if store.host.paired {
            Text("No host key fingerprint was in the pairing code. The next connection shows the key the computer presents.")
                .font(.subheadline)
                .foregroundStyle(LojoTheme.secondaryText)
        } else {
            Text("After the scan, the fingerprint from the computer shows here. Confirm it before you connect.")
                .font(.subheadline)
                .foregroundStyle(LojoTheme.secondaryText)
        }
    }

    private var authorizeBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Copy authorize command") { copyAuthorize() }
                .buttonStyle(PrimaryButtonStyle(prominent: !store.host.paired))
            Text("On the computer, paste that command into a terminal and run it. It adds this iPhone’s public key. It does not copy the private key.")
                .font(.subheadline)
                .foregroundStyle(LojoTheme.secondaryText)
            if let key = store.keys.key {
                UnbrokenMonospace(text: AuthorizeCommand.text(publicKey: key.publicKey))
            }
            if let copyNote {
                Text(copyNote)
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.secondaryText)
            }
        }
    }

    private var testBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(store.connectionTest == .running ? "Testing…" : "Test connection") {
                Task { await store.testConnection() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(store.connectionTest == .running)
            testResult
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch store.connectionTest {
        case .idle:
            EmptyView()
        case .running:
            Text("Testing the connection.")
                .font(.body.weight(.semibold))
                .foregroundStyle(LojoTheme.secondaryText)
        case .connected:
            Text("Connected")
                .font(.title3.weight(.bold))
                .foregroundStyle(LojoTheme.online)
        case .failed(let message):
            Text(message)
                .font(.body.weight(.semibold))
                .foregroundStyle(LojoTheme.danger)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Name, address, user, and port. Paste a code here if the camera is unavailable. If the pairing window expires, copy the authorize command and run it on the computer.")
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.secondaryText)
                authorizeBody
                Button("Scan QR code") { store.beginScan() }
                    .buttonStyle(QuietButtonStyle())
                Button("Paste pairing code") { store.showPairing = true }
                    .buttonStyle(QuietButtonStyle())
                Button("Add computer") { store.addComputer() }
                    .buttonStyle(QuietButtonStyle())
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
                Text("Only an address in 100.64.0.0/10 is contacted.")
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
                .buttonStyle(QuietButtonStyle())
                if canRemove {
                    Button("Remove this computer") { confirmRemove = true }
                        .buttonStyle(DestructiveButtonStyle())
                }
                NavigationLink {
                    KeyView()
                } label: {
                    HStack {
                        Text("Key details")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(LojoTheme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
        .font(.headline)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: LojoTheme.cornerRadius, style: .continuous)
                .fill(LojoTheme.cardBackground)
        )
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(number)")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(LojoTheme.brandGradient))
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            content()
                .padding(.leading, 46)
        }
    }

    private func copyAuthorize() {
        if store.keys.key == nil {
            do {
                try store.keys.generateEd25519()
            } catch {
                copyNote = error.localizedDescription
                return
            }
        }
        guard let key = store.keys.key else {
            copyNote = "A key could not be created on this iPhone."
            return
        }
        UIPasteboard.general.string = AuthorizeCommand.text(publicKey: key.publicKey)
        copyNote = "Copied. Paste it into a terminal on the computer and run it."
    }

    private var canRemove: Bool {
        store.computers.count > 1 || store.host != .placeholder
    }


    private func syncHostFields() {
        label = store.host.label
        address = store.host.address
        username = store.host.username
        port = String(store.host.port)
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
                        UnbrokenMonospace(text: OpenSSHPublicKey.canonical(key.publicKey) ?? key.publicKey)
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
                        UIPasteboard.general.string = OpenSSHPublicKey.canonical(key.publicKey) ?? key.publicKey
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Copy authorize command") {
                        UIPasteboard.general.string = AuthorizeCommand.text(publicKey: key.publicKey)
                    }
                    .buttonStyle(QuietButtonStyle())
                    UnbrokenMonospace(text: AuthorizeCommand.text(publicKey: key.publicKey))
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

/// One line, scrolled sideways. A wrapped label hyphenates the blob and the selection copies that hyphen.
private struct UnbrokenMonospace: View {
    var text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
