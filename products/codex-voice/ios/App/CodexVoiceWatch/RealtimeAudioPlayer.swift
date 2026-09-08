@preconcurrency import AVFoundation
import Foundation

struct WatchAudioGraphDescription {
    let stage: String
    let graphGeneration: Int
    let sessionSampleRate: Int
    let playerSampleRate: Int
    let playerChannels: Int
    let inputNodeInputASBD: String
    let inputNodeOutputASBD: String
    let outputNodeInputASBD: String
    let outputNodeOutputASBD: String
    let playerOutputASBD: String
    let inputVoiceProcessingEnabled: Bool
    let outputVoiceProcessingEnabled: Bool
    let ioFormatsUsable: Bool
    let criticalIOFormatsMatch: Bool
    let playerOutputMatchesOutputInput: Bool

    var diagnosticMessage: String {
        "graph_stage=\(stage) graph_generation=\(graphGeneration) session_rate=\(sessionSampleRate) player_rate=\(playerSampleRate) player_channels=\(playerChannels) input_vp=\(inputVoiceProcessingEnabled ? 1 : 0) output_vp=\(outputVoiceProcessingEnabled ? 1 : 0) io_formats_usable=\(ioFormatsUsable ? 1 : 0) critical_io_match=\(criticalIOFormatsMatch ? 1 : 0) player_output_match=\(playerOutputMatchesOutputInput ? 1 : 0) input_node_input_format=[\(inputNodeInputASBD)] input_node_output_format=[\(inputNodeOutputASBD)] output_node_input_format=[\(outputNodeInputASBD)] output_node_output_format=[\(outputNodeOutputASBD)] player_output_format=[\(playerOutputASBD)]"
    }
}

final class WatchDuplexAudioEngine {
    private final class Graph {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        var playerIsAttached = false
    }

    let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    private var graph: Graph?
    private(set) var graphGeneration = 0
    private(set) var playbackFormat: AVAudioFormat?
    private var playbackConverter: AVAudioConverter?

    var engine: AVAudioEngine? { graph?.engine }
    var player: AVAudioPlayerNode? { graph?.player }
    var engineIsRunning: Bool { graph?.engine.isRunning ?? false }

    func configureForActiveSession(
        onSnapshot: (WatchAudioGraphDescription) -> Void = { _ in }
    ) throws -> WatchAudioGraphDescription {
        guard let graph else {
            throw RealtimeAudioPlayerError.graphUnavailable
        }
        let session = AVAudioSession.sharedInstance()
        let engine = graph.engine
        let player = graph.player
        player.stop()
        if engine.isRunning { engine.stop() }
        engine.reset()
        playbackConverter?.reset()
        playbackConverter = nil
        playbackFormat = nil

        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let output = engine.outputNode
        let afterVoiceProcessing = graphDescription(
            for: graph,
            session: session,
            stage: "after_voice_processing"
        )
        onSnapshot(afterVoiceProcessing)
        try validateVoiceProcessingSnapshot(
            afterVoiceProcessing,
            requirePlayerOutputMatch: false
        )

        engine.attach(player)
        graph.playerIsAttached = true
        let requestedPlaybackFormat = input.outputFormat(forBus: 0)

        engine.connect(player, to: output, format: requestedPlaybackFormat)
        let afterDirectConnection = graphDescription(
            for: graph,
            session: session,
            stage: "after_direct_connection"
        )
        onSnapshot(afterDirectConnection)
        try validateVoiceProcessingSnapshot(
            afterDirectConnection,
            requirePlayerOutputMatch: true
        )

        engine.prepare()
        let afterPrepare = graphDescription(
            for: graph,
            session: session,
            stage: "after_prepare"
        )
        onSnapshot(afterPrepare)
        try validateVoiceProcessingSnapshot(
            afterPrepare,
            requirePlayerOutputMatch: true
        )
        let negotiatedPlaybackFormat = output.inputFormat(forBus: 0)
        guard negotiatedPlaybackFormat.sampleRate > 0,
              negotiatedPlaybackFormat.channelCount > 0,
              let converter = AVAudioConverter(
                from: wireFormat,
                to: negotiatedPlaybackFormat
              ) else {
            throw RealtimeAudioPlayerError.couldNotConfigureGraph
        }
        playbackFormat = negotiatedPlaybackFormat
        playbackConverter = converter
        return afterPrepare
    }

