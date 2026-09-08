import Foundation

public struct WireEnvelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pair
        case paired
        case start
        case ready
        case audioInput
        case commitAudio
        case audioOutput
        case audioOutputDone
        case transcriptDelta
        case transcriptDone
        case status
        case error
        case stop
        case ping
        case pong
        case approval
        case approvalDecision
    }

    public var kind: Kind
    public var code: String?
    public var voice: String?
    public var data: String?
    public var sampleRate: Int?
    public var numChannels: Int?
    public var samplesPerChannel: Int?
    public var role: String?
    public var text: String?
    public var threadId: String?
    public var message: String?
    public var requestId: Int?
    public var approved: Bool?
    public var title: String?
    public var clientId: String?
    public var deviceName: String?
    public var model: String?
    public var relayAuth: String?
    public var deliveryId: String?
    public var sequence: Int?
    public var deliveryKind: String?
    public var deliveryOutcome: String?
    public var turnId: String?
    public var turnSequence: Int?
    public var finalAudioSequence: Int?
    public var capabilities: [String]?

    public init(
        kind: Kind,
        code: String? = nil,
        voice: String? = nil,
        data: String? = nil,
        sampleRate: Int? = nil,
        numChannels: Int? = nil,
        samplesPerChannel: Int? = nil,
        role: String? = nil,
        text: String? = nil,
        threadId: String? = nil,
        message: String? = nil,
        requestId: Int? = nil,
        approved: Bool? = nil,
        title: String? = nil,
        clientId: String? = nil,
        deviceName: String? = nil,
        model: String? = nil,
        relayAuth: String? = nil,
        deliveryId: String? = nil,
        sequence: Int? = nil,
        deliveryKind: String? = nil,
        deliveryOutcome: String? = nil,
        turnId: String? = nil,
        turnSequence: Int? = nil,
        finalAudioSequence: Int? = nil,
        capabilities: [String]? = nil
    ) {
        self.kind = kind
        self.code = code
        self.voice = voice
        self.data = data
        self.sampleRate = sampleRate
        self.numChannels = numChannels
        self.samplesPerChannel = samplesPerChannel
        self.role = role
        self.text = text
        self.threadId = threadId
        self.message = message
        self.requestId = requestId
        self.approved = approved
        self.title = title
        self.clientId = clientId
        self.deviceName = deviceName
        self.model = model
        self.relayAuth = relayAuth
        self.deliveryId = deliveryId
        self.sequence = sequence
        self.deliveryKind = deliveryKind
        self.deliveryOutcome = deliveryOutcome
        self.turnId = turnId
        self.turnSequence = turnSequence
        self.finalAudioSequence = finalAudioSequence
        self.capabilities = capabilities
    }
}

public enum ReliableAudioTurnProtocol {
    public static let capability = "reliable-audio-turn-v1"
    public static let maximumAudioBytes = 1_572_864
    public static let maximumEnvelopeCount = 1_536
    public static let maximumDuration: TimeInterval = 30
}

public struct ReliableAudioTurnBuffer: Sendable {
    public enum Rejection: String, Equatable, Sendable {
        case invalidPayload = "invalid_payload"
        case noActiveTurn = "no_active_turn"
        case turnAlreadyCommitted = "turn_already_committed"
        case maximumAudioBytes = "maximum_audio_bytes"
        case maximumEnvelopeCount = "maximum_envelope_count"
        case maximumDuration = "maximum_duration"
    }

    public enum AppendResult: Equatable, Sendable {
        case accepted(WireEnvelope)
        case rejected(Rejection)
    }

    public enum AcknowledgementResult: Equatable, Sendable {
        case retained
        case turnCompleted(turnID: String)
        case replayRequired(turnID: String, outcome: String)
        case turnRejected(turnID: String, outcome: String)
        case unmatched
    }

    private struct Entry: Sendable {
        var envelope: WireEnvelope
        var lastSentConnectionID: String?
    }

    public private(set) var turnID: String?
    public private(set) var audioBytes = 0
    public private(set) var envelopeCount = 0
    public private(set) var replayCount = 0

    private var startedAt: TimeInterval?
    private var nextAudioSequence = 1
    private var hasCommit = false
    private var entries = [Entry]()

