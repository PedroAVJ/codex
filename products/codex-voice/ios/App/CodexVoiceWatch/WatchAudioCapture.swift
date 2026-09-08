import AVFoundation
import Foundation

struct WatchCaptureDiagnostic: Sendable {
    let code: String
    let message: String
    let sampleRate: Int?
    let samples: Int?
    let errorDomain: String?
    let errorCode: Int?
    let stage: String?
    let failedCall: String?

    init(
        code: String,
        message: String,
        sampleRate: Int? = nil,
        samples: Int? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        stage: String? = nil,
        failedCall: String? = nil
    ) {
        self.code = code
        self.message = message
        self.sampleRate = sampleRate
        self.samples = samples
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.stage = stage
        self.failedCall = failedCall
    }

    static func failure(
        code: String,
        stage: String,
        error: Error,
        engineRunning: Bool,
        detail: String? = nil
    ) -> WatchCaptureDiagnostic {
        let nsError = error as NSError
        let domain = sanitize(nsError.domain, limit: 80)
        let description = sanitize(nsError.localizedDescription, limit: 120)
        let failedCall = nsError.userInfo.first { key, _ in
            let normalizedKey = String(describing: key).lowercased()
            return normalizedKey.contains("failed call") || normalizedKey.contains("failedaudiocall")
        }.map { sanitize(String(describing: $0.value), limit: 80) }
        let failedCallDetail = failedCall.map { " failed_call=\($0)" } ?? ""
        let extraDetail = detail.map { " \(sanitize($0, limit: 120))" } ?? ""
        return WatchCaptureDiagnostic(
            code: code,
            message: "stage=\(sanitize(stage, limit: 48)) error_domain=\(domain) error_code=\(nsError.code) engine_running=\(engineRunning ? 1 : 0) error=\(description)\(failedCallDetail)\(extraDetail)",
            errorDomain: domain,
            errorCode: nsError.code,
            stage: sanitize(stage, limit: 48),
            failedCall: failedCall
        )
    }

    private static func sanitize(_ value: String, limit: Int) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " =.,_:-/()[]"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(String(scalars).prefix(limit))
    }
}

struct WatchAudioCaptureStartupFailure: LocalizedError {
    let stage: String
    let preflightPassed: Bool
    let underlyingError: NSError

    var errorDescription: String? { underlyingError.localizedDescription }
}

final class WatchAudioCapture {
    static let outputSampleRate = 24_000
    static let outputChannels = 1

    private let audioEngine: WatchDuplexAudioEngine
    private let callbackLock = NSLock()
    private var isRunning = false
    private var isEndingTurn = false
    private var detector = AutomaticSpeechTurnDetector()
    private var audioHandler: ((Data) -> Void)?
    private var speechStartedHandler: ((Data) -> Void)?
    private var speechEndedHandler: (() -> Void)?
    private var diagnosticHandler: ((WatchCaptureDiagnostic) -> Void)?
    private var hasReportedFirstBuffer = false
    private var samplesSinceLevelReport = 0
    private var conversionFailureCount = 0
    private var captureAttempt = 0
    private var captureGeneration = 0
    private var firstBufferTimeoutWorkItem: DispatchWorkItem?
    private var tappedInputNode: AVAudioInputNode?

    init(audioEngine: WatchDuplexAudioEngine) {
        self.audioEngine = audioEngine
    }