    @discardableResult
    func rebuildFreshGraph() -> Int {
        if let graph {
            graph.player.stop()
            if graph.engine.isRunning { graph.engine.stop() }
            graph.engine.reset()
        }
        playbackConverter?.reset()
        playbackConverter = nil
        playbackFormat = nil
        graphGeneration &+= 1
        graph = Graph()
        return graphGeneration
    }

    func discardAfterMediaServicesLoss() {
        playbackConverter = nil
        playbackFormat = nil
        graphGeneration &+= 1
        graph = nil
    }

    func prepareForStart() throws -> WatchAudioGraphDescription {
        guard let graph else {
            throw RealtimeAudioPlayerError.graphUnavailable
        }
        guard playbackFormat != nil, playbackConverter != nil else {
            throw RealtimeAudioPlayerError.graphNotConfigured
        }
        if !graph.engine.isRunning {
            graph.engine.prepare()
        }
        return graphDescription(
            for: graph,
            session: AVAudioSession.sharedInstance(),
            stage: "immediately_before_start"
        )
    }

    func validateVoiceProcessingGraph(_ description: WatchAudioGraphDescription) throws {
        try validateVoiceProcessingSnapshot(
            description,
            requirePlayerOutputMatch: true
        )
    }

    private func validateVoiceProcessingSnapshot(
        _ description: WatchAudioGraphDescription,
        requirePlayerOutputMatch: Bool
    ) throws {
        guard description.ioFormatsUsable else {
            throw RealtimeAudioPlayerError.invalidIOFormat(stage: description.stage)
        }
        guard description.inputVoiceProcessingEnabled,
              description.outputVoiceProcessingEnabled else {
            throw RealtimeAudioPlayerError.voiceProcessingNotEnabled
        }
        guard description.criticalIOFormatsMatch else {
            throw RealtimeAudioPlayerError.voiceProcessingIOFormatMismatch
        }
        if requirePlayerOutputMatch,
           !description.playerOutputMatchesOutputInput {
            throw RealtimeAudioPlayerError.playerOutputFormatMismatch
        }
    }

    @discardableResult
    func startPreparedEngine() throws -> Bool {
        guard let engine = graph?.engine else {
            throw RealtimeAudioPlayerError.graphUnavailable
        }
        guard playbackFormat != nil, playbackConverter != nil else {
            throw RealtimeAudioPlayerError.graphNotConfigured
        }
        guard !engine.isRunning else { return false }
        try engine.start()
        return true
    }

    func playbackBuffer(from data: Data) throws -> (buffer: AVAudioPCMBuffer?, sourceFrames: Int) {
        guard let playbackFormat, let playbackConverter else {
            throw RealtimeAudioPlayerError.graphNotConfigured
        }

        let sourceFrameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        let ratio = playbackFormat.sampleRate / wireFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(max(1, ceil(Double(sourceFrameCount) * ratio) + 64))
        guard let output = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: outputCapacity) else {
            throw RealtimeAudioPlayerError.couldNotCreateBuffer
        }

