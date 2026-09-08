import CryptoKit
import Foundation

struct BridgeTransportDiagnostic: Sendable {
    enum Level: String, Sendable {
        case info
        case warning
        case error
    }

    let code: String
    let level: Level
    var connectionID: String? = nil
    var deliveryID: String? = nil
    var sequence: Int? = nil
    var envelopeKind: String? = nil
    var deliveryOutcome: String? = nil
    var frameBytes: Int? = nil
    var payloadBytes: Int? = nil
    var latencyMilliseconds: Int? = nil
    var previousSequence: Int? = nil
    var audioTurnID: String? = nil
    var audioTurnSequence: Int? = nil
    var finalAudioSequence: Int? = nil
    var queueDepth: Int? = nil
    var queueBytes: Int? = nil
    var replayCount: Int? = nil
    var maximumMessageBytes: Int? = nil
    var readyState: Int? = nil
    var closeCode: Int? = nil
    var errorDomain: String? = nil
    var errorCode: Int? = nil
}

final class BridgeConnection: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private struct PendingDelivery {
        let kind: String
        let sequence: Int
        let sentAt: Date
        let payloadBytes: Int
    }

    private static let maximumWebSocketMessageBytes = 2 * 1_024 * 1_024
    private static let deliveryAcknowledgementCode = "delivery_ack"
    private static let deliveryAcknowledgementTimeout: TimeInterval = 12

    private let queue = DispatchQueue(label: "com.pedro.codexvoice.client.relay")
    private let delegateQueue: OperationQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var reconnectWorkItem: DispatchWorkItem?
    private var secureResponseWorkItem: DispatchWorkItem?
    private var credentials: PairingCredentials?
    private var deviceName = "Apple device"
    private var channel = UUID().uuidString.lowercased()
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var relayReady = false
    private var sessionKey: SymmetricKey?
    private var acknowledgementKey: SymmetricKey?
    private var clientNonce: Data?
    private var connectionID = UUID().uuidString.lowercased()
    private var nextOutboundSequence = 0
    private var lastInboundSequence: Int?
    private var pendingDeliveries: [String: PendingDelivery] = [:]
    private var reliableAudioTurnsNegotiated = false
    private var reliableAudioTurnBuffer = ReliableAudioTurnBuffer()
    private var pendingAudioTurnAbort = false
    private var reliableAudioTurnIsAborted = false

    var onEnvelope: ((WireEnvelope) -> String)?
    var onStatus: ((String) -> Void)?
    var onCredentialsUpdated: ((PairingCredentials) -> Void)?
    var onTransportDiagnostic: ((BridgeTransportDiagnostic) -> Void)?
    var onAudioTurnDeliveryFailed: ((String) -> Void)?

    override init() {
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.pedro.codexvoice.client.relay.delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue = delegateQueue
        super.init()
    }

    func start(credentials: PairingCredentials, deviceName: String) {
        queue.async {
            self.stopNow(sendClose: false)
            self.credentials = credentials
            self.deviceName = deviceName
            self.channel = credentials.clientID ?? UUID().uuidString.lowercased()
            self.shouldReconnect = true
            self.reconnectAttempt = 0
            self.nextOutboundSequence = 0
            self.lastInboundSequence = nil
            self.pendingDeliveries.removeAll(keepingCapacity: false)
            self.reliableAudioTurnsNegotiated = false
            self.reliableAudioTurnBuffer.reset()
            self.pendingAudioTurnAbort = false
            self.reliableAudioTurnIsAborted = false
            self.connect()
        }
    }

    func send(_ envelope: WireEnvelope) {
        queue.async {
            switch envelope.kind {
            case .audioInput:
                self.enqueueReliableAudio(envelope)
            case .commitAudio:
                self.enqueueReliableCommit(envelope)
            case .stop:
                self.reliableAudioTurnBuffer.reset()
                self.pendingAudioTurnAbort = false
                self.reliableAudioTurnIsAborted = false
                self.sendSecurely(envelope)
            default:
                self.sendSecurely(envelope)
            }
        }
    }

    func stop() {
        queue.async {
            self.shouldReconnect = false
            self.reliableAudioTurnBuffer.reset()
            self.pendingAudioTurnAbort = false
            self.reliableAudioTurnIsAborted = false
            self.stopNow(sendClose: true)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async {
            guard webSocketTask === self.task else { return }
            NSLog("Codex Voice relay: WebSocket opened")
            self.reportTransport(BridgeTransportDiagnostic(
                code: "websocket_opened",
                level: .info,
                connectionID: self.connectionID,
                maximumMessageBytes: webSocketTask.maximumMessageSize,
                readyState: webSocketTask.state.rawValue
            ))
            self.report("Securing the connection to your Mac")
            self.receiveNext(from: webSocketTask)
            self.schedulePing(for: webSocketTask)
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else { return }
        queue.async {
            guard webSocketTask === self.task else { return }
            NSLog("Codex Voice relay: waiting for network connectivity")
            self.reportTransport(BridgeTransportDiagnostic(
                code: "websocket_waiting_for_connectivity",
                level: .warning,
                connectionID: self.connectionID,
                maximumMessageBytes: webSocketTask.maximumMessageSize,
                readyState: webSocketTask.state.rawValue
            ))
            self.report("Waiting for a network connection")
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async {
            self.reportTransport(BridgeTransportDiagnostic(
                code: "websocket_closed",
                level: closeCode == .normalClosure || closeCode == .goingAway ? .warning : .error,
                connectionID: self.connectionID,
                frameBytes: reason?.count,
                maximumMessageBytes: webSocketTask.maximumMessageSize,
                readyState: webSocketTask.state.rawValue,
                closeCode: closeCode.rawValue
            ))
            self.connectionFailed(
                webSocketTask,
                message: reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Remote relay closed the connection"
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else { return }
        queue.async {
            if let error = error as NSError? {
                NSLog("Codex Voice relay: task ended (%@ %ld)", error.domain, error.code)
                self.reportTransport(BridgeTransportDiagnostic(
                    code: "websocket_task_failed",
                    level: .error,
                    connectionID: self.connectionID,
                    maximumMessageBytes: webSocketTask.maximumMessageSize,
                    readyState: webSocketTask.state.rawValue,
                    errorDomain: error.domain,
                    errorCode: error.code
                ))
            } else {
                self.reportTransport(BridgeTransportDiagnostic(
                    code: "websocket_task_completed",
                    level: .warning,
                    connectionID: self.connectionID,
                    maximumMessageBytes: webSocketTask.maximumMessageSize,
                    readyState: webSocketTask.state.rawValue
                ))
            }
            self.connectionFailed(
                webSocketTask,
                message: error?.localizedDescription ?? "Remote relay connection ended"
            )
        }
    }

    private func connect() {
        guard shouldReconnect, task == nil, let credentials else { return }
        guard var components = URLComponents(string: credentials.relayURL) else {
            scheduleReconnect(message: "The saved relay address is invalid")
            return
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "room", value: credentials.relayRoom),
            URLQueryItem(name: "role", value: RelayRole.device.rawValue),
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "auth", value: credentials.relayAuth),
            URLQueryItem(name: "server", value: credentials.serverPublicKey),
        ]
        guard let url = components.url else {
            scheduleReconnect(message: "The saved relay address is invalid")
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.relayAuth)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumWebSocketMessageBytes
        connectionID = UUID().uuidString.lowercased()
        urlSession = session
        self.task = task
        relayReady = false
        sessionKey = nil
        acknowledgementKey = nil
        clientNonce = nil
        reliableAudioTurnsNegotiated = false
        lastInboundSequence = nil
        pendingDeliveries.removeAll(keepingCapacity: false)
        reportTransport(BridgeTransportDiagnostic(
            code: "websocket_configured",
            level: .info,
            connectionID: connectionID,
            maximumMessageBytes: task.maximumMessageSize,
            readyState: task.state.rawValue
        ))
        report("Connecting to your Mac securely")
        task.resume()
    }

    private func beginHandshake() {
        guard let credentials,
              let privateKey = credentials.clientPrivateKeyValue,
              let serverPublicKey = credentials.serverPublicKeyValue,
              let clientPublicKey = credentials.clientPublicKey else {
            terminalFailure(message: "The saved pairing identity is invalid")
            return
        }
        let nonce = SecureBridgeProtocol.randomBytes(count: 32)
        clientNonce = nonce
        do {
            NSLog("Codex Voice relay: beginning encrypted Mac handshake")
            acknowledgementKey = try SecureBridgeProtocol.deriveKey(
                privateKey: privateKey,
                peerPublicKey: serverPublicKey,
                salt: nonce,
                context: "codex-voice-ack-v1"
            )
            sendPacket(BridgePacket(
                kind: .hello,
                clientID: credentials.clientID,
                clientPublicKey: clientPublicKey,
                clientNonce: nonce.base64URLEncodedString(),
                ticket: credentials.ticket
            ))
        } catch {
            failCurrent(message: "Could not start the secure handshake")
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        let relayMessage: RelayMessage
        do {
            relayMessage = try decoder.decode(RelayMessage.self, from: data)
        } catch {
            let source = error as NSError
            reportTransport(BridgeTransportDiagnostic(
                code: "relay_message_decode_failed",
                level: .error,
                connectionID: connectionID,
                frameBytes: data.count,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue,
                errorDomain: source.domain,
                errorCode: source.code
            ))
            terminalFailure(message: "The relay returned an invalid response")
            return
        }
        reportTransport(BridgeTransportDiagnostic(
            code: "relay_message_received",
            level: .info,
            connectionID: connectionID,
            deliveryID: relayMessage.deliveryId,
            sequence: relayMessage.sequence,
            envelopeKind: relayMessage.kind.rawValue,
            frameBytes: data.count,
            payloadBytes: relayMessage.payload.map { Data($0.utf8).count },
            maximumMessageBytes: task?.maximumMessageSize,
            readyState: task?.state.rawValue
        ))
        switch relayMessage.kind {
        case .ready:
            NSLog("Codex Voice relay: transport authenticated")
            relayReady = true
            reconnectAttempt = 0
            beginHandshake()
            scheduleSecureResponseTimeout(message: "Your Mac did not answer the secure handshake")
        case .frame:
            guard relayMessage.channel == channel,
                  let payload = relayMessage.payload,
                  let relayKey = credentials?.relayKeyValue else {
                reportTransport(BridgeTransportDiagnostic(
                    code: "relay_frame_rejected",
                    level: .error,
                    connectionID: connectionID,
                    deliveryID: relayMessage.deliveryId,
                    sequence: relayMessage.sequence,
                    frameBytes: data.count,
                    payloadBytes: relayMessage.payload.map { Data($0.utf8).count },
                    maximumMessageBytes: task?.maximumMessageSize,
                    readyState: task?.state.rawValue
                ))
                terminalFailure(message: "The encrypted relay response could not be verified")
                return
            }
            let packet: BridgePacket
            do {
                packet = try SecureBridgeProtocol.open(BridgePacket.self, from: payload, using: relayKey)
            } catch {
                let source = error as NSError
                reportTransport(BridgeTransportDiagnostic(
                    code: "relay_frame_open_failed",
                    level: .error,
                    connectionID: connectionID,
                    deliveryID: relayMessage.deliveryId,
                    sequence: relayMessage.sequence,
                    frameBytes: data.count,
                    payloadBytes: Data(payload.utf8).count,
                    maximumMessageBytes: task?.maximumMessageSize,
                    readyState: task?.state.rawValue,
                    errorDomain: source.domain,
                    errorCode: source.code
                ))
                terminalFailure(message: "The encrypted relay response could not be verified")
                return
            }
            if relayMessage.deliveryId != packet.deliveryId || relayMessage.sequence != packet.sequence {
                reportTransport(BridgeTransportDiagnostic(
                    code: "relay_delivery_metadata_mismatch",
                    level: .warning,
                    connectionID: connectionID,
                    deliveryID: packet.deliveryId ?? relayMessage.deliveryId,
                    sequence: packet.sequence ?? relayMessage.sequence,
                    frameBytes: data.count,
                    payloadBytes: Data(payload.utf8).count,
                    maximumMessageBytes: task?.maximumMessageSize,
                    readyState: task?.state.rawValue
                ))
            }
            secureResponseWorkItem?.cancel()
            secureResponseWorkItem = nil
            handle(
                packet,
                frameBytes: data.count,
                payloadBytes: Data(payload.utf8).count
            )
        case .close:
            if relayMessage.channel == nil || relayMessage.channel == channel {
                failCurrent(message: "Your Mac disconnected")
            }
        case .error:
            NSLog("Codex Voice relay: transport rejected the connection")
            terminalFailure(message: relayMessage.message ?? "The remote relay rejected the connection")
        }
    }

    private func handle(_ packet: BridgePacket, frameBytes: Int, payloadBytes: Int) {
        guard packet.version == SecureBridgeProtocol.version else {
            terminalFailure(message: "The Mac is using an incompatible bridge version")
            return
        }
        switch packet.kind {
        case .helloAck:
            finishHandshake(packet)
        case .sealed:
            guard let sessionKey, let payload = packet.data else {
                reportTransport(BridgeTransportDiagnostic(
                    code: "secure_envelope_rejected",
                    level: .error,
                    connectionID: connectionID,
                    deliveryID: packet.deliveryId,
                    sequence: packet.sequence,
                    frameBytes: frameBytes,
                    payloadBytes: payloadBytes,
                    maximumMessageBytes: task?.maximumMessageSize,
                    readyState: task?.state.rawValue
                ))
                terminalFailure(message: "The encrypted Mac response could not be verified")
                return
            }
            let envelope: WireEnvelope
            do {
                envelope = try SecureBridgeProtocol.open(WireEnvelope.self, from: payload, using: sessionKey)
            } catch {
                let source = error as NSError
                reportTransport(BridgeTransportDiagnostic(
                    code: "secure_envelope_open_failed",
                    level: .error,
                    connectionID: connectionID,
                    deliveryID: packet.deliveryId,
                    sequence: packet.sequence,
                    frameBytes: frameBytes,
                    payloadBytes: payloadBytes,
                    maximumMessageBytes: task?.maximumMessageSize,
                    readyState: task?.state.rawValue,
                    errorDomain: source.domain,
                    errorCode: source.code
                ))
                terminalFailure(message: "The encrypted Mac response could not be verified")
                return
            }
            if packet.deliveryId != envelope.deliveryId || packet.sequence != envelope.sequence {
                reportTransport(BridgeTransportDiagnostic(
                    code: "secure_delivery_metadata_mismatch",
                    level: .warning,
                    connectionID: connectionID,
                    deliveryID: envelope.deliveryId ?? packet.deliveryId,
                    sequence: envelope.sequence ?? packet.sequence,
                    envelopeKind: envelope.kind.rawValue,
                    frameBytes: frameBytes,
                    payloadBytes: payloadBytes,
                    maximumMessageBytes: task?.maximumMessageSize,
                    readyState: task?.state.rawValue
                ))
            }
            if isDeliveryAcknowledgement(envelope, from: "bridge.delivery") {
                handleDeliveryAcknowledgement(envelope)
                return
            }
            recordInboundSequence(envelope)
            reportTransport(BridgeTransportDiagnostic(
                code: "secure_envelope_received",
                level: .info,
                connectionID: connectionID,
                deliveryID: envelope.deliveryId,
                sequence: envelope.sequence,
                envelopeKind: envelope.kind.rawValue,
                frameBytes: frameBytes,
                payloadBytes: payloadBytes,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue
            ))
            NSLog("Codex Voice relay: received %@ envelope", envelope.kind.rawValue)
            if envelope.kind == .paired, let clientID = envelope.clientId, let relayAuth = envelope.relayAuth,
               var credentials {
                credentials.complete(clientID: clientID, relayAuth: relayAuth)
                self.credentials = credentials
                DispatchQueue.main.async { self.onCredentialsUpdated?(credentials) }
            }
            if envelope.kind == .paired {
                negotiateCapabilities(from: envelope)
            }
            DispatchQueue.main.async {
                let outcome = self.onEnvelope?(envelope) ?? "no_handler"
                self.queue.async {
                    self.sendDeliveryAcknowledgement(for: envelope, outcome: outcome)
                }
            }
        case .error:
            terminalFailure(message: packet.message ?? "The Mac rejected this device")
        default:
            terminalFailure(message: "The Mac sent an unexpected handshake response")
        }
    }

    private func finishHandshake(_ packet: BridgePacket) {
        guard let acknowledgementKey,
              let payload = packet.data,
              let acknowledgement = try? SecureBridgeProtocol.open(
                HandshakeAcknowledgement.self,
                from: payload,
                using: acknowledgementKey
              ),
              let serverNonce = Data(base64URLEncoded: acknowledgement.serverNonce),
              let clientNonce,
              let credentials,
              let privateKey = credentials.clientPrivateKeyValue,
              let serverPublicKey = credentials.serverPublicKeyValue else {
            terminalFailure(message: "The Mac identity did not match the pairing QR")
            return
        }
        do {
            NSLog("Codex Voice relay: Mac identity verified")
            var salt = Data()
            salt.append(clientNonce)
            salt.append(serverNonce)
            sessionKey = try SecureBridgeProtocol.deriveKey(
                privateKey: privateKey,
                peerPublicKey: serverPublicKey,
                salt: salt,
                context: "codex-voice-session-v1"
            )
            sendSecurely(WireEnvelope(
                kind: .pair,
                clientId: acknowledgement.clientID,
                deviceName: deviceName,
                capabilities: [ReliableAudioTurnProtocol.capability]
            ))
            scheduleSecureResponseTimeout(message: "Your Mac did not finish secure pairing")
        } catch {
            failCurrent(message: "Could not finish the secure handshake")
        }
    }

    private func sendSecurely(_ envelope: WireEnvelope) {
        guard relayReady, let sessionKey else {
            reportTransport(BridgeTransportDiagnostic(
                code: "secure_envelope_send_deferred",
                level: .warning,
                connectionID: connectionID,
                deliveryID: envelope.deliveryId,
                sequence: envelope.sequence,
                envelopeKind: envelope.kind.rawValue,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue
            ))
            return
        }
        do {
            var outbound = envelope
            let acknowledgement = isDeliveryAcknowledgement(outbound, from: "device.delivery")
            if !acknowledgement,
               (outbound.deliveryId == nil || outbound.sequence == nil) {
                nextOutboundSequence += 1
                outbound.deliveryId = UUID().uuidString.lowercased()
                outbound.sequence = nextOutboundSequence
                outbound.deliveryKind = outbound.kind.rawValue
            }
            if outbound.kind != .audioInput {
                NSLog("Codex Voice relay: sending %@ envelope", outbound.kind.rawValue)
            }
            let sealedEnvelope = try SecureBridgeProtocol.seal(outbound, using: sessionKey)
            let encodedBytes = Data(sealedEnvelope.utf8).count
            if !acknowledgement,
               let deliveryID = outbound.deliveryId,
               let sequence = outbound.sequence {
                let sentAt = Date()
                pendingDeliveries[deliveryID] = PendingDelivery(
                    kind: outbound.kind.rawValue,
                    sequence: sequence,
                    sentAt: sentAt,
                    payloadBytes: encodedBytes
                )
                scheduleDeliveryAcknowledgementTimeout(
                    deliveryID: deliveryID,
                    sentAt: sentAt
                )
            }
            reportTransport(BridgeTransportDiagnostic(
                code: acknowledgement ? "delivery_ack_sending" : "secure_envelope_sending",
                level: .info,
                connectionID: connectionID,
                deliveryID: outbound.deliveryId,
                sequence: outbound.sequence,
                envelopeKind: acknowledgement ? outbound.deliveryKind : outbound.kind.rawValue,
                deliveryOutcome: outbound.deliveryOutcome,
                payloadBytes: encodedBytes,
                audioTurnID: outbound.turnId,
                audioTurnSequence: outbound.turnSequence,
                finalAudioSequence: outbound.finalAudioSequence,
                queueDepth: outbound.turnId == nil ? nil : reliableAudioTurnBuffer.envelopeCount,
                queueBytes: outbound.turnId == nil ? nil : reliableAudioTurnBuffer.audioBytes,
                replayCount: outbound.turnId == nil ? nil : reliableAudioTurnBuffer.replayCount,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue
            ))
            sendPacket(BridgePacket(
                kind: .sealed,
                data: sealedEnvelope,
                deliveryId: outbound.deliveryId,
                sequence: outbound.sequence
            ))
        } catch {
            let source = error as NSError
            reportTransport(BridgeTransportDiagnostic(
                code: "secure_envelope_seal_failed",
                level: .error,
                connectionID: connectionID,
                deliveryID: envelope.deliveryId,
                sequence: envelope.sequence,
                envelopeKind: envelope.kind.rawValue,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue,
                errorDomain: source.domain,
                errorCode: source.code
            ))
            failCurrent(message: "Could not encrypt the request")
        }
    }

    private func sendPacket(_ packet: BridgePacket) {
        guard relayReady, let relayKey = credentials?.relayKeyValue else {
            reportTransport(BridgeTransportDiagnostic(
                code: "relay_packet_send_deferred",
                level: .warning,
                connectionID: connectionID,
                deliveryID: packet.deliveryId,
                sequence: packet.sequence,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue
            ))
            return
        }
        do {
            let payload = try SecureBridgeProtocol.seal(packet, using: relayKey)
            send(RelayMessage(
                kind: .frame,
                channel: channel,
                payload: payload,
                deliveryId: packet.deliveryId,
                sequence: packet.sequence
            ))
        } catch {
            let source = error as NSError
            reportTransport(BridgeTransportDiagnostic(
                code: "relay_packet_seal_failed",
                level: .error,
                connectionID: connectionID,
                deliveryID: packet.deliveryId,
                sequence: packet.sequence,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue,
                errorDomain: source.domain,
                errorCode: source.code
            ))
            failCurrent(message: "Could not encrypt the relay request")
        }
    }

    private func send(_ message: RelayMessage) {
        guard let task else {
            reportTransport(BridgeTransportDiagnostic(
                code: "websocket_send_dropped",
                level: .warning,
                connectionID: connectionID,
                deliveryID: message.deliveryId,
                sequence: message.sequence,
                envelopeKind: message.kind.rawValue
            ))
            return
        }
        let data: Data
        let text: String
        do {
            data = try encoder.encode(message)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            text = encoded
        } catch {
            let source = error as NSError
            reportTransport(BridgeTransportDiagnostic(
                code: "websocket_message_encode_failed",
                level: .error,
                connectionID: connectionID,
                deliveryID: message.deliveryId,
                sequence: message.sequence,
                envelopeKind: message.kind.rawValue,
                maximumMessageBytes: task.maximumMessageSize,
                readyState: task.state.rawValue,
                errorDomain: source.domain,
                errorCode: source.code
            ))
            return
        }
        reportTransport(BridgeTransportDiagnostic(
            code: "websocket_send_queued",
            level: .info,
            connectionID: connectionID,
            deliveryID: message.deliveryId,
            sequence: message.sequence,
            envelopeKind: message.kind.rawValue,
            frameBytes: data.count,
            payloadBytes: message.payload.map { Data($0.utf8).count },
            maximumMessageBytes: task.maximumMessageSize,
            readyState: task.state.rawValue
        ))
        task.send(.string(text)) { [weak self, weak task] error in
            guard let self, let task else { return }
            self.queue.async {
                if let error {
                    let source = error as NSError
                    self.reportTransport(BridgeTransportDiagnostic(
                        code: "websocket_send_failed",
                        level: .error,
                        connectionID: self.connectionID,
                        deliveryID: message.deliveryId,
                        sequence: message.sequence,
                        envelopeKind: message.kind.rawValue,
                        frameBytes: data.count,
                        payloadBytes: message.payload.map { Data($0.utf8).count },
                        maximumMessageBytes: task.maximumMessageSize,
                        readyState: task.state.rawValue,
                        errorDomain: source.domain,
                        errorCode: source.code
                    ))
                    self.connectionFailed(task, message: error.localizedDescription)
                } else {
                    self.reportTransport(BridgeTransportDiagnostic(
                        code: "websocket_send_completed",
                        level: .info,
                        connectionID: self.connectionID,
                        deliveryID: message.deliveryId,
                        sequence: message.sequence,
                        envelopeKind: message.kind.rawValue,
                        frameBytes: data.count,
                        payloadBytes: message.payload.map { Data($0.utf8).count },
                        maximumMessageBytes: task.maximumMessageSize,
                        readyState: task.state.rawValue
                    ))
                }
            }
        }
    }

    private func receiveNext(from task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            self.queue.async {
                guard task === self.task else { return }
                switch result {
                case .failure(let error):
                    let source = error as NSError
                    self.reportTransport(BridgeTransportDiagnostic(
                        code: "websocket_receive_failed",
                        level: .error,
                        connectionID: self.connectionID,
                        maximumMessageBytes: task.maximumMessageSize,
                        readyState: task.state.rawValue,
                        errorDomain: source.domain,
                        errorCode: source.code
                    ))
                    self.connectionFailed(task, message: error.localizedDescription)
                case .success(let message):
                    self.handle(message)
                    if task === self.task { self.receiveNext(from: task) }
                }
            }
        }
    }

    private func schedulePing(for task: URLSessionWebSocketTask) {
        queue.asyncAfter(deadline: .now() + 25) { [weak self, weak task] in
            guard let self, let task, task === self.task, self.shouldReconnect else { return }
            task.sendPing { [weak self, weak task] error in
                guard let self, let task else { return }
                self.queue.async {
                    if let error {
                        let source = error as NSError
                        self.reportTransport(BridgeTransportDiagnostic(
                            code: "websocket_ping_failed",
                            level: .error,
                            connectionID: self.connectionID,
                            maximumMessageBytes: task.maximumMessageSize,
                            readyState: task.state.rawValue,
                            errorDomain: source.domain,
                            errorCode: source.code
                        ))
                        self.connectionFailed(task, message: error.localizedDescription)
                    } else {
                        self.reportTransport(BridgeTransportDiagnostic(
                            code: "websocket_ping_completed",
                            level: .info,
                            connectionID: self.connectionID,
                            maximumMessageBytes: task.maximumMessageSize,
                            readyState: task.state.rawValue
                        ))
                        self.schedulePing(for: task)
                    }
                }
            }
        }
    }

    private func isDeliveryAcknowledgement(_ envelope: WireEnvelope, from role: String) -> Bool {
        envelope.kind == .status
            && envelope.code == Self.deliveryAcknowledgementCode
            && envelope.role == role
            && envelope.deliveryId != nil
            && envelope.sequence != nil
    }

    private func sendDeliveryAcknowledgement(for envelope: WireEnvelope, outcome: String) {
        guard let deliveryID = envelope.deliveryId,
              let sequence = envelope.sequence else { return }
        sendSecurely(WireEnvelope(
            kind: .status,
            code: Self.deliveryAcknowledgementCode,
            role: "device.delivery",
            deliveryId: deliveryID,
            sequence: sequence,
            deliveryKind: envelope.kind.rawValue,
            deliveryOutcome: String(outcome.prefix(80))
        ))
    }

    private func handleDeliveryAcknowledgement(_ envelope: WireEnvelope) {
        guard let deliveryID = envelope.deliveryId,
              let sequence = envelope.sequence else { return }
        let queuedTurnID = reliableAudioTurnBuffer.turnID
        let queuedEnvelopeCount = reliableAudioTurnBuffer.envelopeCount
        let queuedAudioBytes = reliableAudioTurnBuffer.audioBytes
        let queuedReplayCount = reliableAudioTurnBuffer.replayCount
        let audioAcknowledgement = reliableAudioTurnBuffer.acknowledge(
            deliveryID: deliveryID,
            outcome: envelope.deliveryOutcome
        )
        guard let pending = pendingDeliveries.removeValue(forKey: deliveryID) else {
            reportTransport(BridgeTransportDiagnostic(
                code: "delivery_ack_unmatched",
                level: .warning,
                connectionID: connectionID,
                deliveryID: deliveryID,
                sequence: sequence,
                envelopeKind: envelope.deliveryKind,
                deliveryOutcome: envelope.deliveryOutcome,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue
            ))
            handleReliableAudioAcknowledgement(
                audioAcknowledgement,
                turnID: queuedTurnID,
                envelopeCount: queuedEnvelopeCount,
                audioBytes: queuedAudioBytes,
                replayCount: queuedReplayCount
            )
            return
        }
        reportTransport(BridgeTransportDiagnostic(
            code: "delivery_ack_received",
            level: pending.sequence == sequence ? .info : .warning,
            connectionID: connectionID,
            deliveryID: deliveryID,
            sequence: sequence,
            envelopeKind: pending.kind,
            deliveryOutcome: envelope.deliveryOutcome,
            payloadBytes: pending.payloadBytes,
            latencyMilliseconds: Int(Date().timeIntervalSince(pending.sentAt) * 1_000),
            audioTurnID: queuedTurnID,
            queueDepth: queuedTurnID == nil ? nil : queuedEnvelopeCount,
            queueBytes: queuedTurnID == nil ? nil : queuedAudioBytes,
            replayCount: queuedTurnID == nil ? nil : queuedReplayCount,
            maximumMessageBytes: task?.maximumMessageSize,
            readyState: task?.state.rawValue
        ))
        handleReliableAudioAcknowledgement(
            audioAcknowledgement,
            turnID: queuedTurnID,
            envelopeCount: queuedEnvelopeCount,
            audioBytes: queuedAudioBytes,
            replayCount: queuedReplayCount
        )
    }

    private func enqueueReliableAudio(_ envelope: WireEnvelope) {
        guard !reliableAudioTurnIsAborted else { return }
        let turnID = reliableAudioTurnBuffer.turnID ?? UUID().uuidString.lowercased()
        nextOutboundSequence += 1
        let result = reliableAudioTurnBuffer.appendAudio(
            envelope,
            turnID: turnID,
            deliveryID: UUID().uuidString.lowercased(),
            deliverySequence: nextOutboundSequence,
            now: ProcessInfo.processInfo.systemUptime
        )
        switch result {
        case .accepted(let outbound):
            if outbound.turnSequence == 1 {
                reportAudioTurnState(code: "audio_turn_buffer_started", level: .info)
            }
            drainReliableAudioTurn()
        case .rejected(let rejection):
            abortReliableAudioTurn(reason: rejection.rawValue)
        }
    }

    private func enqueueReliableCommit(_ envelope: WireEnvelope) {
        guard !reliableAudioTurnIsAborted else { return }
        nextOutboundSequence += 1
        let result = reliableAudioTurnBuffer.appendCommit(
            envelope,
            deliveryID: UUID().uuidString.lowercased(),
            deliverySequence: nextOutboundSequence,
            now: ProcessInfo.processInfo.systemUptime
        )
        switch result {
        case .accepted:
            reportAudioTurnState(code: "audio_turn_commit_buffered", level: .info)
            drainReliableAudioTurn()
        case .rejected(let rejection):
            abortReliableAudioTurn(reason: rejection.rawValue)
        }
    }

    private func negotiateCapabilities(from envelope: WireEnvelope) {
        reliableAudioTurnsNegotiated = envelope.capabilities?.contains(
            ReliableAudioTurnProtocol.capability
        ) == true
        reportTransport(BridgeTransportDiagnostic(
            code: reliableAudioTurnsNegotiated
                ? "reliable_audio_turns_negotiated"
                : "reliable_audio_turns_unavailable",
            level: reliableAudioTurnsNegotiated ? .info : .warning,
            connectionID: connectionID,
            audioTurnID: reliableAudioTurnBuffer.turnID,
            queueDepth: reliableAudioTurnBuffer.envelopeCount,
            queueBytes: reliableAudioTurnBuffer.audioBytes,
            replayCount: reliableAudioTurnBuffer.replayCount,
            maximumMessageBytes: task?.maximumMessageSize,
            readyState: task?.state.rawValue
        ))
        guard reliableAudioTurnsNegotiated else {
            if reliableAudioTurnBuffer.turnID != nil {
                abortReliableAudioTurn(reason: "bridge_capability_unavailable")
            }
            return
        }
        if pendingAudioTurnAbort {
            pendingAudioTurnAbort = false
            sendSecurely(WireEnvelope(kind: .stop, code: "audio_delivery_aborted"))
        }
        drainReliableAudioTurn()
    }

    private func drainReliableAudioTurn() {
        guard relayReady, sessionKey != nil, reliableAudioTurnsNegotiated else { return }
        let previousReplayCount = reliableAudioTurnBuffer.replayCount
        let envelopes = reliableAudioTurnBuffer.pendingEnvelopes(for: connectionID)
        guard !envelopes.isEmpty else { return }
        let replaying = reliableAudioTurnBuffer.replayCount > previousReplayCount
        reportAudioTurnState(
            code: replaying ? "audio_turn_replay_started" : "audio_turn_drain_started",
            level: replaying ? .warning : .info
        )
        for envelope in envelopes {
            guard let deliveryID = envelope.deliveryId else { continue }
            reliableAudioTurnBuffer.markSent(
                deliveryID: deliveryID,
                connectionID: connectionID
            )
            sendSecurely(envelope)
        }
    }

    private func handleReliableAudioAcknowledgement(
        _ result: ReliableAudioTurnBuffer.AcknowledgementResult,
        turnID: String?,
        envelopeCount: Int,
        audioBytes: Int,
        replayCount: Int
    ) {
        switch result {
        case .retained, .unmatched:
            return
        case .turnCompleted(let completedTurnID):
            pendingDeliveries = pendingDeliveries.filter { _, delivery in
                delivery.kind != WireEnvelope.Kind.audioInput.rawValue
                    && delivery.kind != WireEnvelope.Kind.commitAudio.rawValue
            }
            reportTransport(BridgeTransportDiagnostic(
                code: "audio_turn_delivery_completed",
                level: .info,
                connectionID: connectionID,
                audioTurnID: completedTurnID,
                queueDepth: envelopeCount,
                queueBytes: audioBytes,
                replayCount: replayCount,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue
            ))
        case .replayRequired(let replayTurnID, let outcome):
            reportTransport(BridgeTransportDiagnostic(
                code: "audio_turn_replay_required",
                level: .warning,
                connectionID: connectionID,
                deliveryOutcome: outcome,
                audioTurnID: replayTurnID,
                queueDepth: envelopeCount,
                queueBytes: audioBytes,
                replayCount: replayCount + 1,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue
            ))
            drainReliableAudioTurn()
        case .turnRejected(let rejectedTurnID, let outcome):
            reliableAudioTurnIsAborted = true
            reportTransport(BridgeTransportDiagnostic(
                code: "audio_turn_commit_rejected",
                level: .error,
                connectionID: connectionID,
                deliveryOutcome: outcome,
                audioTurnID: rejectedTurnID,
                queueDepth: envelopeCount,
                queueBytes: audioBytes,
                replayCount: replayCount,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue
            ))
            if relayReady, sessionKey != nil, reliableAudioTurnsNegotiated {
                sendSecurely(WireEnvelope(kind: .stop, code: "audio_delivery_aborted"))
            } else {
                pendingAudioTurnAbort = true
            }
            notifyAudioTurnDeliveryFailed("The recording reached the Mac but could not be committed. Please try again.")
        }
    }

    private func abortReliableAudioTurn(reason: String) {
        let turnID = reliableAudioTurnBuffer.turnID
        let envelopeCount = reliableAudioTurnBuffer.envelopeCount
        let audioBytes = reliableAudioTurnBuffer.audioBytes
        let replayCount = reliableAudioTurnBuffer.replayCount
        reliableAudioTurnBuffer.reset()
        pendingAudioTurnAbort = true
        reliableAudioTurnIsAborted = true
        reportTransport(BridgeTransportDiagnostic(
            code: "audio_turn_delivery_aborted",
            level: .error,
            connectionID: connectionID,
            deliveryOutcome: String(reason.prefix(80)),
            audioTurnID: turnID,
            queueDepth: envelopeCount,
            queueBytes: audioBytes,
            replayCount: replayCount,
            maximumMessageBytes: task?.maximumMessageSize,
            readyState: task?.state.rawValue
        ))
        if relayReady, sessionKey != nil, reliableAudioTurnsNegotiated {
            pendingAudioTurnAbort = false
            sendSecurely(WireEnvelope(kind: .stop, code: "audio_delivery_aborted"))
        }
        notifyAudioTurnDeliveryFailed("The Watch could not preserve the full recording. Please try again.")
    }

    private func notifyAudioTurnDeliveryFailed(_ message: String) {
        DispatchQueue.main.async { self.onAudioTurnDeliveryFailed?(message) }
    }

    private func reportAudioTurnState(code: String, level: BridgeTransportDiagnostic.Level) {
        reportTransport(BridgeTransportDiagnostic(
            code: code,
            level: level,
            connectionID: connectionID,
            audioTurnID: reliableAudioTurnBuffer.turnID,
            queueDepth: reliableAudioTurnBuffer.envelopeCount,
            queueBytes: reliableAudioTurnBuffer.audioBytes,
            replayCount: reliableAudioTurnBuffer.replayCount,
            maximumMessageBytes: task?.maximumMessageSize,
            readyState: task?.state.rawValue
        ))
    }

    private func recordInboundSequence(_ envelope: WireEnvelope) {
        guard let sequence = envelope.sequence else { return }
        if let lastInboundSequence, sequence != lastInboundSequence + 1 {
            reportTransport(BridgeTransportDiagnostic(
                code: "delivery_sequence_gap",
                level: .warning,
                connectionID: connectionID,
                deliveryID: envelope.deliveryId,
                sequence: sequence,
                envelopeKind: envelope.kind.rawValue,
                previousSequence: lastInboundSequence,
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue
            ))
        }
        if lastInboundSequence == nil || sequence > lastInboundSequence! {
            lastInboundSequence = sequence
        }
    }

    private func scheduleDeliveryAcknowledgementTimeout(deliveryID: String, sentAt: Date) {
        queue.asyncAfter(deadline: .now() + Self.deliveryAcknowledgementTimeout) { [weak self] in
            guard let self,
                  let pending = self.pendingDeliveries[deliveryID],
                  pending.sentAt == sentAt else { return }
            self.pendingDeliveries.removeValue(forKey: deliveryID)
            self.reportTransport(BridgeTransportDiagnostic(
                code: "delivery_ack_timeout",
                level: .error,
                connectionID: self.connectionID,
                deliveryID: deliveryID,
                sequence: pending.sequence,
                envelopeKind: pending.kind,
                payloadBytes: pending.payloadBytes,
                latencyMilliseconds: Int(Date().timeIntervalSince(pending.sentAt) * 1_000),
                maximumMessageBytes: self.task?.maximumMessageSize,
                readyState: self.task?.state.rawValue
            ))
        }
    }

    private func failCurrent(message: String) {
        guard let task else {
            scheduleReconnect(message: message)
            return
        }
        connectionFailed(task, message: message)
    }

    private func terminalFailure(message: String) {
        NSLog("Codex Voice relay: terminal handshake failure")
        shouldReconnect = false
        stopNow(sendClose: false)
        report(message)
        DispatchQueue.main.async {
            _ = self.onEnvelope?(WireEnvelope(kind: .error, message: message))
        }
    }

    private func connectionFailed(_ failedTask: URLSessionWebSocketTask, message: String) {
        guard failedTask === task else { return }
        reportTransport(BridgeTransportDiagnostic(
            code: "websocket_connection_failed",
            level: .error,
            connectionID: connectionID,
            maximumMessageBytes: failedTask.maximumMessageSize,
            readyState: failedTask.state.rawValue
        ))
        stopNow(sendClose: false)
        scheduleReconnect(message: message)
    }

    private func stopNow(sendClose: Bool) {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        secureResponseWorkItem?.cancel()
        secureResponseWorkItem = nil
        if sendClose, relayReady {
            send(RelayMessage(kind: .close, channel: channel))
        }
        if !pendingDeliveries.isEmpty {
            reportTransport(BridgeTransportDiagnostic(
                code: "delivery_pending_cancelled",
                level: .info,
                connectionID: connectionID,
                queueDepth: pendingDeliveries.count,
                queueBytes: pendingDeliveries.values.reduce(0) { $0 + $1.payloadBytes },
                maximumMessageBytes: task?.maximumMessageSize,
                readyState: task?.state.rawValue
            ))
            pendingDeliveries.removeAll(keepingCapacity: false)
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        relayReady = false
        sessionKey = nil
        acknowledgementKey = nil
        clientNonce = nil
        reliableAudioTurnsNegotiated = false
    }

    private func scheduleReconnect(message: String) {
        guard shouldReconnect else { return }
        NSLog("Codex Voice relay: reconnect scheduled (%@)", message)
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(min(reconnectAttempt - 1, 5))), 30)
        report("Mac unavailable; retrying securely")
        let workItem = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleSecureResponseTimeout(message: String) {
        secureResponseWorkItem?.cancel()
        guard let expectedTask = task else { return }
        let workItem = DispatchWorkItem { [weak self, weak expectedTask] in
            guard let self, let expectedTask, expectedTask === self.task else { return }
            NSLog("Codex Voice relay: secure response timed out")
            self.connectionFailed(expectedTask, message: message)
        }
        secureResponseWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 12, execute: workItem)
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.onStatus?(message) }
    }

    private func reportTransport(_ diagnostic: BridgeTransportDiagnostic) {
        DispatchQueue.main.async { self.onTransportDiagnostic?(diagnostic) }
    }
}
