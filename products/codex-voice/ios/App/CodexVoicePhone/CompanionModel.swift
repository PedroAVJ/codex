import Foundation
import UIKit

@MainActor
final class CompanionModel: ObservableObject {
    enum Phase: Equatable {
        case unpaired
        case scanning
        case connecting
        case paired
    }

    @Published var phase: Phase
    @Published var status: String
    @Published var errorText: String?
    @Published var isShowingScanner = false
    @Published var watchSyncState: PhonePairingTransfer.State = .activating

    private let bridge = BridgeConnection()
    private let watchTransfer = PhonePairingTransfer()
    private var credentials: PairingCredentials?

    init() {
        let savedCredentials = PairingKeychain.load()
        credentials = savedCredentials
        if let savedCredentials, savedCredentials.clientID != nil {
            phase = .paired
            status = "Paired with \(savedCredentials.serviceName)"
        } else {
            phase = .unpaired
            status = "Scan the pairing QR generated on your Mac"
        }

        watchTransfer.onStateChange = { [weak self] state in
            self?.watchSyncState = state
        }
        watchTransfer.activate(credentials: savedCredentials?.clientID == nil ? nil : savedCredentials)

        bridge.onStatus = { [weak self] message in self?.status = message }
        bridge.onEnvelope = { [weak self] envelope in
            self?.handle(envelope)
            return "phone_handler_completed"
        }
        bridge.onCredentialsUpdated = { [weak self] credentials in
            guard let self else { return }
            do {
                try PairingKeychain.save(credentials)
                self.credentials = credentials
                self.watchTransfer.sync(credentials)
            } catch {
                self.errorText = error.localizedDescription
                self.phase = .unpaired
            }
        }
    }

    func scan() {
        errorText = nil
        phase = .scanning
        isShowingScanner = true
    }

    func scannerDismissed() {
        isShowingScanner = false
        if phase == .scanning {
            phase = credentials?.clientID == nil ? .unpaired : .paired
        }
    }

    func open(_ url: URL) {
        isShowingScanner = false
        if url.isFileURL {
            importPairingImage(at: url)
            return
        }

        do {
            let link = try PairingLink(url: url)
            connect(using: link)
        } catch {
            failImageImport(with: error)
        }
    }

    func importPairingImage(_ imageData: Data) {
        isShowingScanner = false
        phase = .connecting
        status = "Reading the shared QR"
        errorText = nil

        Task {
            do {
                let link = try await Task.detached(priority: .userInitiated) {
                    try PairingQRCodeDecoder.decode(imageData)
                }.value
                connect(using: link)
            } catch {
                failImageImport(with: error)
            }
        }
    }

    func failImageImport(with error: Error) {
        phase = .unpaired
        errorText = error.localizedDescription
        status = "Generate a fresh QR on the Mac and try again"
    }

    func forgetMac() {
        bridge.stop()
        PairingKeychain.remove()
        credentials = nil
        phase = .unpaired
        errorText = nil
        status = "Generate a pairing QR on your Mac"
        watchTransfer.clear()
    }

    func resendToWatch() {
        guard credentials?.clientID != nil else { return }
        watchTransfer.resend()
    }

    private func handle(_ envelope: WireEnvelope) {
        switch envelope.kind {
        case .paired:
            phase = .paired
            errorText = nil
            status = envelope.message ?? "Paired and sent to Apple Watch"
            bridge.stop()
        case .error:
            phase = .unpaired
            errorText = envelope.message ?? "Pairing failed"
        default:
            break
        }
    }

    private func importPairingImage(at url: URL) {
        phase = .connecting
        status = "Reading the shared QR"
        errorText = nil

        Task {
            do {
                let imageData = try await Task.detached(priority: .userInitiated) {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                        throw PairingQRCodeError.unreadableImage
                    }
                    return data
                }.value
                let link = try await Task.detached(priority: .userInitiated) {
                    try PairingQRCodeDecoder.decode(imageData)
                }.value
                connect(using: link)
            } catch {
                failImageImport(with: error)
            }
        }
    }

    private func connect(using link: PairingLink) {
        let credentials = PairingCredentials(pairingLink: link)
        self.credentials = credentials
        phase = .connecting
        status = "Verifying \(link.serviceName)"
        errorText = nil
        bridge.stop()
        bridge.start(credentials: credentials, deviceName: UIDevice.current.name)
    }
}
