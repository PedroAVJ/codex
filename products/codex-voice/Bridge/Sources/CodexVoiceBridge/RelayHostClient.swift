import CodexVoiceProtocol
import CryptoKit
import Foundation

final class RelayHostClient: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private static let maximumWebSocketMessageBytes = 2 * 1_024 * 1_024

    private let endpoint: URL
    private let identity: RelayIdentity
    private let serverPrivateKey: P256.KeyAgreement.PrivateKey
    private let serverPublicKey: String
    private let queue: DispatchQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let delegateQueue: OperationQueue

    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var shouldRun = false
    private var relayReady = false
    private var reconnectAttempt = 0

    var onPacket: ((String, BridgePacket) -> Void)?
    var onChannelClosed: ((String?) -> Void)?
    var onState: ((Bool, String) -> Void)?
    var onLiveness: (() -> Void)?

    init(
        endpoint: URL,
        identity: RelayIdentity,
        serverPrivateKey: P256.KeyAgreement.PrivateKey,
        queue: DispatchQueue
    ) {
        self.endpoint = endpoint
        self.identity = identity
        self.serverPrivateKey = serverPrivateKey
        self.serverPublicKey = serverPrivateKey.publicKey.rawRepresentation.base64URLEncodedString()
        self.queue = queue
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.pedro.codexvoice.relay.delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue = delegateQueue
        super.init()
    }

    func start() {
        queue.async {
            self.shouldRun = true
            self.connect()
        }
    }

    func stop() {
        queue.sync {
            shouldRun = false
            relayReady = false
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            urlSession?.invalidateAndCancel()
            urlSession = nil
        }
    }

    func send(_ packet: BridgePacket, channel: String) {
        queue.async {
            guard self.relayReady,
                  let relayKey = self.identity.keyData.map(SymmetricKey.init(data:)),
                  let sealed = try? SecureBridgeProtocol.seal(packet, using: relayKey) else { return }
            self.send(RelayMessage(
                kind: .frame,
                channel: channel,
                payload: sealed,
                deliveryId: packet.deliveryId,
                sequence: packet.sequence
            ))
        }
    }

    func close(channel: String) {
        queue.async {
            guard self.relayReady else { return }
            self.send(RelayMessage(kind: .close, channel: channel))
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async {
            guard webSocketTask === self.task else { return }
            self.reconnectAttempt = 0
            BridgeTelemetry.stage("relay_websocket_opened", attributes: [
                "maximum_message_bytes": webSocketTask.maximumMessageSize,
                "websocket_ready_state": webSocketTask.state.rawValue,
            ])
            self.receiveNext(from: webSocketTask)
            self.schedulePing(for: webSocketTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async {
            BridgeTelemetry.warning("relay_websocket_closed", attributes: [
                "websocket_close_code": closeCode.rawValue,
                "close_reason_bytes": reason?.count ?? 0,
                "maximum_message_bytes": webSocketTask.maximumMessageSize,
                "websocket_ready_state": webSocketTask.state.rawValue,
            ])
            self.fail(webSocketTask, message: "Remote relay disconnected")
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else { return }
        queue.async {
            if let source = error as NSError? {
                BridgeTelemetry.warning("relay_websocket_task_failed", attributes: [
                    "error_domain": source.domain,
                    "error_code": source.code,
                    "maximum_message_bytes": webSocketTask.maximumMessageSize,
                    "websocket_ready_state": webSocketTask.state.rawValue,
                ])
            }
            self.fail(webSocketTask, message: error?.localizedDescription ?? "Remote relay connection ended")
        }
    }

    private func connect() {
        guard shouldRun, task == nil else { return }
        do {
            let auth = try identity.accessToken(
                role: .host,
                expiresAt: Int(Date().addingTimeInterval(60 * 60).timeIntervalSince1970),
                serverPrivateKey: serverPrivateKey
            )
            guard let room = identity.room,
                  var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                throw RelayIdentityError.invalidIdentity
            }
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "room", value: room),
                URLQueryItem(name: "role", value: RelayRole.host.rawValue),
                URLQueryItem(name: "channel", value: "host"),
                URLQueryItem(name: "server", value: serverPublicKey),
            ]
            guard let url = components.url else { throw RelayIdentityError.invalidURL }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 30
            var request = URLRequest(url: url)
            request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = Self.maximumWebSocketMessageBytes
            self.urlSession = session
            self.task = task
            relayReady = false
            BridgeTelemetry.stage("relay_websocket_configured", attributes: [
                "maximum_message_bytes": task.maximumMessageSize,
                "websocket_ready_state": task.state.rawValue,
            ])
            onState?(false, "Connecting to remote relay")
            task.resume()
        } catch {
            scheduleReconnect(message: error.localizedDescription)
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
                    BridgeTelemetry.warning("relay_websocket_receive_failed", attributes: [
                        "error_domain": source.domain,
                        "error_code": source.code,
                        "maximum_message_bytes": task.maximumMessageSize,
                        "websocket_ready_state": task.state.rawValue,
                    ])
                    self.fail(task, message: error.localizedDescription)
                case .success(let message):
                    self.handle(message)
                    self.receiveNext(from: task)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let relayMessage = try? decoder.decode(RelayMessage.self, from: data) else {
            BridgeTelemetry.warning("relay_message_decode_failed", attributes: [
                "frame_bytes": data.count,
                "maximum_message_bytes": task?.maximumMessageSize ?? Self.maximumWebSocketMessageBytes,
            ])
            return
        }
        var receiveAttributes: [String: Any] = [
            "relay_message_kind": relayMessage.kind.rawValue,
            "frame_bytes": data.count,
            "payload_bytes": relayMessage.payload.map { Data($0.utf8).count } ?? 0,
        ]
        if let deliveryID = relayMessage.deliveryId { receiveAttributes["delivery_id"] = deliveryID }
        if let sequence = relayMessage.sequence { receiveAttributes["delivery_sequence"] = sequence }
        BridgeTelemetry.stage("relay_message_received", attributes: receiveAttributes)
        switch relayMessage.kind {
        case .ready:
            relayReady = true
            onState?(true, "Remote relay connected")
        case .frame:
            guard let channel = relayMessage.channel,
                  let payload = relayMessage.payload,
                  let relayKey = identity.keyData.map(SymmetricKey.init(data:)),
                  let packet = try? SecureBridgeProtocol.open(BridgePacket.self, from: payload, using: relayKey) else {
                BridgeTelemetry.warning("relay_frame_open_failed", attributes: receiveAttributes)
                return
            }
            if relayMessage.deliveryId != packet.deliveryId || relayMessage.sequence != packet.sequence {
                BridgeTelemetry.warning("relay_delivery_metadata_mismatch", attributes: receiveAttributes)
            }
            onPacket?(channel, packet)
        case .close:
            onChannelClosed?(relayMessage.channel)
        case .error:
            onState?(false, relayMessage.message ?? "Remote relay rejected the connection")
        }
    }

    private func send(_ message: RelayMessage) {
        guard let task, let data = try? encoder.encode(message), let text = String(data: data, encoding: .utf8) else {
            BridgeTelemetry.warning("relay_websocket_send_dropped")
            return
        }
        var attributes: [String: Any] = [
            "relay_message_kind": message.kind.rawValue,
            "frame_bytes": data.count,
            "payload_bytes": message.payload.map { Data($0.utf8).count } ?? 0,
            "maximum_message_bytes": task.maximumMessageSize,
            "websocket_ready_state": task.state.rawValue,
        ]
        if let deliveryID = message.deliveryId { attributes["delivery_id"] = deliveryID }
        if let sequence = message.sequence { attributes["delivery_sequence"] = sequence }
        let sendAttributes = attributes
        BridgeTelemetry.stage("relay_websocket_send_queued", attributes: sendAttributes)
        task.send(.string(text)) { [weak self, weak task] error in
            guard let self, let task else { return }
            self.queue.async {
                if let error {
                    let source = error as NSError
                    var failureAttributes = sendAttributes
                    failureAttributes["error_domain"] = source.domain
                    failureAttributes["error_code"] = source.code
                    BridgeTelemetry.warning("relay_websocket_send_failed", attributes: failureAttributes)
                    self.fail(task, message: error.localizedDescription)
                } else {
                    BridgeTelemetry.stage("relay_websocket_send_completed", attributes: sendAttributes)
                }
            }
        }
    }

    private func schedulePing(for task: URLSessionWebSocketTask) {
        queue.asyncAfter(deadline: .now() + 25) { [weak self, weak task] in
            guard let self, let task, task === self.task, self.shouldRun else { return }
            task.sendPing { [weak self, weak task] error in
                guard let self, let task else { return }
                self.queue.async {
                    if let error {
                        self.fail(task, message: error.localizedDescription)
                    } else {
                        self.onLiveness?()
                        self.schedulePing(for: task)
                    }
                }
            }
        }
    }

    private func fail(_ failedTask: URLSessionWebSocketTask, message: String) {
        guard failedTask === task else { return }
        task = nil
        relayReady = false
        urlSession?.invalidateAndCancel()
        urlSession = nil
        onState?(false, message)
        onChannelClosed?(nil)
        scheduleReconnect(message: message)
    }

    private func scheduleReconnect(message: String) {
        guard shouldRun else { return }
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(min(reconnectAttempt - 1, 5))), 30)
        onState?(false, "Remote relay unavailable; retrying")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }
}
