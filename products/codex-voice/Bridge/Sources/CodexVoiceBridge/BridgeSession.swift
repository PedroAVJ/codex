import CodexVoiceProtocol
import CryptoKit
import Foundation

final class BridgeSession {
    private struct PendingDelivery {
        let kind: String
        let sequence: Int
        let sentAt: Date
        let payloadBytes: Int
    }

    private static let maximumAudioBytes = 12 * 1024 * 1024
    private static let minimumAudioBytes = 24_000 / 5 * 2
    private static let deliveryAcknowledgementCode = "delivery_ack"
    private static let deliveryAcknowledgementTimeout: TimeInterval = 12

    let id = UUID()
    private let connection: PacketConnection
    private let codex: CodexAppServer
    private let openRouterAPIKey: String?
    private let configuration: BridgeConfiguration
    private let pairingStore: PairingStore
    private let serverPrivateKey: P256.KeyAgreement.PrivateKey
    private let relayIdentity: RelayIdentity
    private let queue: DispatchQueue
    private(set) var threadID: String?
    private var isPaired = false
    private var isCodexBusy = false
    private var audioBuffer = Data()
    private var audioChunkCount = 0
    private var assistantText = ""
    private var sessionKey: SymmetricKey?
    private var pendingTicket: String?
    private var pendingClientID: String?
    private var pendingClientPublicKey: String?
    private var voiceSession: OpenRouterVoiceSession?
    private var voiceReady = false
    private var pendingCodexCallID: String?
    private var hasReportedFirstAudioOutput = false
    private var codexThreadStartGate = CodexThreadStartGate()
    private var nextOutboundSequence = 0
    private var lastInboundSequence: Int?
    private var pendingDeliveries: [String: PendingDelivery] = [:]
    private var reliableAudioTurnsNegotiated = false
    private var reliableAudioTurnReceiver = ReliableAudioTurnReceiver()

    var onClose: ((BridgeSession) -> Void)?
    var onApprovalDecision: ((Int, Bool) -> Void)?

    init(
        connection: PacketConnection,
        codex: CodexAppServer,
        openRouterAPIKey: String?,
        configuration: BridgeConfiguration,
        pairingStore: PairingStore,
        serverPrivateKey: P256.KeyAgreement.PrivateKey,
        relayIdentity: RelayIdentity,
        queue: DispatchQueue
    ) {
        self.connection = connection
        self.codex = codex
        self.openRouterAPIKey = openRouterAPIKey
        self.configuration = configuration
        self.pairingStore = pairingStore
        self.serverPrivateKey = serverPrivateKey
        self.relayIdentity = relayIdentity
        self.queue = queue
        self.connection.onPacket = { [weak self] packet in self?.handle(packet) }
        self.connection.onClose = { [weak self] in
            guard let self else { return }
            self.onClose?(self)
        }
    }

    func start() {
        BridgeTelemetry.stage("bridge_session_started")
        connection.start()
    }

    func close() {
        BridgeTelemetry.stage("bridge_session_closed")
        voiceSession?.stop()
        voiceSession = nil
        voiceReady = false
        audioBuffer.removeAll(keepingCapacity: false)
        audioChunkCount = 0
        hasReportedFirstAudioOutput = false
        pendingDeliveries.removeAll(keepingCapacity: false)
        reliableAudioTurnsNegotiated = false
        reliableAudioTurnReceiver.cancelActiveTurn()
    }

    func send(_ envelope: WireEnvelope) {
        guard let sessionKey else {
            BridgeTelemetry.warning("secure_envelope_send_deferred", attributes: [
                "envelope_kind": envelope.kind.rawValue,
            ])
            return
        }
        do {
            var outbound = envelope
            let acknowledgement = isDeliveryAcknowledgement(outbound, from: "bridge.delivery")
            if !acknowledgement {
                nextOutboundSequence += 1
                outbound.deliveryId = UUID().uuidString.lowercased()
                outbound.sequence = nextOutboundSequence
                outbound.deliveryKind = outbound.kind.rawValue
            }
            let sealedEnvelope = try SecureBridgeProtocol.seal(outbound, using: sessionKey)
            let payloadBytes = Data(sealedEnvelope.utf8).count
            if !acknowledgement,
               let deliveryID = outbound.deliveryId,
               let sequence = outbound.sequence {
                pendingDeliveries[deliveryID] = PendingDelivery(
                    kind: outbound.kind.rawValue,
                    sequence: sequence,
                    sentAt: Date(),
                    payloadBytes: payloadBytes
                )
                scheduleDeliveryAcknowledgementTimeout(deliveryID: deliveryID)
            }
            BridgeTelemetry.stage(
                acknowledgement ? "delivery_ack_sending" : "secure_envelope_sending",
                attributes: deliveryAttributes(
                    deliveryID: outbound.deliveryId,
                    sequence: outbound.sequence,
                    kind: acknowledgement ? outbound.deliveryKind : outbound.kind.rawValue,
                    outcome: outbound.deliveryOutcome,
                    payloadBytes: payloadBytes
                )
            )
            connection.send(BridgePacket(
                kind: .sealed,
                data: sealedEnvelope,
                deliveryId: outbound.deliveryId,
                sequence: outbound.sequence
            ))
        } catch {
            BridgeTelemetry.failure("encrypt_response", error: error)
            connection.send(BridgePacket(kind: .error, message: "Could not encrypt bridge response"))
            connection.close()
        }
    }

