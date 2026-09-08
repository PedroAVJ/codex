import CodexVoiceProtocol
import CryptoKit
import Foundation

final class BridgeServer {
    private let configuration: BridgeConfiguration
    private let codex: CodexAppServer
    private let openRouterAPIKey: String?
    private let pairingStore: PairingStore
    private let serverPrivateKey: P256.KeyAgreement.PrivateKey
    private let relayIdentity: RelayIdentity
    private let queue = DispatchQueue(label: "com.pedro.codexvoice.bridge")
    private var relayClient: RelayHostClient?
    private var relayConnections: [String: RelayPacketConnection] = [:]
    private var relayCloseWorkItems: [String: DispatchWorkItem] = [:]
    private var relayOutageWorkItem: DispatchWorkItem?
    private var sessions: [UUID: BridgeSession] = [:]
    private var pendingApprovals: [Int: PendingApproval] = [:]
    private var nextApprovalID = 1

    init(configuration: BridgeConfiguration) throws {
        self.configuration = configuration
        self.pairingStore = try PairingStore(supportDirectory: configuration.supportDirectory)
        self.serverPrivateKey = try pairingStore.serverPrivateKey()
        self.relayIdentity = try RelayIdentityStore(supportDirectory: configuration.supportDirectory)
            .loadOrCreate(relayURL: configuration.relayURL.absoluteString)
        self.codex = CodexAppServer(executable: configuration.codexExecutable)
        self.openRouterAPIKey = OpenRouterAPIKeyStore.load()
        self.codex.onNotification = { [weak self] method, params in
            self?.queue.async { self?.routeNotification(method: method, params: params) }
        }
        self.codex.onServerRequest = { [weak self] id, method, params in
            self?.queue.async { self?.routeServerRequest(id: id, method: method, params: params) }
        }
    }

