import AVFoundation
import SwiftUI
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (URL) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((URL) -> Void)?
    private let session = AVCaptureSession()
    private let instructionLabel = UILabel()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false
    private var isConfigured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        instructionLabel.text = "Scan the Pedro Voice Agent QR on your Mac"
        instructionLabel.textColor = .white
        instructionLabel.font = .preferredFont(forTextStyle: .headline)
        instructionLabel.textAlignment = .center
        instructionLabel.numberOfLines = 3
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        instructionLabel.layer.cornerRadius = 14
        instructionLabel.clipsToBounds = true
        view.addSubview(instructionLabel)
        NSLayoutConstraint.activate([
            instructionLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            instructionLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            instructionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            instructionLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
        authorizeAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSessionIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScan,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              let url = URL(string: value),
              url.scheme?.lowercased() == SecureBridgeProtocol.pairingURLScheme else { return }
        didScan = true
        session.stopRunning()
        dismiss(animated: true) { self.onScan?(url) }
    }

    private func configureCamera() {
        guard !isConfigured else { return }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            instructionLabel.text = "The camera is unavailable on this device."
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            instructionLabel.text = "The QR scanner could not start."
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        isConfigured = true
    }

    private func authorizeAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCamera()
            startSessionIfPossible()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureCamera()
                        self.startSessionIfPossible()
                    } else {
                        self.instructionLabel.text = "Camera access is off. Enable it in iPhone Settings to scan the Mac QR."
                    }
                }
            }
        case .denied, .restricted:
            instructionLabel.text = "Camera access is off. Enable it in iPhone Settings to scan the Mac QR."
        @unknown default:
            instructionLabel.text = "Camera access is unavailable."
        }
    }

    private func startSessionIfPossible() {
        guard isConfigured else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }
}