    func receiveCodexNotification(method: String, params: [String: Any]) {
        guard let expectedThread = threadID,
              (params["threadId"] as? String) == expectedThread else { return }

        switch method {
        case "turn/started":
            send(WireEnvelope(kind: .status, threadId: expectedThread, message: "Your agent is working"))
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String else { return }
            assistantText += delta
        case "turn/completed":
            finishCodexTurn(params: params, threadID: expectedThread)
        default:
            break
        }
    }

    private func handle(_ packet: BridgePacket) {
        guard packet.version == SecureBridgeProtocol.version else {
            connection.send(BridgePacket(kind: .error, message: "Unsupported bridge protocol version"))
            connection.close()
            return
        }

        switch packet.kind {
        case .hello:
            if sessionKey != nil {
                // A relay Function has a finite lifetime. Re-negotiate only the
                // transport keys while preserving the active Codex/voice session.
                sessionKey = nil
                pendingTicket = nil
                pendingClientID = nil
                pendingClientPublicKey = nil
                isPaired = false
                codexThreadStartGate.reset()
            }
            handleHello(packet)
        case .sealed:
            guard let sessionKey, let data = packet.data else {
                connection.send(BridgePacket(kind: .error, message: "Secure bridge authentication failed"))
                connection.close()
                return
            }
            let envelope: WireEnvelope
            do {
                envelope = try SecureBridgeProtocol.open(WireEnvelope.self, from: data, using: sessionKey)
            } catch {
                BridgeTelemetry.failure("decrypt_request", error: error)
                connection.send(BridgePacket(kind: .error, message: "Secure bridge authentication failed"))
                connection.close()
                return
            }
            if packet.deliveryId != envelope.deliveryId || packet.sequence != envelope.sequence {
                BridgeTelemetry.warning("secure_delivery_metadata_mismatch", attributes: deliveryAttributes(
                    deliveryID: envelope.deliveryId ?? packet.deliveryId,
                    sequence: envelope.sequence ?? packet.sequence,
                    kind: envelope.kind.rawValue,
                    payloadBytes: Data(data.utf8).count
                ))
            }
            if isDeliveryAcknowledgement(envelope, from: "device.delivery") {
                handleDeliveryAcknowledgement(envelope)
                return
            }
            recordInboundSequence(envelope)
            BridgeTelemetry.stage("secure_envelope_received", attributes: deliveryAttributes(
                deliveryID: envelope.deliveryId,
                sequence: envelope.sequence,
                kind: envelope.kind.rawValue,
                payloadBytes: Data(data.utf8).count
            ))
            let outcome = handle(envelope)
            sendDeliveryAcknowledgement(for: envelope, outcome: outcome)
        default:
            connection.send(BridgePacket(kind: .error, message: "Unexpected secure bridge packet"))
            connection.close()
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
        send(WireEnvelope(
            kind: .status,
            code: Self.deliveryAcknowledgementCode,
            role: "bridge.delivery",
            deliveryId: deliveryID,
            sequence: sequence,
            deliveryKind: envelope.kind.rawValue,
            deliveryOutcome: outcome
        ))
    }

    private func handleDeliveryAcknowledgement(_ envelope: WireEnvelope) {
        guard let deliveryID = envelope.deliveryId,
              let sequence = envelope.sequence else { return }
        guard let pending = pendingDeliveries.removeValue(forKey: deliveryID) else {
            BridgeTelemetry.warning("delivery_ack_unmatched", attributes: deliveryAttributes(
                deliveryID: deliveryID,
                sequence: sequence,
                kind: envelope.deliveryKind,
                outcome: envelope.deliveryOutcome
            ))
            return
        }
        var attributes = deliveryAttributes(
            deliveryID: deliveryID,
            sequence: sequence,
            kind: pending.kind,
            outcome: envelope.deliveryOutcome,
            payloadBytes: pending.payloadBytes
        )
        attributes["delivery_latency_ms"] = Int(Date().timeIntervalSince(pending.sentAt) * 1_000)
        attributes["delivery_sequence_matches"] = pending.sequence == sequence
        BridgeTelemetry.stage("watch_delivery_acknowledged", attributes: attributes)
        logAudio(
            "delivery_acknowledged kind=\(pending.kind) sequence=\(sequence) id=\(deliveryID) outcome=\(envelope.deliveryOutcome ?? "unknown")"
        )
    }

    private func recordInboundSequence(_ envelope: WireEnvelope) {
        guard let sequence = envelope.sequence else { return }
        if let previous = lastInboundSequence, sequence != previous + 1 {
            var attributes = deliveryAttributes(
                deliveryID: envelope.deliveryId,
                sequence: sequence,
                kind: envelope.kind.rawValue
            )
            attributes["previous_delivery_sequence"] = previous
            BridgeTelemetry.warning("device_delivery_sequence_gap", attributes: attributes)
        }
        if lastInboundSequence == nil || sequence > lastInboundSequence! {
            lastInboundSequence = sequence
        }
    }

    private func scheduleDeliveryAcknowledgementTimeout(deliveryID: String) {
        queue.asyncAfter(deadline: .now() + Self.deliveryAcknowledgementTimeout) { [weak self] in
            guard let self,
                  let pending = self.pendingDeliveries.removeValue(forKey: deliveryID) else { return }
            var attributes = self.deliveryAttributes(
                deliveryID: deliveryID,
                sequence: pending.sequence,
                kind: pending.kind,
                payloadBytes: pending.payloadBytes
            )
            attributes["delivery_timeout_ms"] = Int(Date().timeIntervalSince(pending.sentAt) * 1_000)
            BridgeTelemetry.warning("watch_delivery_ack_timeout", attributes: attributes)
            self.logAudio(
                "delivery_ack_timeout kind=\(pending.kind) sequence=\(pending.sequence) id=\(deliveryID) payload_bytes=\(pending.payloadBytes)"
            )
        }
    }

    private func deliveryAttributes(
        deliveryID: String?,
        sequence: Int?,
        kind: String?,
        outcome: String? = nil,
        payloadBytes: Int? = nil
    ) -> [String: Any] {
        var attributes: [String: Any] = [:]
        if let deliveryID { attributes["delivery_id"] = deliveryID }
        if let sequence { attributes["delivery_sequence"] = sequence }
        if let kind { attributes["envelope_kind"] = kind }
        if let outcome { attributes["delivery_outcome"] = String(outcome.prefix(80)) }
        if let payloadBytes { attributes["payload_bytes"] = payloadBytes }
        return attributes
    }

    private func deliveryOutcome(for envelope: WireEnvelope) -> String {
        switch envelope.kind {
        case .audioInput: "audio_input_processed"
        case .commitAudio: "commit_processed"
        case .status: "diagnostic_processed"
        case .start: "start_processed"
        case .pair: "pair_processed"
        case .stop: "stop_processed"
        default: "bridge_handler_completed"
        }
    }

    private func handleHello(_ packet: BridgePacket) {
        guard sessionKey == nil,
              let clientPublicKeyValue = packet.clientPublicKey,
              let clientPublicKeyData = Data(base64URLEncoded: clientPublicKeyValue),
              let clientPublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: clientPublicKeyData),
              let clientNonceValue = packet.clientNonce,
              let clientNonce = Data(base64URLEncoded: clientNonceValue),
              clientNonce.count == 32 else {
            connection.send(BridgePacket(kind: .error, message: "Invalid secure bridge handshake"))
            connection.close()
            return
        }

        let isNewPairing: Bool
        let clientID: String
        if let ticket = packet.ticket, pairingStore.hasValidTicket(ticket) {
            isNewPairing = true
            clientID = UUID().uuidString.lowercased()
            pendingTicket = ticket
        } else if let requestedID = packet.clientID,
                  let device = pairingStore.device(id: requestedID),
                  device.publicKey == clientPublicKeyValue {
            isNewPairing = false
            clientID = requestedID
        } else {
            connection.send(BridgePacket(kind: .error, message: "This device is not paired"))
            connection.close()
            return
        }

        do {
            let acknowledgementKey = try SecureBridgeProtocol.deriveKey(
                privateKey: serverPrivateKey,
                peerPublicKey: clientPublicKey,
                salt: clientNonce,
                context: "codex-voice-ack-v1"
            )
            let serverNonce = SecureBridgeProtocol.randomBytes(count: 32)
            let acknowledgement = HandshakeAcknowledgement(
                clientID: clientID,
                serverNonce: serverNonce.base64URLEncodedString(),
                serverName: configuration.serviceName,
                isNewPairing: isNewPairing
            )
            var sessionSalt = Data()
            sessionSalt.append(clientNonce)
            sessionSalt.append(serverNonce)
            sessionKey = try SecureBridgeProtocol.deriveKey(
                privateKey: serverPrivateKey,
                peerPublicKey: clientPublicKey,
                salt: sessionSalt,
                context: "codex-voice-session-v1"
            )
            pendingClientID = clientID
            pendingClientPublicKey = clientPublicKeyValue
            connection.send(BridgePacket(
                kind: .helloAck,
                data: try SecureBridgeProtocol.seal(acknowledgement, using: acknowledgementKey)
            ))
        } catch {
            BridgeTelemetry.failure("secure_handshake", error: error)
            connection.send(BridgePacket(kind: .error, message: "Secure bridge handshake failed"))
            connection.close()
        }
    }

