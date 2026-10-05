import AVFoundation
import SwiftUI
import UIKit
import WatchRemoteCore

struct PairingImportView: View {
    @EnvironmentObject private var store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var paste = ""
    @State private var message: String?
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(PairingHelpCopy.scan)
                        .font(.subheadline)
                        .foregroundStyle(LojoTheme.secondaryText)
                    Text("The code can contain the agent secret. It is stored in the Keychain on this iPhone. The address has to be inside 100.64.0.0/10.")
                        .font(.footnote)
                        .foregroundStyle(LojoTheme.secondaryText)
                    Button("Scan QR code") { openScanner() }
                        .buttonStyle(PrimaryButtonStyle())
                    Text("Pairing text")
                        .font(.headline)
                    TextEditor(text: $paste)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 120)
                        .padding(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(LojoTheme.hairline)
                        )
                        .accessibilityLabel("Pairing text")
                    Button("Import") { apply(paste) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(LojoTheme.danger)
                    }
                }
                .padding(20)
            }
            .background(LojoTheme.pageBackground)
            .navigationTitle("Pair a computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(LojoTheme.secondaryText)
                }
            }
            .onAppear {
                guard store.launchScanner else { return }
                store.launchScanner = false
                openScanner()
            }
            .fullScreenCover(isPresented: $showScanner) {
                QRScannerScreen(
                    onCode: { code in
                        showScanner = false
                        apply(code)
                    },
                    onClose: { showScanner = false }
                )
            }
        }
    }

    private func openScanner() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showScanner = true
                    } else {
                        message = "Camera access is off. Paste the pairing text instead."
                    }
                }
            }
        case .denied, .restricted:
            message = "Camera access is off. Paste the pairing text instead."
        @unknown default:
            message = "Camera access is off. Paste the pairing text instead."
        }
    }

    private func apply(_ text: String) {
        if let error = store.importPairing(text) {
            message = error
        } else {
            paste = ""
            message = nil
        }
    }
}

struct QRScannerScreen: View {
    var onCode: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if AVCaptureDevice.default(for: .video) == nil {
                    Text("This device has no camera. Paste the pairing text instead.")
                        .font(.subheadline)
                        .foregroundStyle(LojoTheme.secondaryText)
                        .padding(20)
                } else {
                    QRScannerRepresentable(onCode: onCode)
                        .ignoresSafeArea()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }
}

struct QRScannerRepresentable: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showUnavailable()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showUnavailable()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            showUnavailable()
            return
        }
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer })?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            if session.isRunning { session.stopRunning() }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.delivered, let value, !value.isEmpty else { return }
            self.delivered = true
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async {
                if session.isRunning { session.stopRunning() }
            }
            self.onCode?(value)
        }
    }

    private func showUnavailable() {
        let label = UILabel()
        label.text = "This device has no camera. Paste the pairing text instead."
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
