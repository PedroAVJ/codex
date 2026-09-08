import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import Testing
@testable import CodexVoiceProtocol

private func pcmFrame(amplitude: Int16, sampleCount: Int = 1_024) -> Data {
    let samples = [Int16](repeating: amplitude, count: sampleCount)
    return samples.withUnsafeBytes { Data($0) }
}

private func deterministicPCM(sampleCount: Int, seed: UInt64) -> [Int16] {
    var state = seed
    return (0..<sampleCount).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let centered = Int32((state >> 48) & 0xffff) - 32_768
        return Int16(clamping: centered / 3)
    }
}

private func pcmData(_ samples: [Int16]) -> Data {
    samples.withUnsafeBytes { Data($0) }
}

@Test func envelopeRoundTrips() throws {
    let original = WireEnvelope(
        kind: .audioInput,
        data: Data([1, 2, 3, 4]).base64EncodedString(),
        sampleRate: 24_000,
        numChannels: 1,
        samplesPerChannel: 2,
        deliveryId: "7777f70f-339e-43e8-a627-cbabea43a8f1",
        sequence: 42,
        deliveryKind: "audioInput",
        turnId: "turn-1",
        turnSequence: 7,
        capabilities: [ReliableAudioTurnProtocol.capability]
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WireEnvelope.self, from: data)
    #expect(decoded == original)
}

@Test func reliableAudioTurnReplaysTheObservedFiftyNinePlusFiveSequenceExactlyOnce() throws {
    var buffer = ReliableAudioTurnBuffer()
    var receiver = ReliableAudioTurnReceiver()
    let turnID = "physical-watch-turn"
    var nextDeliverySequence = 1

    func chunk() -> WireEnvelope {
        WireEnvelope(
            kind: .audioInput,
            data: Data(repeating: 7, count: 1_024).base64EncodedString(),
            sampleRate: 24_000,
            numChannels: 1,
            samplesPerChannel: 512
        )
    }

    for index in 1...59 {
        let result = buffer.appendAudio(
            chunk(),
            turnID: turnID,
            deliveryID: "delivery-\(index)",
            deliverySequence: nextDeliverySequence,
            now: 0
        )
        guard case .accepted = result else {
            Issue.record("The initial physical-watch chunk was not buffered")
            return
        }
        nextDeliverySequence += 1
    }

    let firstConnection = buffer.pendingEnvelopes(for: "connection-a")
    #expect(firstConnection.count == 59)
    for envelope in firstConnection {
        let deliveryID = try #require(envelope.deliveryId)
        let sequence = try #require(envelope.turnSequence)
        buffer.markSent(deliveryID: deliveryID, connectionID: "connection-a")
        #expect(receiver.receiveAudio(turnID: turnID, sequence: sequence) == .accepted)
    }

    for index in 60...64 {
        let result = buffer.appendAudio(
            chunk(),
            turnID: turnID,
            deliveryID: "delivery-\(index)",
            deliverySequence: nextDeliverySequence,
            now: 1
        )
        guard case .accepted = result else {
            Issue.record("The post-outage physical-watch chunk was not buffered")
            return
        }
        nextDeliverySequence += 1
    }
    let commitResult = buffer.appendCommit(
        WireEnvelope(kind: .commitAudio),
        deliveryID: "delivery-commit",
        deliverySequence: nextDeliverySequence,
        now: 1
    )
    guard case .accepted(let commitEnvelope) = commitResult else {
        Issue.record("The physical-watch turn commit was not buffered")
        return
    }

    var acceptedAudioChunks = 59
    var providerStarts = 0
    let resumedConnection = buffer.pendingEnvelopes(for: "connection-b")
    #expect(resumedConnection.count == 65)
    for envelope in resumedConnection {
        let deliveryID = try #require(envelope.deliveryId)
        buffer.markSent(deliveryID: deliveryID, connectionID: "connection-b")
        if envelope.kind == .audioInput {
            let sequence = try #require(envelope.turnSequence)
            switch receiver.receiveAudio(turnID: turnID, sequence: sequence) {
            case .accepted: acceptedAudioChunks += 1
            case .duplicate: break
            default: Issue.record("Replay introduced an audio gap or turn conflict")
            }
        } else if envelope.kind == .commitAudio {
            let finalSequence = try #require(envelope.finalAudioSequence)
            if receiver.receiveCommit(turnID: turnID, finalAudioSequence: finalSequence) == .process {
                providerStarts += 1
            }
        }
    }

    buffer.markAllForReplay()
    let lostCommitAcknowledgementReplay = buffer.pendingEnvelopes(for: "connection-b")
    for envelope in lostCommitAcknowledgementReplay {
        if envelope.kind == .audioInput {
            let sequence = try #require(envelope.turnSequence)
            #expect(receiver.receiveAudio(turnID: turnID, sequence: sequence) == .duplicate)
        } else if envelope.kind == .commitAudio {
            let finalSequence = try #require(envelope.finalAudioSequence)
            #expect(receiver.receiveCommit(turnID: turnID, finalAudioSequence: finalSequence) == .duplicate)
        }
    }

    #expect(acceptedAudioChunks == 64)
    #expect(providerStarts == 1)
    #expect(buffer.acknowledge(
        deliveryID: try #require(commitEnvelope.deliveryId),
        outcome: "commit_duplicate"
    ) == .turnCompleted(turnID: turnID))
    #expect(buffer.envelopeCount == 0)
    #expect(buffer.audioBytes == 0)
}