    private func handle(_ envelope: WireEnvelope) -> String {
        switch envelope.kind {
        case .pair:
            return completePairing(envelope)
        case .start:
            guard isPaired else {
                send(WireEnvelope(kind: .error, message: "Pair with the Mac first"))
                return "start_rejected_not_paired"
            }
            startCodexThread()
            return "start_processed"
        case .audioInput:
            return appendAudio(envelope)
        case .commitAudio:
            return commitAudio(envelope)
        case .status:
            logWatchCaptureDiagnostic(envelope)
            return "diagnostic_processed"
        case .stop:
            reliableAudioTurnReceiver.cancelActiveTurn()
            if envelope.code == "playback_barge_in" {
                BridgeTelemetry.cancelVoiceTurn("response_cancelled_by_playback_barge_in")
                logAudio("response_cancelled reason=playback_barge_in")
            }
            voiceSession?.cancelResponse()
            audioBuffer.removeAll(keepingCapacity: false)
            audioChunkCount = 0
            if isCodexBusy, let threadID {
                codex.sendRequest(method: "turn/interrupt", params: ["threadId": threadID]) { _ in }
            }
            isCodexBusy = false
            pendingCodexCallID = nil
            assistantText = ""
            send(WireEnvelope(kind: .ready, threadId: threadID, message: "Ready"))
            return "stop_processed"
        case .approvalDecision:
            if let requestID = envelope.requestId, let approved = envelope.approved {
                onApprovalDecision?(requestID, approved)
                return "approval_decision_processed"
            }
            return "approval_decision_rejected"
        case .ping:
            send(WireEnvelope(kind: .pong))
            return "ping_processed"
        default:
            return deliveryOutcome(for: envelope)
        }
    }