        var sourceByteOffset = 0
        var retainedInput: AVAudioPCMBuffer?
        var conversionError: NSError?
        let status = playbackConverter.convert(to: output, error: &conversionError) { requestedFrames, inputStatus in
            let remainingFrames = (data.count - sourceByteOffset) / MemoryLayout<Int16>.size
            guard remainingFrames > 0 else {
                inputStatus.pointee = .noDataNow
                return nil
            }

            let frameCount = min(max(1, Int(requestedFrames)), remainingFrames)
            guard let input = AVAudioPCMBuffer(
                pcmFormat: self.wireFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let destination = input.mutableAudioBufferList.pointee.mBuffers.mData else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            input.frameLength = AVAudioFrameCount(frameCount)
            let byteCount = frameCount * MemoryLayout<Int16>.size
            data.copyBytes(
                to: destination.assumingMemoryBound(to: UInt8.self),
                from: sourceByteOffset..<(sourceByteOffset + byteCount)
            )
            input.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
            sourceByteOffset += byteCount
            retainedInput = input
            inputStatus.pointee = .haveData
            return retainedInput
        }
        guard conversionError == nil,
              status != .error,
              sourceByteOffset == data.count else {
            throw conversionError ?? RealtimeAudioPlayerError.conversionFailed
        }
        return (output.frameLength > 0 ? output : nil, Int(sourceFrameCount))
    }