@Test func reliableAudioTurnAbortsInsteadOfPartiallyCommittingAfterItsBound() {
    var buffer = ReliableAudioTurnBuffer()
    let audio = WireEnvelope(
        kind: .audioInput,
        data: Data(repeating: 1, count: 1_024).base64EncodedString()
    )
    #expect(buffer.appendAudio(
        audio,
        turnID: "bounded-turn",
        deliveryID: "audio",
        deliverySequence: 1,
        now: 0
    ) != .rejected(.invalidPayload))
    #expect(buffer.appendCommit(
        WireEnvelope(kind: .commitAudio),
        deliveryID: "commit",
        deliverySequence: 2,
        now: ReliableAudioTurnProtocol.maximumDuration + 0.001
    ) == .rejected(.maximumDuration))
}

@Test func reliableAudioTurnBoundsCoverTheMaximumDetectedWatchTurn() {
    let detectorMaximumSeconds = AutomaticSpeechTurnDetector.Configuration().maximumTurnSeconds
    let wireBytesPerSecond = 24_000 * MemoryLayout<Int16>.size
    let minimumAudioCapacity = Int(detectorMaximumSeconds) * wireBytesPerSecond
    let minimumEnvelopeCapacity = Int(ceil(detectorMaximumSeconds * 48))

    #expect(ReliableAudioTurnProtocol.maximumDuration >= detectorMaximumSeconds)
    #expect(ReliableAudioTurnProtocol.maximumAudioBytes >= minimumAudioCapacity)
    #expect(ReliableAudioTurnProtocol.maximumEnvelopeCount >= minimumEnvelopeCapacity)
}

@Test func reliableAudioTurnReplaysGapsAndRejectsTheWholeTurnOnChunkFailure() throws {
    let audio = WireEnvelope(
        kind: .audioInput,
        data: Data(repeating: 1, count: 1_024).base64EncodedString()
    )
    var gapBuffer = ReliableAudioTurnBuffer()
    for sequence in 1...2 {
        guard case .accepted(let envelope) = gapBuffer.appendAudio(
            audio,
            turnID: "gap-turn",
            deliveryID: "gap-\(sequence)",
            deliverySequence: sequence,
            now: 0
        ) else {
            Issue.record("Audio should fit inside the reliable turn buffer")
            return
        }
        gapBuffer.markSent(
            deliveryID: try #require(envelope.deliveryId),
            connectionID: "connection-a"
        )
    }
    #expect(gapBuffer.acknowledge(
        deliveryID: "gap-1",
        outcome: "audio_input_gap"
    ) == .replayRequired(turnID: "gap-turn", outcome: "audio_input_gap"))
    #expect(gapBuffer.pendingEnvelopes(for: "connection-a").count == 2)

    var rejectedBuffer = ReliableAudioTurnBuffer()
    _ = rejectedBuffer.appendAudio(
        audio,
        turnID: "rejected-turn",
        deliveryID: "rejected-1",
        deliverySequence: 1,
        now: 0
    )
    #expect(rejectedBuffer.acknowledge(
        deliveryID: "rejected-1",
        outcome: "audio_input_rejected_invalid_format"
    ) == .turnRejected(
        turnID: "rejected-turn",
        outcome: "audio_input_rejected_invalid_format"
    ))
    #expect(rejectedBuffer.envelopeCount == 0)
}