    private func completePairing(_ envelope: WireEnvelope) -> String {
        guard let clientID = pendingClientID,
              let clientPublicKey = pendingClientPublicKey,
              envelope.clientId == clientID else {
            send(WireEnvelope(kind: .error, message: "Secure pairing confirmation failed"))
            return "pair_rejected_identity"
        }
        let relayAuth: String
        do {
            relayAuth = try relayIdentity.accessToken(
                role: .device,
                clientID: clientID,
                expiresAt: Int(Date().addingTimeInterval(365 * 24 * 60 * 60).timeIntervalSince1970),
                serverPrivateKey: serverPrivateKey
            )
        } catch {
            send(WireEnvelope(kind: .error, message: "Could not authorise remote access for this device"))
            return "pair_rejected_relay_authorization"
        }

        if let ticket = pendingTicket {
            do {
                try pairingStore.consumeTicket(
                    ticket,
                    clientID: clientID,
                    publicKey: clientPublicKey,
                    deviceName: envelope.deviceName ?? "Apple device"
                )
                pendingTicket = nil
            } catch {
                send(WireEnvelope(kind: .error, message: error.localizedDescription))
                connection.close()
                return "pair_rejected_ticket"
            }
        }
        isPaired = true
        reliableAudioTurnsNegotiated = envelope.capabilities?.contains(
            ReliableAudioTurnProtocol.capability
        ) == true
        BridgeTelemetry.stage("pairing_completed")
        BridgeTelemetry.stage("audio_turn_capability_negotiated", attributes: [
            "reliable_audio_turns": reliableAudioTurnsNegotiated,
        ])
        send(WireEnvelope(
            kind: .paired,
            message: "Paired with \(configuration.serviceName)",
            clientId: clientID,
            relayAuth: relayAuth,
            capabilities: reliableAudioTurnsNegotiated
                ? [ReliableAudioTurnProtocol.capability]
                : []
        ))
        return "pair_processed"
    }