    func start() {
        BridgeTelemetry.stage("codex_control_socket_connecting", attributes: [
            "transport": "unix_websocket",
        ])
        codex.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                BridgeTelemetry.failure("codex_control_socket_connect", error: error)
                BridgeTelemetry.flush()
                fputs("Could not connect to Codex: \(error.localizedDescription)\n", stderr)
                exit(1)
            case .success:
                BridgeTelemetry.stage("codex_control_socket_connected", attributes: [
                    "transport": "unix_websocket",
                ])
                self.queue.async {
                    self.startRelay()
                }
            }
        }
    }

    func stop() {
        relayClient?.stop()
        queue.sync {
            relayClient = nil
            relayCloseWorkItems.values.forEach { $0.cancel() }
            relayCloseWorkItems.removeAll()
            relayOutageWorkItem?.cancel()
            relayOutageWorkItem = nil
            Array(relayConnections.values).forEach { $0.remoteClosed() }
            relayConnections.removeAll()
            sessions.values.forEach { $0.close() }
            sessions.removeAll()
            codex.stop()
        }
    }

    private func accept(_ connection: PacketConnection) {
        let session = BridgeSession(
            connection: connection,
            codex: codex,
            openRouterAPIKey: openRouterAPIKey,
            configuration: configuration,
            pairingStore: pairingStore,
            serverPrivateKey: serverPrivateKey,
            relayIdentity: relayIdentity,
            queue: queue
        )
        sessions[session.id] = session
        session.onClose = { [weak self] session in
            session.close()
            self?.sessions.removeValue(forKey: session.id)
            if let relayConnection = connection as? RelayPacketConnection {
                self?.relayCloseWorkItems.removeValue(forKey: relayConnection.channel)?.cancel()
                self?.relayConnections.removeValue(forKey: relayConnection.channel)
            }
        }
        session.onApprovalDecision = { [weak self] requestID, approved in
            self?.resolveApproval(requestID: requestID, approved: approved)
        }
        session.start()
    }

    private func startRelay() {
        let relay = RelayHostClient(
            endpoint: configuration.relayURL,
            identity: relayIdentity,
            serverPrivateKey: serverPrivateKey,
            queue: queue
        )
        relay.onPacket = { [weak self] channel, packet in
            self?.receiveRelayPacket(packet, channel: channel)
        }
        relay.onChannelClosed = { [weak self] channel in
            guard let self else { return }
            if let channel {
                self.scheduleRelayChannelClose(channel)
            }
        }
        relay.onLiveness = { [weak self] in
            self?.writeRelayState(
                connected: true,
                message: "Remote relay connected"
            )
        }
        relay.onState = { [weak self] connected, message in
            guard let self else { return }
            self.writeRelayState(connected: connected, message: message)
            if connected {
                BridgeTelemetry.stage("relay_connected")
                self.relayOutageWorkItem?.cancel()
                self.relayOutageWorkItem = nil
                print("\nCodex Voice bridge is ready")
                print("  Workspace: \(self.configuration.cwd)")
                print("  Remote relay: connected")
                print("  Pairing: run codex-voice-bridge pair\n")
                fflush(stdout)
            } else {
                BridgeTelemetry.warning("relay_disconnected")
                self.scheduleRelayOutageCleanup()
                fputs("Remote relay: \(message)\n", stderr)
            }
        }
        relayClient = relay
        relay.start()
    }

    private func receiveRelayPacket(_ packet: BridgePacket, channel: String) {
        relayCloseWorkItems.removeValue(forKey: channel)?.cancel()
        let connection: RelayPacketConnection
        if let existing = relayConnections[channel] {
            connection = existing
        } else {
            let created = RelayPacketConnection(
                channel: channel,
                sendPacket: { [weak self] channel, packet in
                    self?.relayClient?.send(packet, channel: channel)
                },
                closeChannel: { [weak self] channel in
                    self?.relayClient?.close(channel: channel)
                }
            )
            relayConnections[channel] = created
            accept(created)
            connection = created
        }
        connection.receive(packet)
    }

    private func scheduleRelayChannelClose(_ channel: String) {
        relayCloseWorkItems.removeValue(forKey: channel)?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.relayCloseWorkItems.removeValue(forKey: channel)
            self.relayConnections.removeValue(forKey: channel)?.remoteClosed()
        }
        relayCloseWorkItems[channel] = workItem
        queue.asyncAfter(deadline: .now() + 30, execute: workItem)
    }

    private func scheduleRelayOutageCleanup() {
        relayOutageWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.relayOutageWorkItem = nil
            let connections = Array(self.relayConnections.values)
            self.relayConnections.removeAll()
            connections.forEach { $0.remoteClosed() }
        }
        relayOutageWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 120, execute: workItem)
    }

    private func writeRelayState(connected: Bool, message: String) {
        let state: [String: Any] = [
            "connected": connected,
            "message": String(message.prefix(160)),
            "updatedAt": Int(Date().timeIntervalSince1970),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        let url = configuration.supportDirectory.appendingPathComponent("relay-state.json")
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            BridgeTelemetry.failure("relay_state_write", error: error)
            fputs("Could not write relay status: \(error.localizedDescription)\n", stderr)
        }
    }

    private func routeNotification(method: String, params: [String: Any]) {
        sessions.values.forEach { $0.receiveCodexNotification(method: method, params: params) }
    }

    private func routeServerRequest(id: Any, method: String, params: [String: Any]) {
        guard let threadID = params["threadId"] as? String,
              let session = sessions.values.first(where: { $0.threadID == threadID }) else {
            denyServerRequest(id: id, method: method)
            return
        }

        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "applyPatchApproval", "execCommandApproval":
            let requestID = nextApprovalID
            nextApprovalID += 1
            pendingApprovals[requestID] = PendingApproval(id: id, method: method)
            let reason = params["reason"] as? String
                ?? params["command"] as? String
                ?? "Your coding agent wants permission to continue."
            session.send(WireEnvelope(
                kind: .approval,
                threadId: threadID,
                message: reason,
                requestId: requestID,
                title: method.contains("fileChange") || method.contains("Patch") ? "Change files?" : "Run command?"
            ))
        default:
            codex.sendErrorResponse(id: id, message: "This approval type is not supported by the Watch prototype")
        }
    }

    private func resolveApproval(requestID: Int, approved: Bool) {
        guard let pending = pendingApprovals.removeValue(forKey: requestID) else { return }
        let decision: String
        switch pending.method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            decision = approved ? "accept" : "decline"
        default:
            decision = approved ? "approved" : "denied"
        }
        codex.sendResponse(id: pending.id, result: ["decision": decision])
    }

    private func denyServerRequest(id: Any, method: String) {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            codex.sendResponse(id: id, result: ["decision": "decline"])
        case "applyPatchApproval", "execCommandApproval":
            codex.sendResponse(id: id, result: ["decision": "denied"])
        default:
            codex.sendErrorResponse(id: id, message: "No active Watch session can answer this request")
        }
    }
}

private struct PendingApproval {
    let id: Any
    let method: String
}