@Test func captureStartRecoveryUsesASettlingRetryThenExhaustsWithoutTouchingAResponse() {
    let first = CaptureStartRecoveryPolicy.decision(
        stage: "engine_start",
        preflightPassed: true,
        errorDomain: "com.apple.coreaudio.avfaudio",
        errorCode: CaptureStartRecoveryPolicy.recoverableEngineStartCode,
        completedRetries: 0,
        mediaServicesLost: false,
        responseInFlight: false
    )
    let second = CaptureStartRecoveryPolicy.decision(
        stage: "engine_start",
        preflightPassed: true,
        errorDomain: "com.apple.coreaudio.avfaudio",
        errorCode: CaptureStartRecoveryPolicy.recoverableEngineStartCode,
        completedRetries: 1,
        mediaServicesLost: false,
        responseInFlight: false
    )
    let settling = CaptureStartRecoveryPolicy.decision(
        stage: "engine_start",
        preflightPassed: true,
        errorDomain: "com.apple.coreaudio.avfaudio",
        errorCode: CaptureStartRecoveryPolicy.recoverableEngineStartCode,
        completedRetries: 2,
        mediaServicesLost: false,
        responseInFlight: false
    )
    let exhausted = CaptureStartRecoveryPolicy.decision(
        stage: "engine_start",
        preflightPassed: true,
        errorDomain: "com.apple.coreaudio.avfaudio",
        errorCode: CaptureStartRecoveryPolicy.recoverableEngineStartCode,
        completedRetries: 3,
        mediaServicesLost: false,
        responseInFlight: false
    )
    let responseProtected = CaptureStartRecoveryPolicy.decision(
        stage: "engine_start",
        preflightPassed: true,
        errorDomain: "com.apple.coreaudio.avfaudio",
        errorCode: CaptureStartRecoveryPolicy.recoverableEngineStartCode,
        completedRetries: 0,
        mediaServicesLost: false,
        responseInFlight: true
    )

    #expect(first == .retry(delayMilliseconds: 250, nextAttempt: 1))
    #expect(second == .retry(delayMilliseconds: 750, nextAttempt: 2))
    #expect(settling == .retry(delayMilliseconds: 2_000, nextAttempt: 3))
    #expect(exhausted == .terminal)
    #expect(responseProtected == .terminal)
}

@Test func deliveryAcknowledgementMetadataRoundTripsThroughBothTransportLayers() throws {
    let deliveryID = "542b25ae-f277-420b-a8aa-2b7b19ac7214"
    let acknowledgement = WireEnvelope(
        kind: .status,
        code: "delivery_ack",
        role: "device.delivery",
        deliveryId: deliveryID,
        sequence: 9,
        deliveryKind: "audioOutput",
        deliveryOutcome: "audio_enqueued"
    )
    let packet = BridgePacket(
        kind: .sealed,
        data: "opaque",
        deliveryId: deliveryID,
        sequence: 9
    )
    let relay = RelayMessage(
        kind: .frame,
        channel: "device",
        payload: "opaque",
        deliveryId: deliveryID,
        sequence: 9
    )

    #expect(try JSONDecoder().decode(
        WireEnvelope.self,
        from: JSONEncoder().encode(acknowledgement)
    ) == acknowledgement)
    #expect(try JSONDecoder().decode(
        BridgePacket.self,
        from: JSONEncoder().encode(packet)
    ) == packet)
    #expect(try JSONDecoder().decode(
        RelayMessage.self,
        from: JSONEncoder().encode(relay)
    ) == relay)
}