    public init() {}

    public mutating func appendAudio(
        _ source: WireEnvelope,
        turnID requestedTurnID: String,
        deliveryID: String,
        deliverySequence: Int,
        now: TimeInterval
    ) -> AppendResult {
        guard source.kind == .audioInput,
              let encoded = source.data,
              let audio = Data(base64Encoded: encoded),
              !audio.isEmpty else {
            return .rejected(.invalidPayload)
        }
        if turnID == nil {
            turnID = requestedTurnID
            startedAt = now
        }
        guard turnID == requestedTurnID else {
            return .rejected(.turnAlreadyCommitted)
        }
        guard !hasCommit else {
            return .rejected(.turnAlreadyCommitted)
        }
        guard let startedAt, now - startedAt <= ReliableAudioTurnProtocol.maximumDuration else {
            return .rejected(.maximumDuration)
        }
        guard audioBytes + audio.count <= ReliableAudioTurnProtocol.maximumAudioBytes else {
            return .rejected(.maximumAudioBytes)
        }
        guard envelopeCount + 1 <= ReliableAudioTurnProtocol.maximumEnvelopeCount else {
            return .rejected(.maximumEnvelopeCount)
        }

        var envelope = source
        envelope.deliveryId = deliveryID
        envelope.sequence = deliverySequence
        envelope.deliveryKind = envelope.kind.rawValue
        envelope.turnId = requestedTurnID
        envelope.turnSequence = nextAudioSequence
        envelope.finalAudioSequence = nil
        entries.append(Entry(envelope: envelope))
        audioBytes += audio.count
        envelopeCount += 1
        nextAudioSequence += 1
        return .accepted(envelope)
    }

    public mutating func appendCommit(
        _ source: WireEnvelope,
        deliveryID: String,
        deliverySequence: Int,
        now: TimeInterval
    ) -> AppendResult {
        guard source.kind == .commitAudio, let turnID, let startedAt else {
            return .rejected(.noActiveTurn)
        }
        guard !hasCommit else {
            return .rejected(.turnAlreadyCommitted)
        }
        guard now - startedAt <= ReliableAudioTurnProtocol.maximumDuration else {
            return .rejected(.maximumDuration)
        }
        guard envelopeCount + 1 <= ReliableAudioTurnProtocol.maximumEnvelopeCount else {
            return .rejected(.maximumEnvelopeCount)
        }

        var envelope = source
        envelope.deliveryId = deliveryID
        envelope.sequence = deliverySequence
        envelope.deliveryKind = envelope.kind.rawValue
        envelope.turnId = turnID
        envelope.turnSequence = nextAudioSequence
        envelope.finalAudioSequence = nextAudioSequence - 1
        entries.append(Entry(envelope: envelope))
        envelopeCount += 1
        hasCommit = true
        return .accepted(envelope)
    }

    public mutating func pendingEnvelopes(for connectionID: String) -> [WireEnvelope] {
        let isReplay = entries.contains { entry in
            entry.lastSentConnectionID != nil && entry.lastSentConnectionID != connectionID
        }
        if isReplay { replayCount += 1 }
        return entries.compactMap { entry in
            entry.lastSentConnectionID == connectionID ? nil : entry.envelope
        }
    }

    public mutating func markSent(deliveryID: String, connectionID: String) {
        guard let index = entries.firstIndex(where: { $0.envelope.deliveryId == deliveryID }) else { return }
        entries[index].lastSentConnectionID = connectionID
    }

    public mutating func markAllForReplay() {
        for index in entries.indices {
            entries[index].lastSentConnectionID = nil
        }
        replayCount += 1
    }

