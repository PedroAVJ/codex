import Foundation

final class OpenRouterVoiceSession: NSObject, URLSessionDataDelegate {
    struct HistoryCompactionResult: Equatable {
        let compactedAudioTurns: Int
        let preservedAudioTurns: Int
        let preservedAudioBytes: Int
    }

    private struct ToolCallAccumulator {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private let apiKey: String
    private let model: String
    private let voice: String
    private let queue: DispatchQueue
    private let requestSession: URLSession
    private lazy var streamingSession = URLSession(
        configuration: .ephemeral,
        delegate: self,
        delegateQueue: nil
    )

    private var validationTask: URLSessionDataTask?
    private var chatTask: URLSessionDataTask?
    private var chatTaskID: Int?
    private var chatStatusCode = 0
    private var rawChatResponse = Data()
    private var streamBuffer = Data()
    private var streamFinished = false
    private var hasAudioOutput = false
    private var assistantTranscript = ""
    private var assistantText = ""
    private var toolCalls: [Int: ToolCallAccumulator] = [:]
    private var history: [[String: Any]] = []
    private var turnHistoryStart = 0
    private var pendingToolCallID: String?
    private var started = false
    private var ready = false
    private var processing = false
    private var stopped = false

    var onReady: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onAudio: ((String) -> Void)?
    var onAudioDone: (() -> Void)?
    var onTranscriptDelta: ((String) -> Void)?
    var onTranscriptDone: ((String) -> Void)?
    var onFunctionCall: ((String, String, String) -> Void)?
    var onResponseComplete: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(
        apiKey: String,
        model: String,
        voice: String,
        queue: DispatchQueue
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.queue = queue
        self.requestSession = URLSession(configuration: .ephemeral)
        super.init()
    }

    func start() {
        queue.async {
            guard !self.started, !self.stopped else { return }
            self.started = true
            self.onStatus?("Connecting to OpenRouter")
            self.validateAPIKey()
        }
    }

    func processAudio(_ pcm16: Data) {
        queue.async {
            guard self.ready, !self.processing, !pcm16.isEmpty else { return }
            self.processing = true
            self.turnHistoryStart = self.history.count
            self.history.append(Self.inputAudioMessage(pcm16: pcm16))
            self.onStatus?("Thinking")
            self.startChatCompletion()
        }
    }

    func sendFunctionOutput(callID: String, output: String) {
        queue.async {
            guard self.processing, self.pendingToolCallID == callID else { return }
            self.pendingToolCallID = nil
            self.history.append([
                "role": "tool",
                "tool_call_id": callID,
                "content": String(output.prefix(60_000)),
            ])
            self.onStatus?("Preparing answer through OpenRouter")
            self.startChatCompletion()
        }
    }

    func cancelResponse() {
        queue.async {
            guard self.processing else { return }
            self.chatTask?.cancel()
            self.chatTask = nil
            self.rollbackCurrentTurn()
            self.resetStreamState()
            self.pendingToolCallID = nil
            self.processing = false
        }
    }