@Test func automaticTurnDetectorCatchesQuietSpeechAndEndsOnSilence() throws {
    var detector = AutomaticSpeechTurnDetector()

    for _ in 0..<6 {
        #expect(detector.consume(pcmFrame(amplitude: 65))?.event == nil)
    }

    #expect(detector.consume(pcmFrame(amplitude: 250))?.event == nil)
    let startObservation = detector.consume(pcmFrame(amplitude: 250))
    let start = try #require(startObservation)
    guard case .started(let preRoll) = start.event else {
        Issue.record("Quiet processed speech did not start a turn")
        return
    }
    #expect(!preRoll.isEmpty)
    #expect(start.snapshot.startThresholdRMS <= 250)

    var ended = false
    for _ in 0..<20 {
        if detector.consume(pcmFrame(amplitude: 0))?.event == .ended {
            ended = true
            break
        }
    }
    #expect(ended)
}

@Test func automaticTurnDetectorDoesNotTreatSteadyRoomNoiseAsSpeech() {
    var detector = AutomaticSpeechTurnDetector()

    for _ in 0..<80 {
        let observation = detector.consume(pcmFrame(amplitude: 105))
        #expect(observation?.event == nil)
        #expect(observation?.snapshot.hasSpeech == false)
    }
}

@Test func responseBargeInIgnoresTheExactPreOutputRegressionSequence() {
    var gate = ResponseBargeInGate()

    gate.committed()
    #expect(gate.state == .waitingForFirstAudio)
    #expect(gate.speechDecision() == .ignoreBeforeOutput)

    let armedOnFirstAudio = gate.receivedFirstAudio()
    #expect(armedOnFirstAudio)
    #expect(gate.state == .playbackStarted)
    #expect(gate.speechDecision() == .interruptPlayback)
}

@Test func responseBargeInArmsOnlyOnceAndResetsForListening() {
    var gate = ResponseBargeInGate()

    gate.committed()
    let firstArm = gate.receivedFirstAudio()
    let duplicateArm = gate.receivedFirstAudio()
    #expect(firstArm)
    #expect(!duplicateArm)

    gate.reset()
    #expect(gate.state == .inactive)
    #expect(gate.speechDecision() == .ignore)
}

@Test func responseBargeInRejectsAThinkingCallbackDeliveredAfterPlaybackStarts() {
    var gate = ResponseBargeInGate()

    gate.committed()
    let thinkingEpoch = gate.rearmedDetector()
    _ = gate.receivedFirstAudio()
    let playbackEpoch = gate.rearmedDetector()

    #expect(!gate.isCurrentDetectorEpoch(thinkingEpoch))
    #expect(gate.isCurrentDetectorEpoch(playbackEpoch))
    #expect(gate.speechDecision() == .interruptPlayback)
}

@Test func responseBargeInDefersTheInitialAcousticSettlingWindow() {
    var gate = ResponseBargeInGate()

    gate.committed()
    _ = gate.receivedFirstAudio()

    #expect(gate.speechDecision(playbackAgeMilliseconds: 200) == .ignoreInitialPlayback)
    #expect(gate.speechDecision(playbackAgeMilliseconds: 600) == .interruptPlayback)
}

@Test func responseBargeInRejectsMatchedSpeakerEchoButAllowsIndependentSpeech() {
    var gate = ResponseBargeInGate()

    gate.committed()
    _ = gate.receivedFirstAudio()

    #expect(gate.speechDecision(
        playbackAgeMilliseconds: 800,
        likelyPlaybackEcho: true
    ) == .ignorePlaybackEcho)
    #expect(gate.speechDecision(
        playbackAgeMilliseconds: 800,
        likelyPlaybackEcho: false
    ) == .interruptPlayback)
}