    func finishPlaybackConversion() throws -> [AVAudioPCMBuffer] {
        guard let playbackFormat, let playbackConverter else {
            throw RealtimeAudioPlayerError.graphNotConfigured
        }

        var buffers = [AVAudioPCMBuffer]()
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: 4_096) else {
                throw RealtimeAudioPlayerError.couldNotCreateBuffer
            }
            var conversionError: NSError?
            let status = playbackConverter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard conversionError == nil, status != .error else {
                throw conversionError ?? RealtimeAudioPlayerError.conversionFailed
            }
            if output.frameLength > 0 { buffers.append(output) }
            if status == .endOfStream { return buffers }
            if output.frameLength == 0 { break }
        }
        throw RealtimeAudioPlayerError.conversionFailed
    }

    func resetPlaybackConversion() {
        playbackConverter?.reset()
    }

    func shutdown() {
        graph?.player.stop()
        playbackConverter?.reset()
        playbackConverter = nil
        playbackFormat = nil
        if let graph {
            if graph.engine.isRunning { graph.engine.stop() }
            graph.engine.reset()
        }
        graphGeneration &+= 1
        graph = nil
    }

    private func graphDescription(
        for graph: Graph,
        session: AVAudioSession,
        stage: String
    ) -> WatchAudioGraphDescription {
        let input = graph.engine.inputNode
        let output = graph.engine.outputNode
        let inputNodeInputFormat = input.inputFormat(forBus: 0)
        let inputNodeOutputFormat = input.outputFormat(forBus: 0)
        let outputNodeInputFormat = output.inputFormat(forBus: 0)
        let outputNodeOutputFormat = output.outputFormat(forBus: 0)
        let playerOutputFormat = graph.playerIsAttached
            ? graph.player.outputFormat(forBus: 0)
            : nil

        return WatchAudioGraphDescription(
            stage: stage,
            graphGeneration: graphGeneration,
            sessionSampleRate: Int(session.sampleRate.rounded()),
            playerSampleRate: Int(playerOutputFormat?.sampleRate.rounded() ?? 0),
            playerChannels: Int(playerOutputFormat?.channelCount ?? 0),
            inputNodeInputASBD: Self.describe(inputNodeInputFormat),
            inputNodeOutputASBD: Self.describe(inputNodeOutputFormat),
            outputNodeInputASBD: Self.describe(outputNodeInputFormat),
            outputNodeOutputASBD: Self.describe(outputNodeOutputFormat),
            playerOutputASBD: playerOutputFormat.map(Self.describe)
                ?? "state=not_attached",
            inputVoiceProcessingEnabled: input.isVoiceProcessingEnabled,
            outputVoiceProcessingEnabled: output.isVoiceProcessingEnabled,
            ioFormatsUsable: session.sampleRate > 0 && [
                inputNodeInputFormat,
                inputNodeOutputFormat,
                outputNodeInputFormat,
                outputNodeOutputFormat,
            ].allSatisfy(Self.isUsable),
            criticalIOFormatsMatch: inputNodeOutputFormat.isEqual(
                outputNodeInputFormat
            ),
            playerOutputMatchesOutputInput: playerOutputFormat.map {
                $0.isEqual(outputNodeInputFormat)
            } ?? false
        )
    }

    private static func isUsable(_ format: AVAudioFormat) -> Bool {
        let value = format.streamDescription.pointee
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0,
              format.commonFormat != .otherFormat,
              value.mSampleRate.isFinite,
              value.mSampleRate == format.sampleRate,
              value.mFormatID == kAudioFormatLinearPCM,
              value.mBytesPerPacket > 0,
              value.mFramesPerPacket > 0,
              value.mBytesPerFrame > 0,
              value.mChannelsPerFrame == format.channelCount,
              value.mBitsPerChannel > 0,
              value.mReserved == 0,
              UInt64(value.mBytesPerPacket)
                == UInt64(value.mBytesPerFrame) * UInt64(value.mFramesPerPacket),
              format.channelLayout?.channelCount == nil
                || format.channelLayout?.channelCount == format.channelCount else {
            return false
        }

        let isNonInterleaved = value.mFormatFlags
            & kAudioFormatFlagIsNonInterleaved != 0
        guard isNonInterleaved == !format.isInterleaved else { return false }
        let isFloat = value.mFormatFlags & kAudioFormatFlagIsFloat != 0
        switch format.commonFormat {
        case .pcmFormatFloat32:
            return isFloat && value.mBitsPerChannel == 32
        case .pcmFormatFloat64:
            return isFloat && value.mBitsPerChannel == 64
        case .pcmFormatInt16:
            return !isFloat && value.mBitsPerChannel == 16
        case .pcmFormatInt32:
            return !isFloat && value.mBitsPerChannel == 32
        case .otherFormat:
            return false
        @unknown default:
            return false
        }
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        let value = format.streamDescription.pointee
        let layoutDescription = channelLayoutSignature(format)
        return String(
            format: "common=%u,interleaved=%d,standard=%d,%@,asbd_sr=%.0f,asbd_id=%08X,asbd_flags=%08X,asbd_bpp=%u,asbd_fpp=%u,asbd_bpf=%u,asbd_ch=%u,asbd_bits=%u,asbd_reserved=%u",
            format.commonFormat.rawValue,
            format.isInterleaved ? 1 : 0,
            format.isStandard ? 1 : 0,
            layoutDescription,
            value.mSampleRate,
            value.mFormatID,
            value.mFormatFlags,
            value.mBytesPerPacket,
            value.mFramesPerPacket,
            value.mBytesPerFrame,
            value.mChannelsPerFrame,
            value.mBitsPerChannel,
            value.mReserved
        )
    }

    private static func channelLayoutSignature(_ format: AVAudioFormat) -> String {
        if let channelLayout = format.channelLayout {
            let layout = channelLayout.layout.pointee
            return "layout_tag=\(layout.mChannelLayoutTag),layout_bitmap=\(layout.mChannelBitmap),layout_descriptions=\(layout.mNumberChannelDescriptions),layout_channels=\(channelLayout.channelCount)"
        }
        return "layout=none"
    }
}

@MainActor
final class RealtimeAudioPlayer {
    static let sampleRate = 24_000

    private let audioEngine: WatchDuplexAudioEngine
    private var pendingBuffers = 0
    private var streamIsFinished = false
    private var generation = 0
    private var hasReportedFirstBuffer = false
    private var unreportedSourceFrames = 0
    private var streamSourceFrames = 0
    private var streamOutputFrames = 0
    private var playbackEchoMatcher = PlaybackEchoMatcher()
    private var unscheduledEchoSourceFrames = 0

    var onFinished: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onDiagnostic: ((WatchCaptureDiagnostic) -> Void)?

