import Foundation
import WatchConnectivity

final class WatchPairingReceiver: NSObject, WCSessionDelegate {
    var onCredentials: ((PairingCredentials, String?) -> Void)?
    var onStatus: ((String) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        receive(session.receivedApplicationContext)
        report("Waiting for the iPhone companion")
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
            receive(session.receivedApplicationContext)
            if session.isCompanionAppInstalled {
                report("Waiting for the iPhone companion to send the secure Mac identity")
            } else {
                report("Install Pedro Voice Agent on the paired iPhone")
            }
        } else if let error {
            report("Apple Watch sync failed: \(error.localizedDescription)")
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        receive(userInfo)
    }

    func acknowledge(transferID: String?) {
        guard let transferID, WCSession.isSupported() else { return }
        let session = WCSession.default
        let acknowledgement: [String: Any] = [
            SecureBridgeProtocol.watchPairingAcknowledgementContextKey: transferID,
        ]
        try? session.updateApplicationContext(acknowledgement)
        if !session.outstandingUserInfoTransfers.contains(where: {
            $0.userInfo[SecureBridgeProtocol.watchPairingAcknowledgementContextKey] as? String == transferID
        }) {
            session.transferUserInfo(acknowledgement)
        }
        if session.isReachable {
            session.sendMessage(acknowledgement, replyHandler: nil, errorHandler: nil)
        }
        NSLog("Codex Voice Watch pairing: acknowledgement queued")
    }

    private func receive(_ values: [String: Any]) {
        guard let data = values[SecureBridgeProtocol.watchPairingContextKey] as? Data,
              let credentials = try? JSONDecoder().decode(PairingCredentials.self, from: data) else { return }
        let transferID = values[SecureBridgeProtocol.watchPairingTransferIDContextKey] as? String
        NSLog("Codex Voice Watch pairing: secure credentials received")
        DispatchQueue.main.async { self.onCredentials?(credentials, transferID) }
    }

    private func report(_ message: String) {
        NSLog("Codex Voice Watch pairing: %@", message)
        DispatchQueue.main.async { [weak self] in self?.onStatus?(message) }
    }
}