@Test func playbackEchoMatcherRecognizesDelayedScaledOutput() {
    let output = deterministicPCM(sampleCount: 24_000, seed: 7)
    let background = deterministicPCM(sampleCount: 8_400, seed: 11)
    let captured = zip(output[7_200..<15_600], background).map { outputSample, noiseSample in
        Int16(clamping: Int32(outputSample) / 5 + Int32(noiseSample) / 40)
    }
    var matcher = PlaybackEchoMatcher()

    matcher.appendReference(pcmData(output))
    let match = matcher.match(capturedPCM: pcmData(captured))

    #expect(match.isLikelyEcho)
    #expect(match.waveformCorrelation > 0.9)
    #expect(match.referenceSamples == output.count)
    #expect(match.capturedSamples == captured.count)
}

@Test func playbackEchoMatcherDoesNotRejectIndependentNearbySpeech() {
    let output = deterministicPCM(sampleCount: 24_000, seed: 17)
    let nearbySpeech = deterministicPCM(sampleCount: 8_400, seed: 23)
    var matcher = PlaybackEchoMatcher()

    matcher.appendReference(pcmData(output))
    let match = matcher.match(capturedPCM: pcmData(nearbySpeech))

    #expect(!match.isLikelyEcho)
    #expect(match.waveformCorrelation < 0.2)
}

@Test func playbackEchoMatcherTreatsDoubleTalkAsNearbySpeech() {
    let output = deterministicPCM(sampleCount: 24_000, seed: 29)
    let nearbySpeech = deterministicPCM(sampleCount: 8_400, seed: 31)
    let captured = zip(output[9_600..<18_000], nearbySpeech).map { outputSample, speechSample in
        Int16(clamping: Int32(outputSample) / 10 + Int32(speechSample) / 3)
    }
    var matcher = PlaybackEchoMatcher()

    matcher.appendReference(pcmData(output))
    let match = matcher.match(capturedPCM: pcmData(captured))

    #expect(!match.isLikelyEcho)
}

@Test func playbackEchoMatcherFollowsTheAudioPlaybackHead() {
    let output = deterministicPCM(sampleCount: 192_000, seed: 37)
    let captured = Array(output[120_000..<128_400])
    var matcher = PlaybackEchoMatcher()

    matcher.appendReference(pcmData(output))
    let beforePlaybackAdvances = matcher.match(capturedPCM: pcmData(captured))
    matcher.advancePlayback(by: 120_000)
    let whileThatAudioIsPlaying = matcher.match(capturedPCM: pcmData(captured))

    #expect(!beforePlaybackAdvances.isLikelyEcho)
    #expect(whileThatAudioIsPlaying.isLikelyEcho)
    #expect(whileThatAudioIsPlaying.waveformCorrelation > 0.9)
}

@Test func watchPairingContextKeysRemainDistinct() {
    let keys = Set([
        SecureBridgeProtocol.watchPairingContextKey,
        SecureBridgeProtocol.watchPairingTransferIDContextKey,
        SecureBridgeProtocol.watchPairingAcknowledgementContextKey,
    ])

    #expect(keys.count == 3)
}

@Test func pairingLinkRoundTrips() throws {
    let privateKey = P256.KeyAgreement.PrivateKey()
    let relayKey = SecureBridgeProtocol.randomBytes(count: 32)
    let link = PairingLink(
        serviceName: "Example Mac Agent",
        ticket: SecureBridgeProtocol.randomBytes(count: 32).base64URLEncodedString(),
        serverPublicKey: privateKey.publicKey.rawRepresentation.base64URLEncodedString(),
        expiresAt: Int(Date().addingTimeInterval(600).timeIntervalSince1970),
        relayURL: "wss://relay.example.com/api/relay",
        relayRoom: SecureBridgeProtocol.relayRoom(for: relayKey),
        relayKey: relayKey.base64URLEncodedString(),
        relayAuth: "signed-token"
    )

    #expect(try PairingLink(url: link.url) == link)

    var duplicated = URLComponents(url: link.url, resolvingAgainstBaseURL: false)!
    duplicated.queryItems?.append(URLQueryItem(name: "ticket", value: link.ticket))
    #expect(throws: SecureBridgeError.invalidPairingURL) {
        try PairingLink(url: duplicated.url!)
    }
}