    init(audioEngine: WatchDuplexAudioEngine) {
        self.audioEngine = audioEngine
    }

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Int16>.size) else { return false }
        var stage = "output_engine_preflight"
        do {
            let graph = try audioEngine.prepareForStart()
            onDiagnostic?(WatchCaptureDiagnostic(
                code: "audio_graph_prestart",
                message: "path=output \(graph.diagnosticMessage)",
                sampleRate: graph.playerSampleRate
            ))
            try audioEngine.validateVoiceProcessingGraph(graph)

            stage = "output_engine_start"
            let startedEngine = try audioEngine.startPreparedEngine()
            if startedEngine {
                onDiagnostic?(WatchCaptureDiagnostic(
                    code: "output_engine_started",
                    message: "shared_engine=1 engine_running=1"
                ))
            }

            stage = "output_convert"
            let converted = try audioEngine.playbackBuffer(from: data)
            unreportedSourceFrames += converted.sourceFrames
            streamSourceFrames += converted.sourceFrames
            playbackEchoMatcher.appendReference(data)
            unscheduledEchoSourceFrames += converted.sourceFrames

            if let buffer = converted.buffer, !hasReportedFirstBuffer {
                hasReportedFirstBuffer = true
                onDiagnostic?(WatchCaptureDiagnostic(
                    code: "output_first_buffer",
                    message: "pcm_bytes=\(data.count) converted_frames=\(buffer.frameLength) shared_engine=1",
                    sampleRate: Self.sampleRate,
                    samples: unreportedSourceFrames
                ))
                unreportedSourceFrames = 0
            }

            streamIsFinished = false
            if let buffer = converted.buffer {
                stage = "output_schedule"
                let echoSourceFrames = unscheduledEchoSourceFrames
                unscheduledEchoSourceFrames = 0
                schedulePlaybackBuffer(buffer, echoSourceFrames: echoSourceFrames)
            }
            return true
        } catch {
            onDiagnostic?(WatchCaptureDiagnostic.failure(
                code: "output_failed",
                stage: stage,
                error: error,
                engineRunning: audioEngine.engineIsRunning
            ))
            stop()
            onError?(error)
            return false
        }
    }

    func finishStream() {
        do {
            let flushedBuffers = try audioEngine.finishPlaybackConversion()
            let flushedFrames = flushedBuffers.reduce(0) { $0 + Int($1.frameLength) }
            if let first = flushedBuffers.first, !hasReportedFirstBuffer {
                hasReportedFirstBuffer = true
                onDiagnostic?(WatchCaptureDiagnostic(
                    code: "output_first_buffer",
                    message: "pcm_bytes=0 converted_frames=\(first.frameLength) shared_engine=1 source_buffered=1",
                    sampleRate: Self.sampleRate,
                    samples: unreportedSourceFrames
                ))
                unreportedSourceFrames = 0
            }
            for (index, buffer) in flushedBuffers.enumerated() {
                let echoSourceFrames = index == 0 ? unscheduledEchoSourceFrames : 0
                if index == 0 { unscheduledEchoSourceFrames = 0 }
                schedulePlaybackBuffer(buffer, echoSourceFrames: echoSourceFrames)
            }
            if flushedFrames > 0 {
                onDiagnostic?(WatchCaptureDiagnostic(
                    code: "output_converter_flushed",
                    message: "converted_frames=\(flushedFrames) pending_buffers=\(pendingBuffers)"
                ))
            }
            streamIsFinished = true
            onDiagnostic?(WatchCaptureDiagnostic(
                code: "output_stream_finished",
                message: "pending_buffers=\(pendingBuffers) source_frames=\(streamSourceFrames) output_frames=\(streamOutputFrames)"
            ))
            completeIfPossible()
        } catch {
            onDiagnostic?(WatchCaptureDiagnostic.failure(
                code: "output_failed",
                stage: "output_flush",
                error: error,
                engineRunning: audioEngine.engineIsRunning
            ))
            stop()
            onError?(error)
        }
    }

    func playbackEchoMatch(for capturedPCM: Data) -> PlaybackEchoMatcher.Match {
        playbackEchoMatcher.match(capturedPCM: capturedPCM)
    }

    func stop() {
        generation += 1
        audioEngine.player?.stop()
        audioEngine.resetPlaybackConversion()
        pendingBuffers = 0
        streamIsFinished = false
        hasReportedFirstBuffer = false
        unreportedSourceFrames = 0
        streamSourceFrames = 0
        streamOutputFrames = 0
        playbackEchoMatcher.reset()
        unscheduledEchoSourceFrames = 0
    }

    func invalidateAfterMediaServicesLoss() {
        generation += 1
        pendingBuffers = 0
        streamIsFinished = false
        hasReportedFirstBuffer = false
        unreportedSourceFrames = 0
        streamSourceFrames = 0
        streamOutputFrames = 0
        playbackEchoMatcher.reset()
        unscheduledEchoSourceFrames = 0
    }

    func shutdown() {
        stop()
        audioEngine.shutdown()
        onDiagnostic?(WatchCaptureDiagnostic(
            code: "output_engine_stopped",
            message: "shared_engine=1 engine_running=0"
        ))
    }

    private func completeIfPossible() {
        guard streamIsFinished, pendingBuffers == 0 else { return }
        audioEngine.player?.stop()
        audioEngine.resetPlaybackConversion()
        streamIsFinished = false
        hasReportedFirstBuffer = false
        let sourceFrames = streamSourceFrames
        let outputFrames = streamOutputFrames
        unreportedSourceFrames = 0
        streamSourceFrames = 0
        streamOutputFrames = 0
        onDiagnostic?(WatchCaptureDiagnostic(
            code: "output_finished",
            message: "pending_buffers=0 data_played_back=1 source_frames=\(sourceFrames) output_frames=\(outputFrames)"
        ))
        onFinished?()
    }

    private func schedulePlaybackBuffer(
        _ buffer: AVAudioPCMBuffer,
        echoSourceFrames: Int = 0
    ) {
        guard let player = audioEngine.player else {
            let error = RealtimeAudioPlayerError.graphUnavailable
            onDiagnostic?(WatchCaptureDiagnostic.failure(
                code: "output_failed",
                stage: "output_schedule",
                error: error,
                engineRunning: false
            ))
            invalidateAfterMediaServicesLoss()
            onError?(error)
            return
        }
        pendingBuffers += 1
        streamOutputFrames += Int(buffer.frameLength)
        let scheduledGeneration = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == scheduledGeneration else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                self.playbackEchoMatcher.advancePlayback(by: echoSourceFrames)
                self.completeIfPossible()
            }
        }
        if !player.isPlaying {
            player.play()
            onDiagnostic?(WatchCaptureDiagnostic(
                code: "output_playing",
                message: "pending_buffers=\(pendingBuffers) engine_running=\(audioEngine.engineIsRunning ? 1 : 0)"
            ))
        }
    }
}

enum RealtimeAudioPlayerError: LocalizedError {
    case couldNotConfigureGraph
    case graphUnavailable
    case graphNotConfigured
    case invalidIOFormat(stage: String)
    case voiceProcessingNotEnabled
    case voiceProcessingIOFormatMismatch
    case playerOutputFormatMismatch
    case couldNotCreateBuffer
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .couldNotConfigureGraph:
            "The Watch could not configure its active audio route."
        case .graphUnavailable, .graphNotConfigured:
            "The Watch audio session is not ready."
        case .invalidIOFormat:
            "The Watch audio route does not expose a usable format."
        case .voiceProcessingNotEnabled,
             .voiceProcessingIOFormatMismatch,
             .playerOutputFormatMismatch:
            "The Watch voice-processing audio route is inconsistent."
        case .couldNotCreateBuffer, .conversionFailed:
            "The Watch could not play the live audio stream."
        }
    }
}
