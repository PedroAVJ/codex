import Foundation
import Testing
@testable import CodexVoiceBridge
@testable import CodexVoiceProtocol

private func pcmFrame(amplitude: Int16, sampleCount: Int = 1_024) -> Data {
    let samples = [Int16](repeating: amplitude, count: sampleCount)
    return samples.withUnsafeBytes { Data($0) }
}

@Test func openRouterWAVEnvelopeMatchesWatchPCMFormat() {
    let pcm = Data([0x01, 0x02, 0x03, 0x04])
    let wav = OpenRouterVoiceSession.wavData(
        pcm16: pcm,
        sampleRate: 24_000,
        channelCount: 1
    )

    #expect(String(data: wav[0..<4], encoding: .ascii) == "RIFF")
    #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
    #expect(wav[20] == 1)
    #expect(wav[22] == 1)
    #expect(wav[24] == 0xC0)
    #expect(wav[25] == 0x5D)
    #expect(wav[34] == 16)
    #expect(String(data: wav[36..<40], encoding: .ascii) == "data")
    #expect(wav.suffix(pcm.count) == pcm)
}

@Test func openRouterUsesDirectMultimodalAudioInput() throws {
    let pcm = Data([0x01, 0x02, 0x03, 0x04])
    let message = OpenRouterVoiceSession.inputAudioMessage(pcm16: pcm)

    #expect(message["role"] as? String == "user")
    let content = try #require(message["content"] as? [[String: Any]])
    let part = try #require(content.first)
    #expect(part["type"] as? String == "input_audio")
    let input = try #require(part["input_audio"] as? [String: Any])
    #expect(input["format"] as? String == "wav")
    let encoded = try #require(input["data"] as? String)
    let wav = try #require(Data(base64Encoded: encoded))
    #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
    #expect(wav.suffix(pcm.count) == pcm)
}

@Test func openRouterHistoryKeepsTheNewestAudioTurnForImmediateFollowUp() throws {
    let firstAudio = OpenRouterVoiceSession.inputAudioMessage(pcm16: Data([0x01, 0x02]))
    let secondAudio = OpenRouterVoiceSession.inputAudioMessage(pcm16: Data([0x03, 0x04]))
    var history: [[String: Any]] = [
        firstAudio,
        ["role": "assistant", "content": "First answer"],
        secondAudio,
        ["role": "assistant", "content": "Second answer"],
    ]

    let result = OpenRouterVoiceSession.compactProcessedAudio(
        in: &history,
        maximumPreservedAudioTurns: 1
    )

    #expect(result.compactedAudioTurns == 1)
    #expect(result.preservedAudioTurns == 1)
    #expect(history[0]["content"] as? String == "Previous voice turn (audio omitted after processing).")
    _ = try #require(history[2]["content"] as? [[String: Any]])
}

@Test func openRouterHistoryDoesNotDiscardTheOnlyAudioTurn() throws {
    var history = [OpenRouterVoiceSession.inputAudioMessage(pcm16: Data([0x01, 0x02]))]

    let result = OpenRouterVoiceSession.compactProcessedAudio(in: &history)

    #expect(result.compactedAudioTurns == 0)
    #expect(result.preservedAudioTurns == 1)
    _ = try #require(history[0]["content"] as? [[String: Any]])
}

@Test func openRouterHistoryPreservesTypicalMultiTurnAudioWithinTheBoundedWindow() throws {
    var history: [[String: Any]] = []
    for index in 0..<4 {
        history.append(OpenRouterVoiceSession.inputAudioMessage(
            pcm16: Data(repeating: UInt8(index), count: 120_000)
        ))
        history.append(["role": "assistant", "content": "Answer \(index)"])
    }

    let result = OpenRouterVoiceSession.compactProcessedAudio(in: &history)

    #expect(result.compactedAudioTurns == 0)
    #expect(result.preservedAudioTurns == 4)
    for index in stride(from: 0, to: history.count, by: 2) {
        _ = try #require(history[index]["content"] as? [[String: Any]])
    }
}