    public mutating func acknowledge(deliveryID: String, outcome: String?) -> AcknowledgementResult {
        guard let index = entries.firstIndex(where: { $0.envelope.deliveryId == deliveryID }) else {
            return .unmatched
        }
        guard let turnID else { return .unmatched }
        if entries[index].envelope.kind == .audioInput {
            switch outcome {
            case "audio_input_processed", "audio_input_duplicate":
                return .retained
            case "audio_input_gap":
                markAllForReplay()
                return .replayRequired(turnID: turnID, outcome: "audio_input_gap")
            default:
                let safeOutcome = String((outcome ?? "unknown").prefix(80))
                reset()
                return .turnRejected(turnID: turnID, outcome: safeOutcome)
            }
        }
        guard entries[index].envelope.kind == .commitAudio else { return .retained }

        switch outcome {
        case "commit_processed", "commit_duplicate":
            reset()
            return .turnCompleted(turnID: turnID)
        case "commit_deferred_missing_audio":
            markAllForReplay()
            return .replayRequired(
                turnID: turnID,
                outcome: "commit_deferred_missing_audio"
            )
        default:
            let safeOutcome = String((outcome ?? "unknown").prefix(80))
            reset()
            return .turnRejected(turnID: turnID, outcome: safeOutcome)
        }
    }

    public mutating func reset() {
        turnID = nil
        audioBytes = 0
        envelopeCount = 0
        replayCount = 0
        startedAt = nil
        nextAudioSequence = 1
        hasCommit = false
        entries.removeAll(keepingCapacity: false)
    }
}

public struct ReliableAudioTurnReceiver: Sendable {
    public enum AudioDisposition: Equatable, Sendable {
        case accepted
        case duplicate
        case gap(expected: Int)
        case conflictingTurn
    }

    public enum CommitDisposition: Equatable, Sendable {
        case process
        case duplicate
        case deferred(expected: Int)
        case invalid
    }

    private var activeTurnID: String?
    private var nextExpectedAudioSequence = 1
    private var completedTurnIDs = [String]()

    public init() {}

    public mutating func receiveAudio(turnID: String, sequence: Int) -> AudioDisposition {
        if completedTurnIDs.contains(turnID) { return .duplicate }
        if activeTurnID == nil {
            activeTurnID = turnID
            nextExpectedAudioSequence = 1
        }
        guard activeTurnID == turnID else { return .conflictingTurn }
        if sequence < nextExpectedAudioSequence { return .duplicate }
        if sequence > nextExpectedAudioSequence { return .gap(expected: nextExpectedAudioSequence) }
        nextExpectedAudioSequence += 1
        return .accepted
    }

    public mutating func receiveCommit(turnID: String, finalAudioSequence: Int) -> CommitDisposition {
        if completedTurnIDs.contains(turnID) { return .duplicate }
        guard activeTurnID == turnID, finalAudioSequence >= 0 else { return .invalid }
        let receivedAudioSequence = nextExpectedAudioSequence - 1
        if finalAudioSequence > receivedAudioSequence {
            return .deferred(expected: nextExpectedAudioSequence)
        }
        guard finalAudioSequence == receivedAudioSequence else { return .invalid }
        completedTurnIDs.append(turnID)
        if completedTurnIDs.count > 4 { completedTurnIDs.removeFirst() }
        activeTurnID = nil
        nextExpectedAudioSequence = 1
        return .process
    }

    public mutating func cancelActiveTurn() {
        activeTurnID = nil
        nextExpectedAudioSequence = 1
    }
}

public enum CaptureStartRecoveryPolicy {
    public enum Decision: Equatable, Sendable {
        case retry(delayMilliseconds: Int, nextAttempt: Int)
        case terminal
    }

    public static let recoverableEngineStartCode = 2_003_329_396
    public static let retryDelaysMilliseconds = [250, 750, 2_000]

    public static func decision(
        stage: String,
        preflightPassed: Bool,
        errorDomain: String,
        errorCode: Int,
        completedRetries: Int,
        mediaServicesLost: Bool,
        responseInFlight: Bool
    ) -> Decision {
        let normalizedDomain = errorDomain.lowercased()
        let isAudioDomain = normalizedDomain.contains("coreaudio")
            || normalizedDomain.contains("avfaudio")
            || normalizedDomain.contains("osstatus")
        guard stage == "engine_start",
              preflightPassed,
              isAudioDomain,
              errorCode == recoverableEngineStartCode,
              !mediaServicesLost,
              !responseInFlight,
              retryDelaysMilliseconds.indices.contains(completedRetries) else {
            return .terminal
        }
        return .retry(
            delayMilliseconds: retryDelaysMilliseconds[completedRetries],
            nextAttempt: completedRetries + 1
        )
    }
}
