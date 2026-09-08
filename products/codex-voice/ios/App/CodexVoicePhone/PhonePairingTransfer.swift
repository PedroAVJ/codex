import Foundation
import WatchConnectivity

final class PhonePairingTransfer: NSObject, WCSessionDelegate {
    enum State: Equatable {
        case unavailable
        case activating
        case watchNotPaired
        case watchAppNotInstalled
        case sending
        case synced
        case failed(String)

        var message: String {
            switch self {
            case .unavailable:
                "Apple Watch sync is unavailable on this iPhone."
            case .activating:
                "Preparing Apple Watch sync…"
            case .watchNotPaired:
                "Pair an Apple Watch with this iPhone first."
            case .watchAppNotInstalled:
                "Install Pedro Voice Agent from the Watch app on this iPhone."
            case .sending:
                "Sending the secure Mac identity to Apple Watch…"
            case .synced:
                "Apple Watch confirmed the secure Mac identity."
            case .failed(let message):
                message
            }
        }

        var isSynced: Bool { self == .synced }
    }

    var onStateChange: ((State) -> Void)?

    private let lock = NSLock()
    private var pendingCredentials: PairingCredentials?
    private var transferID: String?
    private var acknowledgedTransferID: String?

    func activate(credentials: PairingCredentials?) {
        updatePending(credentials, newTransfer: credentials != nil)
        guard WCSession.isSupported() else {
            report(.unavailable)
            return
        }
        report(.activating)
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func sync(_ credentials: PairingCredentials) {
        updatePending(credentials, newTransfer: true)
        sendPending(queueFallback: true)
    }

    func resend() {
        lock.lock()
        if pendingCredentials != nil {
            transferID = UUID().uuidString.lowercased()
            acknowledgedTransferID = nil
        }
        lock.unlock()
        sendPending(queueFallback: true)
    }

    func clear() {
        updatePending(nil, newTransfer: false)
        guard WCSession.isSupported() else { return }
        do {
            try WCSession.default.updateApplicationContext([:])
        } catch {
            report(.failed("Couldn’t clear the Apple Watch pairing state: \(error.localizedDescription)"))
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            report(.failed("Apple Watch sync could not start: \(error.localizedDescription)"))
            return
        }
        guard activationState == .activated else {
            report(.activating)
            return
        }
        sendPending(queueFallback: true)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        guard session.activationState == .activated else { return }
        sendPending(queueFallback: true)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receiveAcknowledgement(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveAcknowledgement(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        receiveAcknowledgement(userInfo)
    }

    private func updatePending(_ credentials: PairingCredentials?, newTransfer: Bool) {
        lock.lock()
        pendingCredentials = credentials
        transferID = newTransfer && credentials != nil ? UUID().uuidString.lowercased() : nil
        acknowledgedTransferID = nil
        lock.unlock()
    }

    private func snapshot() -> (PairingCredentials, String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let pendingCredentials, let transferID else { return nil }
        return (pendingCredentials, transferID)
    }

    private func sendPending(queueFallback: Bool) {
        guard WCSession.isSupported(), let (credentials, transferID) = snapshot() else { return }
        guard !isAcknowledged(transferID) else {
            report(.synced)
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            report(.activating)
            return
        }
        guard session.isPaired else {
            report(.watchNotPaired)
            return
        }
        guard session.isWatchAppInstalled else {
            report(.watchAppNotInstalled)
            return
        }
        guard let data = try? JSONEncoder().encode(credentials) else {
            report(.failed("Couldn’t prepare the secure Mac identity for Apple Watch."))
            return
        }

        let context: [String: Any] = [
            SecureBridgeProtocol.watchPairingContextKey: data,
            SecureBridgeProtocol.watchPairingTransferIDContextKey: transferID,
        ]
        do {
            try session.updateApplicationContext(context)
            reportSendingIfPending(transferID)
        } catch {
            report(.failed("Couldn’t send the secure Mac identity to Apple Watch: \(error.localizedDescription)"))
            return
        }

        if queueFallback && !hasOutstandingTransfer(id: transferID, in: session) {
            session.transferUserInfo(context)
        }
        if session.isReachable {
            session.sendMessage(context, replyHandler: receiveAcknowledgement) { [weak self] _ in
                self?.reportSendingIfPending(transferID)
            }
        }
    }

    private func hasOutstandingTransfer(id: String, in session: WCSession) -> Bool {
        session.outstandingUserInfoTransfers.contains { transfer in
            transfer.userInfo[SecureBridgeProtocol.watchPairingTransferIDContextKey] as? String == id
        }
    }

    private func receiveAcknowledgement(_ values: [String: Any]) {
        guard let acknowledgedID = values[SecureBridgeProtocol.watchPairingAcknowledgementContextKey] as? String,
              let (_, expectedID) = snapshot(),
              acknowledgedID == expectedID else { return }
        lock.lock()
        acknowledgedTransferID = acknowledgedID
        lock.unlock()
        report(.synced)
    }

    private func isAcknowledged(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acknowledgedTransferID == id
    }

    private func reportSendingIfPending(_ id: String) {
        guard !isAcknowledged(id) else { return }
        report(.sending)
    }

    private func report(_ state: State) {
        NSLog("Codex Voice Phone Watch sync: %@", diagnosticName(state))
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }

    private func diagnosticName(_ state: State) -> String {
        switch state {
        case .unavailable: "unavailable"
        case .activating: "activating"
        case .watchNotPaired: "watch not paired"
        case .watchAppNotInstalled: "Watch app not installed"
        case .sending: "sending"
        case .synced: "acknowledged"
        case .failed: "failed"
        }
    }
}