    func start(
        onAudio: @escaping (Data) -> Void,
        onSpeechStarted: @escaping (Data) -> Void,
        onSpeechEnded: @escaping () -> Void,
        onDiagnostic: @escaping (WatchCaptureDiagnostic) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        callbackLock.lock()
        captureGeneration &+= 1
        let generation = captureGeneration
        audioHandler = onAudio
        speechStartedHandler = onSpeechStarted
        speechEndedHandler = onSpeechEnded
        diagnosticHandler = onDiagnostic
        detector = AutomaticSpeechTurnDetector()
        isEndingTurn = false
        hasReportedFirstBuffer = false
        samplesSinceLevelReport = 0
        conversionFailureCount = 0
        firstBufferTimeoutWorkItem?.cancel()
        firstBufferTimeoutWorkItem = nil
        let alreadyRunning = isRunning
        let attempt = captureAttempt
        callbackLock.unlock()

        if alreadyRunning {
            onDiagnostic(WatchCaptureDiagnostic(
                code: "capture_rearmed",
                message: "attempt=\(attempt) detector_reset=1 engine_running=1 shared_engine=1"
            ))
            completion(.success(()))
            return
        }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            onDiagnostic(WatchCaptureDiagnostic(
                code: "permission",
                message: "record_permission=granted"
            ))
            configureAndStart(generation: generation, completion: completion)
        case .denied:
            onDiagnostic(WatchCaptureDiagnostic(
                code: "permission",
                message: "record_permission=denied"
            ))
            completion(.failure(AudioCaptureError.permissionDenied))
        case .undetermined:
            onDiagnostic(WatchCaptureDiagnostic(
                code: "permission",
                message: "record_permission=requested"
            ))
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self,
                          self.isCurrentCaptureGeneration(generation) else { return }
                    self.emit(WatchCaptureDiagnostic(
                        code: "permission",
                        message: granted ? "record_permission=granted" : "record_permission=denied"
                    ))
                    if granted {
                        self.configureAndStart(
                            generation: generation,
                            completion: completion
                        )
                    } else {
                        completion(.failure(AudioCaptureError.permissionDenied))
                    }
                }
            }
        @unknown default:
            onDiagnostic(WatchCaptureDiagnostic(
                code: "permission",
                message: "record_permission=unknown"
            ))
            completion(.failure(AudioCaptureError.permissionDenied))
        }
    }

    func stop() {
        callbackLock.lock()
        captureGeneration &+= 1
        captureAttempt &+= 1
        let onDiagnostic = diagnosticHandler
        audioHandler = nil
        speechStartedHandler = nil
        speechEndedHandler = nil
        diagnosticHandler = nil
        detector = AutomaticSpeechTurnDetector()
        isEndingTurn = false
        hasReportedFirstBuffer = false
        samplesSinceLevelReport = 0
        firstBufferTimeoutWorkItem?.cancel()
        firstBufferTimeoutWorkItem = nil
        let wasRunning = isRunning
        isRunning = false
        let tappedInputNode = self.tappedInputNode
        self.tappedInputNode = nil
        callbackLock.unlock()

        guard wasRunning || tappedInputNode != nil else { return }
        tappedInputNode?.removeTap(onBus: 0)
        onDiagnostic?(WatchCaptureDiagnostic(
            code: "capture_stopped",
            message: "input_tap=0 shared_engine_running=\(audioEngine.engineIsRunning ? 1 : 0)"
        ))
    }

    func invalidateAfterMediaServicesLoss() {
        callbackLock.lock()
        captureGeneration &+= 1
        captureAttempt &+= 1
        audioHandler = nil
        speechStartedHandler = nil
        speechEndedHandler = nil
        diagnosticHandler = nil
        detector = AutomaticSpeechTurnDetector()
        isRunning = false
        isEndingTurn = false
        hasReportedFirstBuffer = false
        samplesSinceLevelReport = 0
        conversionFailureCount = 0
        firstBufferTimeoutWorkItem?.cancel()
        firstBufferTimeoutWorkItem = nil
        tappedInputNode = nil
        callbackLock.unlock()
    }

    private func configureAndStart(
        generation: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        callbackLock.lock()
        guard captureGeneration == generation else {
            callbackLock.unlock()
            return
        }
        let alreadyRunning = isRunning
        callbackLock.unlock()
        guard !alreadyRunning else {
            completion(.success(()))
            return
        }

        callbackLock.lock()
        captureAttempt += 1
        let attempt = captureAttempt
        callbackLock.unlock()

        guard let engine = audioEngine.engine else {
            let error = RealtimeAudioPlayerError.graphUnavailable
            emit(WatchCaptureDiagnostic.failure(
                code: "capture_failed",
                stage: "audio_graph_unavailable",
                error: error,
                engineRunning: false
            ))
            completion(.failure(error))
            return
        }

        var stage = "input_node"
        var preflightPassed = false
        emit(WatchCaptureDiagnostic(
            code: "capture_attempt",
            message: "attempt=\(attempt) engine_running=\(engine.isRunning ? 1 : 0) shared_engine=1"
        ))

        do {
            let input = engine.inputNode
            stage = "input_format"
            let hardwareFormat = input.inputFormat(forBus: 0)
            let prestartInputFormat = input.outputFormat(forBus: 0)
            let session = AVAudioSession.sharedInstance()
            emit(WatchCaptureDiagnostic(
                code: "input_format",
                message: "hardware_rate=\(Int(hardwareFormat.sampleRate)) hardware_channels=\(hardwareFormat.channelCount) prestart_rate=\(Int(prestartInputFormat.sampleRate)) prestart_channels=\(prestartInputFormat.channelCount) session_rate=\(Int(session.sampleRate)) session_input_channels=\(session.inputNumberOfChannels) voice_processing=\(input.isVoiceProcessingEnabled ? 1 : 0) input_latency_ms=\(Int((session.inputLatency * 1_000).rounded()))"
            ))
            guard hardwareFormat.sampleRate > 0,
                  hardwareFormat.channelCount > 0,
                  prestartInputFormat.sampleRate > 0,
                  prestartInputFormat.channelCount > 0 else {
                throw AudioCaptureError.invalidInputFormat
            }
            guard let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(Self.outputSampleRate),
                    channels: AVAudioChannelCount(Self.outputChannels),
                    interleaved: true
                  ) else {
                throw AudioCaptureError.unsupportedFormat
            }

            var converter: AVAudioConverter?
            var converterInputSampleRate = 0.0
            var converterInputChannels: AVAudioChannelCount = 0
            var converterInputCommonFormat: AVAudioCommonFormat = .otherFormat
            var converterInputInterleaved = false

            stage = "tap_install"
            input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
                guard let self,
                      self.isCurrentCaptureAttempt(attempt) else { return }
                let inputFormat = buffer.format
                guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                    self.noteConversionFailure(
                        reason: "invalid_negotiated_format",
                        attempt: attempt
                    )
                    return
                }

                let inputFormatChanged = converter == nil
                    || converterInputSampleRate != inputFormat.sampleRate
                    || converterInputChannels != inputFormat.channelCount
                    || converterInputCommonFormat != inputFormat.commonFormat
                    || converterInputInterleaved != inputFormat.isInterleaved
                if inputFormatChanged {
                    guard let negotiatedConverter = AVAudioConverter(
                        from: inputFormat,
                        to: outputFormat
                    ) else {
                        self.noteConversionFailure(
                            reason: "converter_unavailable",
                            attempt: attempt
                        )
                        return
                    }
                    converter = negotiatedConverter
                    converterInputSampleRate = inputFormat.sampleRate
                    converterInputChannels = inputFormat.channelCount
                    converterInputCommonFormat = inputFormat.commonFormat
                    converterInputInterleaved = inputFormat.isInterleaved
                    self.emit(WatchCaptureDiagnostic(
                        code: "input_format_negotiated",
                        message: "input_rate=\(Int(inputFormat.sampleRate.rounded())) input_channels=\(inputFormat.channelCount) input_interleaved=\(inputFormat.isInterleaved ? 1 : 0) output_rate=\(Self.outputSampleRate) output_channels=\(Self.outputChannels)"
                    ), attempt: attempt)
                }
                guard let converter else {
                    self.noteConversionFailure(
                        reason: "converter_unavailable",
                        attempt: attempt
                    )
                    return
                }

                let ratio = Double(Self.outputSampleRate) / inputFormat.sampleRate
                let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio) + 8))
                guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                    self.noteConversionFailure(
                        reason: "buffer_allocation",
                        attempt: attempt
                    )
                    return
                }

                var suppliedInput = false
                var conversionError: NSError?
                let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                    if suppliedInput {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    suppliedInput = true
                    inputStatus.pointee = .haveData
                    return buffer
                }
                guard conversionError == nil,
                      status != .error,
                      converted.frameLength > 0 else {
                    self.noteConversionFailure(
                        reason: "converter_status_\(status.rawValue)",
                        attempt: attempt
                    )
                    return
                }

                let audioBuffer = converted.audioBufferList.pointee.mBuffers
                guard let bytes = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
                    self.noteConversionFailure(
                        reason: "empty_output",
                        attempt: attempt
                    )
                    return
                }
                self.consume(
                    Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize)),
                    attempt: attempt
                )
            }
            callbackLock.lock()
            tappedInputNode = input
            callbackLock.unlock()

            stage = "engine_start_preflight"
            let graph = try audioEngine.prepareForStart()
            emit(WatchCaptureDiagnostic(
                code: "audio_graph_prestart",
                message: "path=input \(graph.diagnosticMessage)",
                sampleRate: graph.playerSampleRate
            ))
            try audioEngine.validateVoiceProcessingGraph(graph)
            preflightPassed = true

            stage = "engine_start"
            let startedEngine = try audioEngine.startPreparedEngine()
            callbackLock.lock()
            isRunning = true
            callbackLock.unlock()
            scheduleFirstBufferTimeout(attempt: attempt)
            emit(WatchCaptureDiagnostic(
                code: "capture_started",
                message: String(
                    format: "attempt=%d input_rate=%.0f input_channels=%d output_rate=%d output_channels=%d engine_started=%d shared_engine=1",
                    attempt,
                    prestartInputFormat.sampleRate,
                    prestartInputFormat.channelCount,
                    Self.outputSampleRate,
                    Self.outputChannels,
                    startedEngine ? 1 : 0
                ),
                sampleRate: Self.outputSampleRate
            ))
            completion(.success(()))
        } catch {
            emit(WatchCaptureDiagnostic.failure(
                code: "capture_failed",
                stage: stage,
                error: error,
                engineRunning: audioEngine.engineIsRunning
            ))
            inputCleanupAfterFailure()
            completion(.failure(WatchAudioCaptureStartupFailure(
                stage: stage,
                preflightPassed: preflightPassed,
                underlyingError: error as NSError
            )))
        }
    }

    private func consume(_ data: Data, attempt: Int) {
        callbackLock.lock()
        guard isRunning,
              captureAttempt == attempt,
              !isEndingTurn else {
            callbackLock.unlock()
            return
        }
        guard let observation = detector.consume(data) else {
            callbackLock.unlock()
            return
        }

        let event = observation.event
        if case .some(.ended) = event { isEndingTurn = true }
        let onAudio = audioHandler
        let onSpeechStarted = speechStartedHandler
        let onSpeechEnded = speechEndedHandler
        let onDiagnostic = diagnosticHandler
        let handlerGeneration = captureGeneration

        var diagnostics = [WatchCaptureDiagnostic]()
        if !hasReportedFirstBuffer {
            hasReportedFirstBuffer = true
            firstBufferTimeoutWorkItem?.cancel()
            firstBufferTimeoutWorkItem = nil
            diagnostics.append(WatchCaptureDiagnostic(
                code: "first_buffer",
                message: "attempt=\(captureAttempt) pcm_bytes=\(data.count) samples=\(observation.snapshot.sampleCount) engine_running=\(isRunning ? 1 : 0)",
                sampleRate: Self.outputSampleRate,
                samples: observation.snapshot.sampleCount
            ))
        }

        samplesSinceLevelReport += observation.snapshot.sampleCount
        if samplesSinceLevelReport >= Self.outputSampleRate * 2 {
            samplesSinceLevelReport = 0
            diagnostics.append(WatchCaptureDiagnostic(
                code: "level",
                message: String(
                    format: "rms=%.0f peak=%.0f noise=%.0f start=%.0f speech=%d",
                    observation.snapshot.rms,
                    observation.snapshot.peak,
                    observation.snapshot.noiseFloorRMS,
                    observation.snapshot.startThresholdRMS,
                    observation.snapshot.hasSpeech ? 1 : 0
                ),
                sampleRate: Self.outputSampleRate
            ))
        }

        switch event {
        case .started(let preRoll):
            diagnostics.append(WatchCaptureDiagnostic(
                code: "speech_started",
                message: "pre_roll_bytes=\(preRoll.count) rms=\(Int(observation.snapshot.rms.rounded()))",
                sampleRate: Self.outputSampleRate,
                samples: preRoll.count / MemoryLayout<Int16>.size
            ))
        case .ended:
            diagnostics.append(WatchCaptureDiagnostic(
                code: "speech_ended",
                message: "end_silence_detected=1",
                sampleRate: Self.outputSampleRate
            ))
        case nil:
            break
        }
        callbackLock.unlock()

        guard isCurrentCaptureGeneration(handlerGeneration) else { return }
        diagnostics.forEach { onDiagnostic?($0) }
        onAudio?(data)
        switch event {
        case .started(let preRoll): onSpeechStarted?(preRoll)
        case .ended: onSpeechEnded?()
        case nil: break
        }
    }

    private func noteConversionFailure(reason: String, attempt: Int) {
        callbackLock.lock()
        guard isRunning, captureAttempt == attempt else {
            callbackLock.unlock()
            return
        }
        conversionFailureCount += 1
        let count = conversionFailureCount
        let onDiagnostic = diagnosticHandler
        let handlerGeneration = captureGeneration
        callbackLock.unlock()

        guard count == 1 || count.isMultiple(of: 25) else { return }
        guard isCurrentCaptureGeneration(handlerGeneration) else { return }
        onDiagnostic?(WatchCaptureDiagnostic(
            code: "conversion_failed",
            message: "reason=\(reason) count=\(count)"
        ))
    }

    private func emit(_ diagnostic: WatchCaptureDiagnostic) {
        callbackLock.lock()
        let onDiagnostic = diagnosticHandler
        callbackLock.unlock()
        onDiagnostic?(diagnostic)
    }

    private func emit(_ diagnostic: WatchCaptureDiagnostic, attempt: Int) {
        callbackLock.lock()
        guard captureAttempt == attempt else {
            callbackLock.unlock()
            return
        }
        let onDiagnostic = diagnosticHandler
        let handlerGeneration = captureGeneration
        callbackLock.unlock()
        guard isCurrentCaptureGeneration(handlerGeneration) else { return }
        onDiagnostic?(diagnostic)
    }

    private func isCurrentCaptureGeneration(_ generation: Int) -> Bool {
        callbackLock.lock()
        let isCurrent = captureGeneration == generation
        callbackLock.unlock()
        return isCurrent
    }

    private func isCurrentCaptureAttempt(_ attempt: Int) -> Bool {
        callbackLock.lock()
        let isCurrent = captureAttempt == attempt
        callbackLock.unlock()
        return isCurrent
    }

    private func inputCleanupAfterFailure() {
        callbackLock.lock()
        captureAttempt &+= 1
        firstBufferTimeoutWorkItem?.cancel()
        firstBufferTimeoutWorkItem = nil
        let tappedInputNode = self.tappedInputNode
        self.tappedInputNode = nil
        callbackLock.unlock()
        tappedInputNode?.removeTap(onBus: 0)
        callbackLock.lock()
        isRunning = false
        callbackLock.unlock()
    }

    private func scheduleFirstBufferTimeout(attempt: Int) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            guard self.isRunning,
                  !self.hasReportedFirstBuffer,
                  self.captureAttempt == attempt else {
                self.callbackLock.unlock()
                return
            }
            let onDiagnostic = self.diagnosticHandler
            let engineRunning = self.isRunning
            let handlerGeneration = self.captureGeneration
            self.callbackLock.unlock()
            guard self.isCurrentCaptureGeneration(handlerGeneration),
                  self.isCurrentCaptureAttempt(attempt) else { return }
            onDiagnostic?(WatchCaptureDiagnostic(
                code: "first_buffer_timeout",
                message: "attempt=\(attempt) seconds=3 engine_running=\(engineRunning ? 1 : 0) input_tap=1"
            ))
        }
        callbackLock.lock()
        firstBufferTimeoutWorkItem?.cancel()
        firstBufferTimeoutWorkItem = workItem
        callbackLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: workItem)
    }
}

enum AudioCaptureError: LocalizedError {
    case permissionDenied
    case invalidInputFormat
    case unsupportedFormat
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is required. Enable it in Watch Settings."
        case .invalidInputFormat:
            "The Watch microphone route does not expose a usable format."
        case .unsupportedFormat:
            "The Watch microphone format is not supported."
        case .converterUnavailable:
            "The Watch could not create the microphone audio converter."
        }
    }
}
