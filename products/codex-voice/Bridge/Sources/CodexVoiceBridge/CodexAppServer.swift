import Foundation

final class CodexAppServer {
    typealias JSONObject = [String: Any]
    typealias RequestCompletion = (Result<Any, Error>) -> Void

    static let criticalRequestTimeout: TimeInterval = 20
    private static let maximumSocketConnectionAttempts = 20
    private static let socketConnectionRetryDelay: TimeInterval = 0.25

    private enum State {
        case stopped
        case connecting
        case started
    }

    private let executable: URL
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.pedro.codexvoice.app-server")
    private var socket: UnixWebSocketConnection?
    private var state = State.stopped
    private var startCompletions: [(Result<Void, Error>) -> Void] = []
    private var nextRequestID = 1
    private var pending: [Int: RequestCompletion] = [:]

    var onNotification: ((String, JSONObject) -> Void)?
    var onServerRequest: ((Any, String, JSONObject) -> Void)?

    init(executable: URL, socketPath: String? = nil) {
        self.executable = executable
        self.socketPath = socketPath ?? Self.controlSocketPath()
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if case .started = self.state {
                completion(.success(()))
                return
            }
            self.startCompletions.append(completion)
            guard case .stopped = self.state else { return }
            self.state = .connecting

            do {
                try self.ensureManagedDaemonRunning()
                self.connectToSocket(attemptsRemaining: Self.maximumSocketConnectionAttempts)
            } catch {
                self.state = .stopped
                self.completeStart(.failure(error))
            }
        }
    }

    func sendRequest(
        method: String,
        params: JSONObject,
        timeout: TimeInterval? = nil,
        completion: RequestCompletion? = nil
    ) {
        queue.async {
            let id = self.nextRequestID
            self.nextRequestID += 1
            if let completion {
                self.pending[id] = completion
                if let timeout {
                    self.queue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
                        guard let self,
                              let callback = self.pending.removeValue(forKey: id) else { return }
                        callback(.failure(CodexServerError.requestTimedOut(method)))
                    }
                }
            }
            self.write(["method": method, "id": id, "params": params])
        }
    }

    func sendNotification(method: String, params: JSONObject) {
        queue.async { self.write(["method": method, "params": params]) }
    }

    func sendResponse(id: Any, result: JSONObject) {
        queue.async { self.write(["id": id, "result": result]) }
    }

    func sendErrorResponse(id: Any, message: String) {
        queue.async {
            self.write(["id": id, "error": ["code": -32_000, "message": message]])
        }
    }

    func stop() {
        queue.async {
            self.socket?.close()
            self.socket = nil
            self.state = .stopped
            self.completeStart(.failure(CodexServerError.connectionClosed))
            self.failAllPending(CodexServerError.connectionClosed)
        }
    }

    static func controlSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let codexHome: URL
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            codexHome = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        } else {
            codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome
            .appendingPathComponent("app-server-control", isDirectory: true)
            .appendingPathComponent("app-server-control.sock", isDirectory: false)
            .standardizedFileURL.path
    }

    private func initialize() {
        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_voice_watch",
                    "title": "Pedro Voice Agent",
                    "version": "0.3.11",
                ],
                "capabilities": ["experimentalApi": true],
            ],
            timeout: Self.criticalRequestTimeout
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.sendNotification(method: "initialized", params: [:])
                self.queue.async {
                    self.state = .started
                    self.completeStart(.success(()))
                }
            case .failure(let error):
                self.queue.async {
                    self.state = .stopped
                    self.socket?.close()
                    self.socket = nil
                    self.completeStart(.failure(error))
                }
            }
        }
    }

    private func write(_ object: JSONObject) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(text: text)
    }

    private func ensureManagedDaemonRunning() throws {
        let process = Process()
        process.executableURL = executable
        if executable.path == "/usr/bin/env" {
            process.arguments = ["codex", "app-server", "daemon", "start"]
        } else {
            process.arguments = ["app-server", "daemon", "start"]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CodexServerError.daemonStartFailed(process.terminationStatus)
        }
    }

    private func connectToSocket(attemptsRemaining: Int) {
        guard case .connecting = state else { return }

        let socket = UnixWebSocketConnection(socketPath: socketPath, queue: queue)
        self.socket = socket
        socket.onOpen = { [weak self, weak socket] in
            guard let self, self.socket === socket else { return }
            self.initialize()
        }
        socket.onText = { [weak self, weak socket] text in
            guard let self, self.socket === socket else { return }
            self.consume(text)
        }
        socket.onClose = { [weak self, weak socket] error in
            guard let self, self.socket === socket else { return }
            self.socket = nil
            let failure = error ?? CodexServerError.connectionClosed
            if case .connecting = self.state, attemptsRemaining > 1 {
                self.scheduleSocketRetry(
                    attemptsRemaining: attemptsRemaining - 1,
                    lastError: failure
                )
                return
            }
            self.state = .stopped
            self.completeStart(.failure(failure))
            self.failAllPending(failure)
        }

        do {
            try socket.connect()
        } catch {
            guard self.socket === socket else { return }
            self.socket = nil
            if attemptsRemaining > 1 {
                scheduleSocketRetry(attemptsRemaining: attemptsRemaining - 1, lastError: error)
            } else {
                state = .stopped
                completeStart(.failure(error))
                failAllPending(error)
            }
        }
    }

    private func scheduleSocketRetry(attemptsRemaining: Int, lastError: Error) {
        guard case .connecting = state else { return }
        queue.asyncAfter(deadline: .now() + Self.socketConnectionRetryDelay) { [weak self] in
            guard let self else { return }
            guard case .connecting = self.state else { return }
            if attemptsRemaining > 0 {
                self.connectToSocket(attemptsRemaining: attemptsRemaining)
            } else {
                self.state = .stopped
                self.completeStart(.failure(lastError))
                self.failAllPending(lastError)
            }
        }
    }

    private func consume(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject else { return }
        handle(object)
    }

    private func handle(_ object: JSONObject) {
        if let numericID = object["id"] as? NSNumber,
           object["method"] == nil,
           let completion = pending.removeValue(forKey: numericID.intValue) {
            if let error = object["error"] as? JSONObject {
                completion(.failure(CodexServerError.rpc(error["message"] as? String ?? "Unknown RPC error")))
            } else {
                completion(.success(object["result"] ?? NSNull()))
            }
            return
        }

        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? JSONObject ?? [:]
        if let id = object["id"] {
            onServerRequest?(id, method, params)
        } else {
            onNotification?(method, params)
        }
    }

    private func completeStart(_ result: Result<Void, Error>) {
        let callbacks = startCompletions
        startCompletions.removeAll()
        callbacks.forEach { $0(result) }
    }

    private func failAllPending(_ error: Error) {
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
    }
}

enum CodexServerError: LocalizedError {
    case connectionClosed
    case daemonStartFailed(Int32)
    case rpc(String)
    case malformedResponse(String)
    case requestTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .connectionClosed: "Codex app-server connection closed"
        case .daemonStartFailed(let status):
            "Codex app-server daemon could not start (exit status \(status))"
        case .rpc(let message): message
        case .malformedResponse(let context): "Malformed Codex response: \(context)"
        case .requestTimedOut(let method): "Codex app-server did not answer \(method) in time"
        }
    }
}