@Test func openRouterHistoryAlwaysPreservesNewestAudioAndHonorsTheByteBudget() throws {
    var history: [[String: Any]] = [
        OpenRouterVoiceSession.inputAudioMessage(pcm16: Data(repeating: 1, count: 90_000)),
        ["role": "assistant", "content": "First"],
        OpenRouterVoiceSession.inputAudioMessage(pcm16: Data(repeating: 2, count: 90_000)),
        ["role": "assistant", "content": "Second"],
    ]

    let result = OpenRouterVoiceSession.compactProcessedAudio(
        in: &history,
        maximumPreservedAudioBytes: 100_000
    )

    #expect(result.compactedAudioTurns == 1)
    #expect(result.preservedAudioTurns == 1)
    #expect(history[0]["content"] as? String == "Previous voice turn (audio omitted after processing).")
    _ = try #require(history[2]["content"] as? [[String: Any]])
}

@Test func openRouterForwardsAudioAsEachStreamDeltaArrives() {
    let session = OpenRouterVoiceSession(
        apiKey: "test",
        model: "openai/gpt-audio-mini",
        voice: "alloy",
        queue: DispatchQueue(label: "OpenRouterVoiceSessionTests")
    )
    var received: [String] = []
    session.onAudio = { received.append($0) }

    session.processStreamLine(
        #"data: {"choices":[{"delta":{"audio":{"data":"AQID","transcript":"Hi"}}}]}"#
    )

    #expect(received == ["AQID"])
}

@Test func syntheticWatchAudioFlowsFromTurnDetectionThroughWireAndOpenRouterWAV() throws {
    var detector = AutomaticSpeechTurnDetector()
    var hasSpeech = false
    var turnEnded = false
    var transmittedPCM = Data()
    let frames = [Int16](repeating: 60, count: 8)
        + [Int16](repeating: 420, count: 12)
        + [Int16](repeating: 0, count: 20)

    for amplitude in frames {
        let frame = pcmFrame(amplitude: amplitude)
        let possibleObservation = detector.consume(frame)
        let observation = try #require(possibleObservation)
        if hasSpeech {
            transmittedPCM.append(frame)
        }
        switch observation.event {
        case .started(let preRoll):
            hasSpeech = true
            transmittedPCM.append(preRoll)
        case .ended:
            turnEnded = true
        case nil:
            break
        }
        if turnEnded { break }
    }

    #expect(turnEnded)
    #expect(!transmittedPCM.isEmpty)

    var receivedPCM = Data()
    for offset in stride(from: 0, to: transmittedPCM.count, by: 8_192) {
        let end = min(offset + 8_192, transmittedPCM.count)
        let chunk = transmittedPCM.subdata(in: offset..<end)
        let sent = WireEnvelope(
            kind: .audioInput,
            data: chunk.base64EncodedString(),
            sampleRate: 24_000,
            numChannels: 1,
            samplesPerChannel: chunk.count / MemoryLayout<Int16>.size
        )
        let encoded = try JSONEncoder().encode(sent)
        let received = try JSONDecoder().decode(WireEnvelope.self, from: encoded)
        #expect(received.sampleRate == 24_000)
        #expect(received.numChannels == 1)
        let receivedData = try #require(received.data)
        receivedPCM.append(try #require(Data(base64Encoded: receivedData)))
    }

    #expect(receivedPCM == transmittedPCM)
    let wav = OpenRouterVoiceSession.wavData(
        pcm16: receivedPCM,
        sampleRate: 24_000,
        channelCount: 1
    )
    #expect(String(data: wav[0..<4], encoding: .ascii) == "RIFF")
    #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
    #expect(wav.suffix(receivedPCM.count) == receivedPCM)

    let message = OpenRouterVoiceSession.inputAudioMessage(pcm16: receivedPCM)
    let content = try #require(message["content"] as? [[String: Any]])
    let firstPart = try #require(content.first)
    let input = try #require(firstPart["input_audio"] as? [String: Any])
    #expect(input["format"] as? String == "wav")
    let encodedAudio = try #require(input["data"] as? String)
    #expect(Data(base64Encoded: encodedAudio) == wav)
}