@Test func shareableQRCodeDecodesIntoPairingLink() throws {
    let privateKey = P256.KeyAgreement.PrivateKey()
    let relayKey = SecureBridgeProtocol.randomBytes(count: 32)
    let link = PairingLink(
        serviceName: "Shared QR Mac",
        ticket: SecureBridgeProtocol.randomBytes(count: 32).base64URLEncodedString(),
        serverPublicKey: privateKey.publicKey.rawRepresentation.base64URLEncodedString(),
        expiresAt: Int(Date().addingTimeInterval(600).timeIntervalSince1970),
        relayURL: "wss://relay.example.com/api/relay",
        relayRoom: SecureBridgeProtocol.relayRoom(for: relayKey),
        relayKey: relayKey.base64URLEncodedString(),
        relayAuth: "signed-token"
    )

    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(Data(link.url.absoluteString.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    let image = try #require(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 4, y: 4)))
    let png = try #require(CIContext().pngRepresentation(
        of: image,
        format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()
    ))

    #expect(try PairingQRCodeDecoder.decode(png) == link)
}

@Test func relayAccessTokenRoundTripsAndRejectsTampering() throws {
    let server = P256.KeyAgreement.PrivateKey()
    let claims = RelayAccessClaims(
        room: SecureBridgeProtocol.randomBytes(count: 32).base64URLEncodedString(),
        role: .device,
        clientID: "watch",
        expiresAt: Int(Date().addingTimeInterval(600).timeIntervalSince1970)
    )
    let token = try RelayAccessToken.issue(claims: claims, serverPrivateKey: server)

    #expect(try RelayAccessToken.verify(token, serverPublicKey: server.publicKey) == claims)
    #expect(throws: SecureBridgeError.invalidRelayToken) {
        try RelayAccessToken.verify(token + "x", serverPublicKey: server.publicKey)
    }
}

@Test func securePayloadRoundTripsAcrossKeyAgreement() throws {
    let client = P256.KeyAgreement.PrivateKey()
    let server = P256.KeyAgreement.PrivateKey()
    let salt = SecureBridgeProtocol.randomBytes(count: 32)
    let clientKey = try SecureBridgeProtocol.deriveKey(
        privateKey: client,
        peerPublicKey: server.publicKey,
        salt: salt,
        context: "test"
    )
    let serverKey = try SecureBridgeProtocol.deriveKey(
        privateKey: server,
        peerPublicKey: client.publicKey,
        salt: salt,
        context: "test"
    )
    let message = WireEnvelope(kind: .status, message: "encrypted")
    let sealed = try SecureBridgeProtocol.seal(message, using: clientKey)

    #expect(try SecureBridgeProtocol.open(WireEnvelope.self, from: sealed, using: serverKey) == message)
}

@Test func decoderHandlesFragmentedAndCoalescedFrames() throws {
    let one = try FrameEncoder.encode(Data("one".utf8))
    let two = try FrameEncoder.encode(Data("two".utf8))
    let joined = one + two

    var decoder = FrameDecoder()
    #expect(try decoder.append(joined.prefix(3)).isEmpty)
    #expect(try decoder.append(joined.dropFirst(3).prefix(5)) == [Data("one".utf8)])
    #expect(try decoder.append(joined.dropFirst(8)) == [Data("two".utf8)])
}

@Test func oversizedFrameIsRejected() throws {
    var decoder = FrameDecoder()
    let size = FrameDecoder.maximumFrameBytes + 1
    let header = Data([
        UInt8((size >> 24) & 0xff),
        UInt8((size >> 16) & 0xff),
        UInt8((size >> 8) & 0xff),
        UInt8(size & 0xff),
    ])

    #expect(throws: FrameCodecError.frameTooLarge(size)) {
        try decoder.append(header)
    }
}