    private func startCodexThread() {
        guard threadID == nil else {
            guard let openRouterAPIKey else { return }
            startVoice(apiKey: openRouterAPIKey)
            return
        }

        let generation: Int
        switch codexThreadStartGate.begin() {
        case .start(let value):
            generation = value
        case .suppressInFlight:
            BridgeTelemetry.warning("codex_thread_start_suppressed", attributes: ["reason": "in_flight"])
            send(WireEnvelope(kind: .status, message: "Starting your agent"))
            return
        case .suppressFailed:
            BridgeTelemetry.warning("codex_thread_start_suppressed", attributes: ["reason": "awaiting_retry"])
            return
        }

        guard let openRouterAPIKey else {
            _ = codexThreadStartGate.complete(generation: generation, succeeded: false)
            send(WireEnvelope(
                kind: .error,
                message: "OpenRouter is not configured. Run codex-voice-bridge configure-openrouter-key on the Mac."
            ))
            return
        }

        BridgeTelemetry.stage("codex_thread_start_requested", attributes: [
            "timeout_seconds": Int(CodexAppServer.criticalRequestTimeout),
        ])
        send(WireEnvelope(kind: .status, message: "Starting your agent"))
        let developerInstructions = """
        You are serving a voice-first Apple Watch client. Keep final answers concise and conversational. Use tools
        when they materially help. Never reveal secrets, tokens, passwords, personal identifiers, verification
        codes, or raw logs. Work inside the configured workspace unless the user clearly asks otherwise. Ask for
        confirmation before destructive or externally consequential actions.
        """

        codex.sendRequest(
            method: "thread/start",
            params: [
                "cwd": configuration.cwd,
                "approvalPolicy": "on-request",
                "sandbox": "workspace-write",
                "model": configuration.model,
                "developerInstructions": developerInstructions,
            ],
            timeout: CodexAppServer.criticalRequestTimeout
        ) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                let succeeded: Bool
                if case .success = result {
                    succeeded = true
                } else {
                    succeeded = false
                }
                guard self.codexThreadStartGate.complete(
                    generation: generation,
                    succeeded: succeeded
                ) else {
                    BridgeTelemetry.warning("codex_thread_start_stale_result")
                    return
                }

                switch result {
                case .failure(let error):
                    let code: String
                    if case CodexServerError.requestTimedOut = error {
                        code = "codex_thread_start_timeout"
                    } else {
                        code = "codex_thread_start_failed"
                    }
                    BridgeTelemetry.failure(code, error: error)
                    self.send(WireEnvelope(
                        kind: .error,
                        message: "Your agent could not start. Tap retry to reconnect."
                    ))
                case .success(let value):
                    guard let response = value as? [String: Any],
                          let thread = response["thread"] as? [String: Any],
                          let threadID = thread["id"] as? String else {
                        self.codexThreadStartGate.markFailed()
                        BridgeTelemetry.failure(
                            "codex_thread_start_malformed",
                            error: CodexServerError.malformedResponse("thread/start")
                        )
                        self.send(WireEnvelope(kind: .error, message: "Your agent did not return a thread"))
                        return
                    }
                    self.threadID = threadID
                    BridgeTelemetry.stage("codex_thread_started")
                    self.startVoice(apiKey: openRouterAPIKey)
                }
            }
        }
    }

    private func startVoice(apiKey: String) {
        if voiceReady {
            send(WireEnvelope(
                kind: .ready,
                threadId: threadID,
                message: "Ready",
                model: configuration.voiceModel
            ))
            return
        }
        guard voiceSession == nil else { return }
        send(WireEnvelope(kind: .status, threadId: threadID, message: "Connecting to OpenRouter"))

        let live = OpenRouterVoiceSession(
            apiKey: apiKey,
            model: configuration.voiceModel,
            voice: configuration.defaultVoice,
            queue: queue
        )
        live.onReady = { [weak self] in
            guard let self else { return }
            self.voiceReady = true
            BridgeTelemetry.stage("openrouter_voice_ready")
            self.send(WireEnvelope(
                kind: .ready,
                threadId: self.threadID,
                message: "Ready",
                model: self.configuration.voiceModel
            ))
        }
        live.onStatus = { [weak self] message in
            guard let self else { return }
            fputs("OpenRouter voice status: \(message)\n", stderr)
            fflush(stderr)
            self.send(WireEnvelope(kind: .status, threadId: self.threadID, message: message))
        }
        live.onAudio = { [weak self] delta in
            guard let self else { return }
            if !self.hasReportedFirstAudioOutput {
                self.hasReportedFirstAudioOutput = true
                BridgeTelemetry.voiceStage(
                    "openrouter_first_audio_output",
                    operation: "provider.first_audio"
                )
            }
            self.send(WireEnvelope(
                kind: .audioOutput,
                data: delta,
                sampleRate: 24_000,
                numChannels: 1,
                threadId: self.threadID
            ))
        }
        live.onAudioDone = { [weak self] in
            guard let self else { return }
            self.send(WireEnvelope(kind: .audioOutputDone, threadId: self.threadID))
            self.hasReportedFirstAudioOutput = false
            BridgeTelemetry.finishVoiceTurn()
        }
        live.onTranscriptDelta = { [weak self] delta in
            guard let self else { return }
            self.send(WireEnvelope(
                kind: .transcriptDelta,
                role: "assistant",
                text: delta,
                threadId: self.threadID
            ))
        }
        live.onTranscriptDone = { [weak self] transcript in
            guard let self else { return }
            self.send(WireEnvelope(
                kind: .transcriptDone,
                role: "assistant",
                text: transcript,
                threadId: self.threadID
            ))
        }
        live.onFunctionCall = { [weak self] callID, name, arguments in
            self?.runCodex(callID: callID, name: name, arguments: arguments)
        }
        live.onResponseComplete = { [weak self] in
            guard let self else { return }
            if !self.isCodexBusy {
                self.send(WireEnvelope(kind: .ready, threadId: self.threadID, message: "Ready"))
            }
        }
        live.onError = { [weak self, weak live] error in
            guard let self, self.voiceSession === live else { return }
            BridgeTelemetry.failure("openrouter_voice", error: error)
            fputs("OpenRouter voice error: \(error.localizedDescription)\n", stderr)
            fflush(stderr)
            live?.stop()
            self.voiceReady = false
            self.voiceSession = nil
            self.audioBuffer.removeAll(keepingCapacity: false)
            self.audioChunkCount = 0
            self.hasReportedFirstAudioOutput = false
            self.send(WireEnvelope(kind: .error, threadId: self.threadID, message: error.localizedDescription))
        }
        voiceSession = live
        live.start()
    }

    private func appendAudio(_ envelope: WireEnvelope) -> String {
        guard isPaired else {
            logAudio("chunk_rejected reason=not_paired")
            return "audio_input_rejected_not_paired"
        }
        guard threadID != nil, voiceReady else {
            logAudio("chunk_rejected reason=voice_not_ready")
            return "audio_input_rejected_voice_not_ready"
        }
        guard !isCodexBusy else {
            logAudio("chunk_rejected reason=codex_busy")
            return "audio_input_rejected_codex_busy"
        }
        guard envelope.sampleRate == 24_000, envelope.numChannels == 1 else {
            logAudio("chunk_rejected reason=invalid_format")
            return "audio_input_rejected_invalid_format"
        }
        guard let encoded = envelope.data,
              let chunk = Data(base64Encoded: encoded),
              !chunk.isEmpty else {
            logAudio("chunk_rejected reason=invalid_payload")
            return "audio_input_rejected_invalid_payload"
        }
        if reliableAudioTurnsNegotiated {
            guard let turnID = envelope.turnId,
                  let turnSequence = envelope.turnSequence else {
                BridgeTelemetry.warning("watch_audio_turn_metadata_missing")
                logAudio("chunk_rejected reason=turn_metadata_missing")
                return "audio_turn_metadata_missing"
            }
            switch reliableAudioTurnReceiver.receiveAudio(
                turnID: turnID,
                sequence: turnSequence
            ) {
            case .accepted:
                if turnSequence == 1 {
                    BridgeTelemetry.stage("watch_audio_turn_started", attributes: [
                        "audio_turn_id": turnID,
                    ])
                }
                break
            case .duplicate:
                BridgeTelemetry.stage("watch_audio_chunk_duplicate", attributes: [
                    "audio_turn_id": turnID,
                    "turn_sequence": turnSequence,
                ])
                return "audio_input_duplicate"
            case .gap(let expected):
                BridgeTelemetry.warning("watch_audio_chunk_gap", attributes: [
                    "audio_turn_id": turnID,
                    "expected_turn_sequence": expected,
                    "received_turn_sequence": turnSequence,
                ])
                return "audio_input_gap"
            case .conflictingTurn:
                BridgeTelemetry.warning("watch_audio_turn_conflict", attributes: [
                    "audio_turn_id": turnID,
                    "received_turn_sequence": turnSequence,
                ])
                return "audio_input_conflicting_turn"
            }
        }
        guard audioBuffer.count + chunk.count <= Self.maximumAudioBytes else {
            logAudio("turn_rejected reason=maximum_bytes bytes=\(audioBuffer.count)")
            BridgeTelemetry.cancelVoiceTurn("watch_audio_rejected_maximum_bytes")
            audioBuffer.removeAll(keepingCapacity: false)
            audioChunkCount = 0
            send(WireEnvelope(kind: .error, threadId: threadID, message: "That recording is too long"))
            reliableAudioTurnReceiver.cancelActiveTurn()
            return "audio_input_rejected_maximum_bytes"
        }
        audioBuffer.append(chunk)
        audioChunkCount += 1
        if audioChunkCount == 1 {
            BridgeTelemetry.beginVoiceTurn()
            BridgeTelemetry.voiceStage("watch_first_audio_chunk", operation: "bridge.first_input")
            logAudio("first_chunk bytes=\(chunk.count) sample_rate=24000 channels=1")
        } else if audioChunkCount.isMultiple(of: 100) {
            logAudio("progress chunks=\(audioChunkCount) bytes=\(audioBuffer.count)")
        }
        return "audio_input_processed"
    }

    private func commitAudio(_ envelope: WireEnvelope) -> String {
        guard voiceReady, let threadID, !isCodexBusy else {
            logAudio("commit_rejected reason=voice_not_ready_or_busy chunks=\(audioChunkCount) bytes=\(audioBuffer.count)")
            if audioChunkCount > 0 {
                BridgeTelemetry.cancelVoiceTurn("watch_audio_commit_rejected")
            }
            return "commit_rejected_voice_not_ready_or_busy"
        }
        if reliableAudioTurnsNegotiated {
            guard let turnID = envelope.turnId,
                  let finalAudioSequence = envelope.finalAudioSequence else {
                BridgeTelemetry.warning("watch_audio_commit_metadata_missing")
                return "commit_rejected_metadata_missing"
            }
            switch reliableAudioTurnReceiver.receiveCommit(
                turnID: turnID,
                finalAudioSequence: finalAudioSequence
            ) {
            case .process:
                BridgeTelemetry.stage("watch_audio_turn_commit_complete", attributes: [
                    "audio_turn_id": turnID,
                    "final_audio_sequence": finalAudioSequence,
                ])
                break
            case .duplicate:
                BridgeTelemetry.stage("watch_audio_commit_duplicate", attributes: [
                    "audio_turn_id": turnID,
                    "final_audio_sequence": finalAudioSequence,
                ])
                logAudio("commit_duplicate final_audio_sequence=\(finalAudioSequence)")
                return "commit_duplicate"
            case .deferred(let expected):
                BridgeTelemetry.warning("watch_audio_commit_deferred", attributes: [
                    "audio_turn_id": turnID,
                    "expected_turn_sequence": expected,
                    "final_audio_sequence": finalAudioSequence,
                ])
                logAudio("commit_deferred expected_sequence=\(expected) final_audio_sequence=\(finalAudioSequence)")
                return "commit_deferred_missing_audio"
            case .invalid:
                BridgeTelemetry.warning("watch_audio_commit_invalid", attributes: [
                    "audio_turn_id": turnID,
                    "final_audio_sequence": finalAudioSequence,
                ])
                return "commit_rejected_invalid_sequence"
            }
        }
        guard audioBuffer.count >= Self.minimumAudioBytes else {
            logAudio("commit_rejected reason=too_short chunks=\(audioChunkCount) bytes=\(audioBuffer.count)")
            BridgeTelemetry.cancelVoiceTurn("watch_audio_rejected_too_short")
            audioBuffer.removeAll(keepingCapacity: false)
            audioChunkCount = 0
            send(WireEnvelope(
                kind: .error,
                threadId: threadID,
                message: "I did not catch that. Listening again."
            ))
            return "commit_rejected_too_short"
        }

        let recording = audioBuffer
        BridgeTelemetry.voiceStage("watch_audio_commit_accepted", operation: "bridge.commit")
        logAudio("commit_accepted chunks=\(audioChunkCount) bytes=\(recording.count)")
        audioBuffer.removeAll(keepingCapacity: false)
        audioChunkCount = 0
        send(WireEnvelope(kind: .status, threadId: threadID, message: "Thinking"))
        voiceSession?.processAudio(recording)
        return "commit_processed"
    }

    private func logWatchCaptureDiagnostic(_ envelope: WireEnvelope) {
        guard isPaired, envelope.role == "watch.capture", let code = envelope.code else { return }
        let knownCodes: Set<String> = [
            "permission",
            "audio_session_configuring",
            "audio_session_configured",
            "audio_session_activated",
            "audio_session_failed",
            "audio_session_event",
            "audio_graph_configured",
            "audio_graph_failed",
            "audio_graph_prestart",
            "audio_graph_recreated",
            "audio_graph_discarded",
            "audio_recovery_scheduled",
            "audio_recovery_deactivated",
            "audio_recovery_deactivation_failed",
            "audio_recovery_reactivated",
            "audio_recovery_exhausted",
            "audio_probe_started",
            "audio_probe_speech_started",
            "audio_probe_speech_ended",
            "capture_attempt",
            "input_format",
            "input_format_negotiated",
            "capture_started",
            "capture_rearmed",
            "capture_stopped",
            "capture_failed",
            "first_buffer",
            "first_buffer_timeout",
            "level",
            "speech_started",
            "speech_ended",
            "barge_in_waiting_for_output",
            "pre_output_speech_ignored",
            "provider_first_audio_received",
            "initial_playback_speech_deferred",
            "playback_echo_speech_rejected",
            "playback_barge_in_triggered",
            "stale_barge_in_speech_discarded",
            "barge_in_capture_unavailable",
            "audio_turn_delivery_failed",
            "conversion_failed",
            "output_engine_started",
            "output_engine_stopped",
            "output_first_buffer",
            "output_playing",
            "output_stream_finished",
            "output_finished",
            "output_failed",
            "no_speech",
            "muted",
            "unmuted",
        ]
        guard knownCodes.contains(code) else { return }
        BridgeTelemetry.watchDiagnostic(code: code, sampleRate: envelope.sampleRate)

        let message = envelope.message ?? ""
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " =.,_:-/()[]"))
        guard message.count <= 3_000,
              message.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            logAudio("diagnostic code=\(code) detail=rejected")
            return
        }

        let rate = envelope.sampleRate.map(String.init) ?? "none"
        let samples = envelope.samplesPerChannel.map(String.init) ?? "none"
        logAudio("diagnostic code=\(code) sample_rate=\(rate) samples=\(samples) \(message)")
    }

    private func logAudio(_ message: String) {
        let session = id.uuidString.prefix(8).lowercased()
        fputs("Watch audio [\(session)]: \(message)\n", stderr)
        fflush(stderr)
    }

    private func runCodex(callID: String, name: String, arguments: String) {
        guard name == "run_codex" else {
            voiceSession?.sendFunctionOutput(callID: callID, output: "Unsupported tool: \(name)")
            return
        }
        guard !isCodexBusy, pendingCodexCallID == nil else {
            voiceSession?.sendFunctionOutput(callID: callID, output: "Your agent is already handling another request.")
            return
        }
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = object["request"] as? String,
              !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let threadID else {
            voiceSession?.sendFunctionOutput(callID: callID, output: "The agent request was missing or invalid.")
            return
        }

        pendingCodexCallID = callID
        isCodexBusy = true
        BridgeTelemetry.voiceStage("codex_call_started", operation: "codex.turn")
        assistantText = ""
        send(WireEnvelope(kind: .status, threadId: threadID, message: "Your agent is working"))
        codex.sendRequest(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": request]],
                "effort": "low",
            ],
            timeout: CodexAppServer.criticalRequestTimeout
        ) { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            self.queue.async { self.failCodexCall(error.localizedDescription) }
        }
    }

    private func finishCodexTurn(params: [String: Any], threadID: String) {
        let response = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        assistantText = ""
        isCodexBusy = false
        guard let callID = pendingCodexCallID else { return }
        pendingCodexCallID = nil

        let output = response.isEmpty
            ? (turnFailureMessage(params) ?? "Your agent completed without a written result.")
            : response
        voiceSession?.sendFunctionOutput(callID: callID, output: output)
        BridgeTelemetry.voiceStage("codex_call_finished", operation: "codex.turn.complete")
        send(WireEnvelope(kind: .status, threadId: threadID, message: "Preparing answer"))
    }

    private func failCodexCall(_ message: String) {
        guard let callID = pendingCodexCallID else { return }
        pendingCodexCallID = nil
        isCodexBusy = false
        BridgeTelemetry.failure(
            "codex_call",
            error: NSError(domain: "CodexVoice.CodexCall", code: 1)
        )
        voiceSession?.sendFunctionOutput(callID: callID, output: "Your agent failed: \(message)")
    }

    private func turnFailureMessage(_ params: [String: Any]) -> String? {
        guard let turn = params["turn"] as? [String: Any],
              let error = turn["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

struct CodexThreadStartGate {
    enum Decision: Equatable {
        case start(Int)
        case suppressInFlight
        case suppressFailed
    }

    private enum State: Equatable {
        case idle
        case starting(Int)
        case failed
    }

    private var state: State = .idle
    private var generation = 0

    mutating func begin() -> Decision {
        switch state {
        case .idle:
            generation += 1
            state = .starting(generation)
            return .start(generation)
        case .starting:
            return .suppressInFlight
        case .failed:
            return .suppressFailed
        }
    }

    @discardableResult
    mutating func complete(generation: Int, succeeded: Bool) -> Bool {
        guard state == .starting(generation) else { return false }
        state = succeeded ? .idle : .failed
        return true
    }

    mutating func markFailed() {
        state = .failed
    }

    mutating func reset() {
        generation += 1
        state = .idle
    }
}