    func clearInputAudio() {}

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.ready = false
            self.processing = false
            self.validationTask?.cancel()
            self.chatTask?.cancel()
            self.validationTask = nil
            self.chatTask = nil
            self.requestSession.invalidateAndCancel()
            self.streamingSession.invalidateAndCancel()
        }
    }

    private func validateAPIKey() {
        BridgeTelemetry.stage("openrouter_key_validation_started")
        var request = authorizedRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        validationTask = requestSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                self.validationTask = nil
                guard !self.stopped else { return }
                if let error {
                    self.fail(OpenRouterVoiceError.transport(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    self.fail(self.apiError(data: data, fallback: "The OpenRouter API key was rejected."))
                    return
                }
                if let data,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let metadata = object["data"] as? [String: Any],
                   let remaining = metadata["limit_remaining"] as? NSNumber,
                   remaining.doubleValue <= 0 {
                    self.fail(OpenRouterVoiceError.api("This OpenRouter key has no remaining spending limit."))
                    return
                }
                self.ready = true
                BridgeTelemetry.stage("openrouter_key_validated")
                self.onReady?()
            }
        }
        validationTask?.resume()
    }

    private func startChatCompletion() {
        BridgeTelemetry.voiceStage(
            "openrouter_request_started",
            operation: "provider.request"
        )
        resetStreamState()
        let payload: [String: Any] = [
            "model": model,
            "messages": [systemMessage] + history,
            "modalities": ["text", "audio"],
            "audio": ["voice": voice, "format": "pcm16"],
            "tools": [runCodexTool],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "max_tokens": 1_200,
            "stream": true,
        ]
        guard var request = jsonRequest(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            payload: payload,
            timeout: 120
        ) else {
            fail(OpenRouterVoiceError.api("Could not encode the voice request."))
            return
        }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let task = streamingSession.dataTask(with: request)
        chatTask = task
        chatTaskID = task.taskIdentifier
        task.resume()
    }

    private var systemMessage: [String: Any] {
        [
            "role": "system",
            "content": """
            You are the concise spoken front end for Codex running on the user's Mac. For greetings and simple
            conversation, answer directly. For every request that needs files, code, commands, research, apps,
            the workspace, current information, or any action on the Mac, call run_codex exactly once with a
            complete self-contained request. Never claim work succeeded until run_codex returns. Summarize tool
            results naturally and briefly for speech. Never speak secrets, tokens, passwords, verification codes,
            raw logs, or long file contents.
            """,
        ]
    }

    private var runCodexTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "run_codex",
                "description": "Run a request through the authenticated Codex agent on the user's Mac. Use this for any task that requires the Mac, workspace, tools, files, commands, research, current information, or external actions.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "request": [
                            "type": "string",
                            "description": "A complete instruction for the Mac Codex agent, preserving the user's intent and constraints.",
                        ],
                    ],
                    "required": ["request"],
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Voice", forHTTPHeaderField: "X-OpenRouter-Title")
        return request
    }

    private func jsonRequest(url: URL, payload: [String: Any], timeout: TimeInterval) -> URLRequest? {
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        queue.async {
            guard dataTask.taskIdentifier == self.chatTaskID else {
                completionHandler(.cancel)
                return
            }
            self.chatStatusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            BridgeTelemetry.stage("openrouter_response_received", attributes: [
                "http_status": self.chatStatusCode,
            ])
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            guard dataTask.taskIdentifier == self.chatTaskID, !self.streamFinished else { return }
            self.rawChatResponse.append(data)
            self.streamBuffer.append(data)
            self.processStreamLines()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        queue.async {
            guard task.taskIdentifier == self.chatTaskID else { return }
            self.chatTask = nil
            self.chatTaskID = nil
            guard !self.stopped, self.processing, !self.streamFinished else { return }
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.fail(OpenRouterVoiceError.transport(error.localizedDescription))
                return
            }
            if self.chatStatusCode < 200 || self.chatStatusCode >= 300 {
                self.fail(self.apiError(
                    data: self.rawChatResponse,
                    fallback: "OpenRouter rejected the voice request."
                ))
                return
            }
            self.processTrailingStreamData()
            if !self.streamFinished { self.finishStream() }
        }
    }

    private func processStreamLines() {
        while let newline = streamBuffer.firstIndex(of: 0x0A) {
            let lineData = streamBuffer[..<newline]
            streamBuffer.removeSubrange(...newline)
            guard var line = String(data: lineData, encoding: .utf8) else { continue }
            if line.last == "\r" { line.removeLast() }
            processStreamLine(line)
        }
    }

    private func processTrailingStreamData() {
        guard !streamBuffer.isEmpty,
              let line = String(data: streamBuffer, encoding: .utf8) else { return }
        streamBuffer.removeAll(keepingCapacity: false)
        processStreamLine(line)
    }

    func processStreamLine(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if value == "[DONE]" {
            finishStream()
            return
        }
        guard let data = value.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (event["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any] else { return }

        if let content = delta["content"] as? String { assistantText += content }
        if let audio = delta["audio"] as? [String: Any] {
            if let encoded = audio["data"] as? String, !encoded.isEmpty {
                hasAudioOutput = true
                onAudio?(encoded)
            }
            if let transcript = audio["transcript"] as? String { assistantTranscript += transcript }
        }
        if let chunks = delta["tool_calls"] as? [[String: Any]] {
            for chunk in chunks {
                let index = (chunk["index"] as? NSNumber)?.intValue ?? 0
                var call = toolCalls[index] ?? ToolCallAccumulator()
                if let id = chunk["id"] as? String { call.id += id }
                if let function = chunk["function"] as? [String: Any] {
                    if let name = function["name"] as? String { call.name += name }
                    if let arguments = function["arguments"] as? String { call.arguments += arguments }
                }
                toolCalls[index] = call
            }
        }
    }

    private func finishStream() {
        guard !streamFinished else { return }
        streamFinished = true
        guard chatStatusCode >= 200, chatStatusCode < 300 else { return }

        let completedCalls = toolCalls.sorted { $0.key < $1.key }.map(\.value)
            .filter { !$0.id.isEmpty && !$0.name.isEmpty }
        if let call = completedCalls.first {
            let calls = completedCalls.map { item in
                [
                    "id": item.id,
                    "type": "function",
                    "function": ["name": item.name, "arguments": item.arguments],
                ] as [String: Any]
            }
            history.append(["role": "assistant", "content": NSNull(), "tool_calls": calls])
            pendingToolCallID = call.id
            hasAudioOutput = false
            assistantTranscript = ""
            assistantText = ""
            onStatus?("Passing request to your agent")
            onFunctionCall?(call.id, call.name, call.arguments)
            return
        }

        let transcript = (assistantTranscript.isEmpty ? assistantText : assistantTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAudioOutput else {
            fail(OpenRouterVoiceError.api("The selected model returned no spoken audio."))
            return
        }
        if !transcript.isEmpty {
            onTranscriptDelta?(transcript)
            onTranscriptDone?(transcript)
            history.append(["role": "assistant", "content": transcript])
        }
        onAudioDone?()
        let historyCompaction = Self.compactProcessedAudio(in: &history)
        BridgeTelemetry.stage("openrouter_history_compacted", attributes: [
            "compacted_audio_turns": historyCompaction.compactedAudioTurns,
            "preserved_audio_turns": historyCompaction.preservedAudioTurns,
            "preserved_audio_bytes": historyCompaction.preservedAudioBytes,
            "history_messages": history.count,
        ])
        trimHistory()
        processing = false
        pendingToolCallID = nil
        onResponseComplete?()
    }

    private func trimHistory() {
        while history.count > 12 {
            guard let nextTurn = history.indices.dropFirst().first(where: {
                (history[$0]["role"] as? String) == "user"
            }) else { break }
            history.removeSubrange(0..<nextTurn)
        }
    }

    @discardableResult
    static func compactProcessedAudio(
        in history: inout [[String: Any]],
        maximumPreservedAudioTurns: Int = 6,
        maximumPreservedAudioBytes: Int = 6_000_000
    ) -> HistoryCompactionResult {
        let audioTurnIndices = history.indices.filter { index in
            (history[index]["role"] as? String) == "user"
                && history[index]["content"] is [[String: Any]]
        }
        var preservedIndices = Set<Int>()
        var preservedAudioBytes = 0
        for index in audioTurnIndices.reversed() {
            guard preservedIndices.count < max(1, maximumPreservedAudioTurns) else { break }
            let audioBytes = inputAudioByteCount(in: history[index])
            let isNewestTurn = preservedIndices.isEmpty
            guard isNewestTurn
                    || preservedAudioBytes + audioBytes <= max(0, maximumPreservedAudioBytes) else {
                continue
            }
            preservedIndices.insert(index)
            preservedAudioBytes += audioBytes
        }
        var compactedCount = 0
        for index in audioTurnIndices where !preservedIndices.contains(index) {
            history[index]["content"] = "Previous voice turn (audio omitted after processing)."
            compactedCount += 1
        }
        return HistoryCompactionResult(
            compactedAudioTurns: compactedCount,
            preservedAudioTurns: preservedIndices.count,
            preservedAudioBytes: preservedAudioBytes
        )
    }

    private static func inputAudioByteCount(in message: [String: Any]) -> Int {
        guard let content = message["content"] as? [[String: Any]],
              let audioPart = content.first(where: { ($0["type"] as? String) == "input_audio" }),
              let inputAudio = audioPart["input_audio"] as? [String: Any],
              let encoded = inputAudio["data"] as? String else { return 0 }
        return (encoded.count / 4) * 3
    }

    private func rollbackCurrentTurn() {
        guard history.indices.contains(turnHistoryStart) else { return }
        history.removeSubrange(turnHistoryStart...)
    }

    private func resetStreamState() {
        chatStatusCode = 0
        rawChatResponse.removeAll(keepingCapacity: false)
        streamBuffer.removeAll(keepingCapacity: false)
        streamFinished = false
        hasAudioOutput = false
        assistantTranscript = ""
        assistantText = ""
        toolCalls.removeAll(keepingCapacity: false)
    }

    private func fail(_ error: Error) {
        rollbackCurrentTurn()
        processing = false
        pendingToolCallID = nil
        chatTask?.cancel()
        chatTask = nil
        chatTaskID = nil
        resetStreamState()
        onError?(error)
    }

    private func apiError(data: Data?, fallback: String) -> Error {
        if let data,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return OpenRouterVoiceError.api(message)
        }
        return OpenRouterVoiceError.api(fallback)
    }

    static func wavData(pcm16: Data, sampleRate: UInt32, channelCount: UInt16) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        var result = Data()
        result.append(Data("RIFF".utf8))
        result.appendLittleEndian(UInt32(36 + pcm16.count))
        result.append(Data("WAVEfmt ".utf8))
        result.appendLittleEndian(UInt32(16))
        result.appendLittleEndian(UInt16(1))
        result.appendLittleEndian(channelCount)
        result.appendLittleEndian(sampleRate)
        result.appendLittleEndian(byteRate)
        result.appendLittleEndian(blockAlign)
        result.appendLittleEndian(bitsPerSample)
        result.append(Data("data".utf8))
        result.appendLittleEndian(UInt32(pcm16.count))
        result.append(pcm16)
        return result
    }

    static func inputAudioMessage(pcm16: Data) -> [String: Any] {
        let wav = wavData(pcm16: pcm16, sampleRate: 24_000, channelCount: 1)
        return [
            "role": "user",
            "content": [[
                "type": "input_audio",
                "input_audio": [
                    "data": wav.base64EncodedString(),
                    "format": "wav",
                ],
            ]],
        ]
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

enum OpenRouterVoiceError: LocalizedError {
    case api(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .api(let message): "OpenRouter: \(message)"
        case .transport(let message): "OpenRouter connection failed: \(message)"
        }
    }
}
