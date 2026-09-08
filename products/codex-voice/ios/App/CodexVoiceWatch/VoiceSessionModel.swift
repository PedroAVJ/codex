@preconcurrency import AVFoundation
import Foundation

@MainActor
final class VoiceSessionModel: ObservableObject {
    enum Phase: Equatable {
        case pairing
        case connecting
        case ready
        case recording
        case thinking
        case speaking
    }

    @Published var phase: Phase = .pairing
    @Published var status = "Looking for your Mac"
    @Published var isPaired = false
    @Published var assistantText = ""
    @Published var errorText: String?
    @Published var pendingApproval: ApprovalRequest?
    @Published var isMuted = false
    @Published var sessionEnded = false

    private let bridge = BridgeConnection()
    private let duplexAudioEngine: WatchDuplexAudioEngine
    private let capture: WatchAudioCapture
    private let audioPlayer: RealtimeAudioPlayer
    private let pairingReceiver = WatchPairingReceiver()
    private var credentials: PairingCredentials?
    private var hasStarted = false
    private var backendReady = false
    private var shouldStartRecordingWhenReady = true
    private var hasDetectedSpeech = false
    private var responseBargeInGate = ResponseBargeInGate()
    private var responsePlaybackStartedUptime: TimeInterval?
    private var bargeInRearmTask: Task<Void, Never>?
    private var audioSessionIsActive = false
    private var audioSessionActivationInFlight = false
    private var audioSessionActivationAttemptID: UUID?
    private var audioSessionActivationTimeoutTask: Task<Void, Never>?
    private var audioSessionActivationRequestOutstanding = false
    private var deferredAudioSessionPreparation: (() -> Void)?
    private var deferredAudioSessionDeactivationRequired = false
    private var pendingBridgeCredentials: PairingCredentials?
    private var bridgeCredentials: PairingCredentials?
    private var lastInstalledTransferID: String?
    private var backendReadyRetryTask: Task<Void, Never>?
    private var captureWatchdogTask: Task<Void, Never>?
    private var captureStartRecoveryTask: Task<Void, Never>?
    private var mediaServicesAreLost = false
    private var audioRecoveryPending = false
    private var audioRecoveryGeneration = 0
    private var audioSessionObserverTokens = [NSObjectProtocol]()
    #if DEBUG
    private var debugPlaybackWatchdogTask: Task<Void, Never>?
    private var debugCaptureProbeStarted = false
    #endif

    var isBusy: Bool { phase == .thinking || phase == .speaking || phase == .connecting }

    init() {
        let duplexAudioEngine = WatchDuplexAudioEngine()
        self.duplexAudioEngine = duplexAudioEngine
        capture = WatchAudioCapture(audioEngine: duplexAudioEngine)
        audioPlayer = RealtimeAudioPlayer(audioEngine: duplexAudioEngine)
        credentials = PairingKeychain.load()
        if credentials != nil {
            isPaired = true
            phase = .connecting
            status = "Reconnecting to your Mac"
        } else {
            status = "Scan the Mac QR with the iPhone app"
        }

        bridge.onStatus = { [weak self] message in
            guard let self else { return }
            NSLog("Codex Voice Watch bridge: %@", message)
            WatchTelemetry.recordLifecycle("bridge_status_changed")
            self.status = message
        }
        bridge.onEnvelope = { [weak self] envelope in
            self?.handle(envelope) ?? "watch_handler_unavailable"
        }
        bridge.onTransportDiagnostic = { diagnostic in
            WatchTelemetry.recordTransport(diagnostic)
        }
        bridge.onAudioTurnDeliveryFailed = { [weak self] message in
            self?.handleAudioTurnDeliveryFailure(message)
        }
        bridge.onCredentialsUpdated = { [weak self] credentials in
            guard let self else { return }
            self.credentials = credentials
            try? PairingKeychain.save(credentials)
        }
        pairingReceiver.onCredentials = { [weak self] credentials, transferID in
            self?.install(credentials, transferID: transferID)
        }
        pairingReceiver.onStatus = { [weak self] message in
            guard let self, self.credentials == nil, self.phase == .pairing else { return }
            self.status = message
        }
        pairingReceiver.activate()
        audioPlayer.onFinished = { [weak self] in
            guard let self, self.isPaired, !self.sessionEnded, !self.isMuted else { return }
            #if DEBUG
            if Self.debugAudioProbe {
                self.debugPlaybackWatchdogTask?.cancel()
                self.debugPlaybackWatchdogTask = nil
                self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                    code: "audio_probe_output_finished",
                    message: "data_played_back=1"
                ))
                self.status = "Playback completed; testing microphone"
                self.startDebugCaptureProbe()
                return
            }
            #endif
            self.resetResponseBargeIn()
            self.phase = .ready
            self.status = "Listening"
            self.shouldStartRecordingWhenReady = true
            self.startRecordingIfRequested()
        }
        audioPlayer.onError = { [weak self] error in
            guard let self, !self.sessionEnded else { return }
            #if DEBUG
            if Self.debugAudioProbe {
                self.debugPlaybackWatchdogTask?.cancel()
                self.debugPlaybackWatchdogTask = nil
                self.handleAudioFailure(error, reason: "debug_probe_output")
                return
            }
            #endif
            self.handleAudioFailure(error, reason: "output")
        }
        audioPlayer.onDiagnostic = { [weak self] diagnostic in
            guard let self else { return }
            self.reportCaptureDiagnostic(diagnostic)
        }
        observeAudioSessionEvents()

        #if DEBUG
        applyDebugPreviewState()
        if Self.debugAudioProbe {
            hasStarted = true
            startDebugAudioProbe()
        }
        #endif
    }

    func start() {
        #if DEBUG
        if Self.debugAudioProbe {
            guard !hasStarted else { return }
            hasStarted = true
            startDebugAudioProbe()
            return
        }
        if Self.debugPreviewState != nil { return }
        #endif
        guard !hasStarted else { return }
        hasStarted = true
        sessionEnded = false
        if let credentials {
            connectWhenAudioIsReady(credentials)
        } else {
            phase = .pairing
            status = "Open Pedro Voice Agent on iPhone and send the pairing to this Watch"
        }
    }

    func open(_ url: URL) {
        guard url.scheme == "codexvoice", url.host == "talk" else { return }
        if sessionEnded {
            retry()
            return
        }
        shouldStartRecordingWhenReady = true
        start()
        startRecordingIfRequested()
    }

    func resolveApproval(approved: Bool) {
        guard let request = pendingApproval else { return }
        bridge.send(WireEnvelope(
            kind: .approvalDecision,
            requestId: request.requestID,
            approved: approved
        ))
        pendingApproval = nil
        status = approved ? "Approved" : "Declined"
    }

    func toggleMute() {
        guard isPaired, !sessionEnded else { return }
        isMuted.toggle()
        hasDetectedSpeech = false
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        captureStartRecoveryTask?.cancel()
        captureStartRecoveryTask = nil
        resetResponseBargeIn()

        if isMuted {
            capture.stop()
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "muted",
                message: "capture_paused=1"
            ))
            return
        }

        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "unmuted",
            message: "capture_paused=0"
        ))
        shouldStartRecordingWhenReady = true
        if mediaServicesAreLost {
            audioRecoveryPending = true
            phase = .connecting
            status = "Waiting for Watch audio services"
            return
        }
        if backendReady {
            phase = .ready
            startRecordingIfRequested()
        } else {
            phase = .connecting
            requestBackendStart()
        }
    }

    func endSession() {
        sessionEnded = true
        isMuted = false
        shouldStartRecordingWhenReady = false
        hasDetectedSpeech = false
        backendReady = false
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        captureStartRecoveryTask?.cancel()
        captureStartRecoveryTask = nil
        resetResponseBargeIn()
        audioRecoveryPending = false
        audioRecoveryGeneration &+= 1
        let nativeActivationWasOutstanding = audioSessionActivationRequestOutstanding
        let shouldDeactivateAudioSession = (audioSessionIsActive
            || nativeActivationWasOutstanding) && !mediaServicesAreLost
        cancelPendingAudioSessionActivation()
        audioSessionIsActive = false
        backendReadyRetryTask?.cancel()
        backendReadyRetryTask = nil
        capture.stop()
        audioPlayer.shutdown()
        if shouldDeactivateAudioSession, nativeActivationWasOutstanding {
            deferredAudioSessionDeactivationRequired = true
        } else if shouldDeactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
        bridge.send(WireEnvelope(kind: .stop))
        bridge.stop()
        hasStarted = false
        phase = .ready
        status = "Session ended"
        errorText = nil
    }

    func retry() {
        guard let credentials else {
            sessionEnded = false
            hasStarted = false
            start()
            return
        }
        sessionEnded = false
        isMuted = false
        errorText = nil
        audioRecoveryPending = true
        audioRecoveryGeneration &+= 1
        captureStartRecoveryTask?.cancel()
        captureStartRecoveryTask = nil
        cancelPendingAudioSessionActivation()

        if mediaServicesAreLost {
            shouldStartRecordingWhenReady = true
            hasStarted = true
            phase = .connecting
            status = "Waiting for Watch audio services"
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_recovery_waiting_for_reset",
                message: "reason=user_retry generation=\(audioRecoveryGeneration) pending_operation=1"
            ))
            return
        }

        capture.stop()
        audioPlayer.shutdown()
        audioSessionIsActive = false
        if audioSessionActivationRequestOutstanding {
            deferredAudioSessionDeactivationRequired = true
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_deactivation_deferred",
                message: "reason=user_retry native_request_outstanding=1"
            ))
        } else {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_graph_discarded",
            message: "reason=user_retry"
        ))
        backendReady = false
        shouldStartRecordingWhenReady = true
        hasStarted = true
        phase = .connecting
        connectWhenAudioIsReady(credentials, forceRestart: true)
    }

    private func beginRecording(
        preRoll: Data? = nil,
        completedCaptureStartRetries: Int = 0
    ) {
        guard !isMuted, !sessionEnded else { return }
        guard backendReady else {
            phase = .connecting
            status = "Connecting"
            requestBackendStart()
            return
        }
        errorText = nil
        assistantText = ""
        resetResponseBargeIn()
        hasDetectedSpeech = preRoll != nil
        phase = .recording
        status = "Preparing microphone"
        audioPlayer.stop()
        let sessionGeneration = audioRecoveryGeneration
        capture.start(
            onAudio: { [weak self] data in
                // WatchAudioCapture emits diagnostics, PCM, and turn boundaries
                // synchronously from one tap. A single FIFO queue preserves the
                // final-audio -> commit order; unstructured Tasks do not.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.audioRecoveryGeneration == sessionGeneration,
                          !self.mediaServicesAreLost,
                          !self.sessionEnded,
                          !self.isMuted else { return }
                    self.sendAudio(data)
                }
            },
            onSpeechStarted: { [weak self] preRoll in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.audioRecoveryGeneration == sessionGeneration,
                          !self.mediaServicesAreLost,
                          !self.sessionEnded,
                          !self.isMuted else { return }
                    self.speechDetected(preRoll)
                }
            },
            onSpeechEnded: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.audioRecoveryGeneration == sessionGeneration,
                          !self.mediaServicesAreLost,
                          !self.sessionEnded,
                          !self.isMuted else { return }
                    self.finishRecording()
                }
            },
            onDiagnostic: { [weak self] diagnostic in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.audioRecoveryGeneration == sessionGeneration,
                          !self.mediaServicesAreLost,
                          !self.sessionEnded else { return }
                    self.reportCaptureDiagnostic(diagnostic)
                }
            }
        ) { [weak self] result in
            guard let self,
                  self.audioRecoveryGeneration == sessionGeneration,
                  !self.mediaServicesAreLost,
                  !self.sessionEnded,
                  !self.isMuted,
                  self.phase == .recording else { return }
            switch result {
            case .success:
                self.phase = .recording
                self.status = "Listening"
                self.scheduleCaptureWatchdog()
                if let preRoll { self.sendAudio(preRoll) }
            case .failure(let error):
                self.handleAudioFailure(
                    error,
                    reason: "capture_start",
                    preRoll: preRoll,
                    completedCaptureStartRetries: completedCaptureStartRetries
                )
            }
        }
    }

    private func handleAudioFailure(
        _ error: Error,
        reason: String,
        preRoll: Data? = nil,
        completedCaptureStartRetries: Int = 0
    ) {
        let startupFailure = error as? WatchAudioCaptureStartupFailure
        let nativeError: Error = startupFailure?.underlyingError ?? error
        if reason == "capture_start", let startupFailure {
            let source = startupFailure.underlyingError
            switch CaptureStartRecoveryPolicy.decision(
                stage: startupFailure.stage,
                preflightPassed: startupFailure.preflightPassed,
                errorDomain: source.domain,
                errorCode: source.code,
                completedRetries: completedCaptureStartRetries,
                mediaServicesLost: mediaServicesAreLost,
                responseInFlight: phase == .thinking || phase == .speaking
            ) {
            case .retry(let delayMilliseconds, let nextAttempt):
                scheduleCaptureStartRecovery(
                    nativeError: source,
                    preRoll: preRoll,
                    delayMilliseconds: delayMilliseconds,
                    nextAttempt: nextAttempt
                )
                return
            case .terminal:
                if startupFailure.stage == "engine_start",
                   startupFailure.preflightPassed,
                   source.code == CaptureStartRecoveryPolicy.recoverableEngineStartCode,
                   completedCaptureStartRetries >= CaptureStartRecoveryPolicy.retryDelaysMilliseconds.count {
                    reportCaptureDiagnostic(WatchCaptureDiagnostic(
                        code: "audio_recovery_exhausted",
                        message: "reason=capture_start generation=\(audioRecoveryGeneration) attempts=\(completedCaptureStartRetries + 1) error_domain=\(source.domain) error_code=\(source.code)",
                        errorDomain: source.domain,
                        errorCode: source.code,
                        stage: startupFailure.stage
                    ))
                }
            }
        }
        if !mediaServicesAreLost, isMediaServicesFailure(nativeError) {
            handleMediaServicesWereLost(source: "native_error")
        }
        if mediaServicesAreLost, !sessionEnded, !isMuted {
            audioRecoveryPending = true
            shouldStartRecordingWhenReady = true
            phase = .connecting
            status = "Waiting for Watch audio services"
            let source = nativeError as NSError
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_failure_deferred_until_reset",
                message: "reason=\(reason) generation=\(audioRecoveryGeneration) error_domain=\(source.domain) error_code=\(source.code)"
            ))
            return
        }
        presentTerminalAudioFailure(nativeError, reason: reason)
    }

    private func scheduleCaptureStartRecovery(
        nativeError: NSError,
        preRoll: Data?,
        delayMilliseconds: Int,
        nextAttempt: Int
    ) {
        captureStartRecoveryTask?.cancel()
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        capture.stop()
        audioPlayer.shutdown()
        resetResponseBargeIn()
        audioSessionIsActive = false
        audioRecoveryGeneration &+= 1
        let recoveryGeneration = audioRecoveryGeneration
        phase = .recording
        status = "Restoring microphone"
        errorText = nil
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_recovery_scheduled",
            message: "reason=engine_start generation=\(recoveryGeneration) retry_attempt=\(nextAttempt) delay_ms=\(delayMilliseconds) graph_discarded=1 response_cancelled=0 error_domain=\(nativeError.domain) error_code=\(nativeError.code)",
            errorDomain: nativeError.domain,
            errorCode: nativeError.code,
            stage: "engine_start"
        ))

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_recovery_deactivated",
                message: "generation=\(recoveryGeneration) retry_attempt=\(nextAttempt)"
            ))
        } catch {
            reportCaptureDiagnostic(WatchCaptureDiagnostic.failure(
                code: "audio_recovery_deactivation_failed",
                stage: "capture_start_retry_deactivate",
                error: error,
                engineRunning: duplexAudioEngine.engineIsRunning,
                detail: "generation=\(recoveryGeneration) retry_attempt=\(nextAttempt)"
            ))
        }

        captureStartRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.audioRecoveryGeneration == recoveryGeneration,
                  !self.mediaServicesAreLost,
                  !self.sessionEnded,
                  !self.isMuted,
                  self.phase == .recording else { return }
            self.captureStartRecoveryTask = nil
            self.audioSessionActivationInFlight = true
            self.prepareAudioSession { [weak self] result in
                guard let self,
                      self.audioRecoveryGeneration == recoveryGeneration,
                      !self.mediaServicesAreLost,
                      !self.sessionEnded,
                      !self.isMuted else { return }
                self.audioSessionActivationInFlight = false
                switch result {
                case .success:
                    self.audioSessionIsActive = true
                    self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                        code: "audio_recovery_reactivated",
                        message: "reason=engine_start generation=\(recoveryGeneration) retry_attempt=\(nextAttempt) graph_generation=\(self.duplexAudioEngine.graphGeneration)"
                    ))
                    self.beginRecording(
                        preRoll: preRoll,
                        completedCaptureStartRetries: nextAttempt
                    )
                case .failure(let error):
                    self.handleAudioFailure(
                        error,
                        reason: "capture_start_recovery_activation"
                    )
                }
            }
        }
    }

    private func isMediaServicesFailure(_ error: Error) -> Bool {
        let source = error as NSError
        let domain = source.domain.lowercased()
        let isAudioDomain = source.domain == NSOSStatusErrorDomain
            || domain.contains("coreaudio")
            || domain.contains("avfaudio")
        let mediaServicesFailed = Int(AVAudioSession.ErrorCode.mediaServicesFailed.rawValue)
        return isAudioDomain && (source.code == mediaServicesFailed || source.code == -308)
    }

    private func presentTerminalAudioFailure(_ error: Error, reason: String) {
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        capture.stop()
        audioPlayer.shutdown()
        resetResponseBargeIn()
        deactivateAudioSessionAfterFailure(reason: reason)
        guard !mediaServicesAreLost else { return }
        let source = error as NSError
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_failure_terminal",
            message: "reason=\(reason) generation=\(audioRecoveryGeneration) error_domain=\(source.domain) error_code=\(source.code)"
        ))
        phase = .ready
        status = "Microphone unavailable"
        errorText = error.localizedDescription
    }

    private func finishRecording() {
        guard phase == .recording, !isMuted, !sessionEnded else { return }
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        hasDetectedSpeech = false
        bargeInRearmTask?.cancel()
        bargeInRearmTask = nil
        responsePlaybackStartedUptime = nil
        responseBargeInGate.committed()
        phase = .thinking
        status = "Thinking"
        shouldStartRecordingWhenReady = true
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "barge_in_waiting_for_output",
            message: "provider_audio_started=0 speech_interrupt_enabled=0"
        ))
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_turn_commit_enqueued",
            message: "callback_delivery=main_queue_fifo final_audio_ordered=1"
        ))
        bridge.send(WireEnvelope(kind: .commitAudio))
        beginBargeInMonitoring()
    }

    private func beginBargeInMonitoring() {
        guard !isMuted, !sessionEnded else { return }
        bargeInRearmTask?.cancel()
        bargeInRearmTask = nil
        hasDetectedSpeech = false
        let sessionGeneration = audioRecoveryGeneration
        let detectorEpoch = responseBargeInGate.rearmedDetector()
        capture.start(
            onAudio: { _ in },
            onSpeechStarted: { [weak self] preRoll in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.audioRecoveryGeneration == sessionGeneration,
                          !self.mediaServicesAreLost,
                          !self.sessionEnded,
                          !self.isMuted else { return }
                    self.handleBargeInSpeechStarted(preRoll, detectorEpoch: detectorEpoch)
                }
            },
            onSpeechEnded: {},
            onDiagnostic: { [weak self] diagnostic in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.audioRecoveryGeneration == sessionGeneration,
                          !self.mediaServicesAreLost,
                          !self.sessionEnded else { return }
                    self.reportCaptureDiagnostic(diagnostic)
                }
            }
        ) { [weak self] result in
            guard let self,
                  self.audioRecoveryGeneration == sessionGeneration,
                  !self.mediaServicesAreLost,
                  !self.sessionEnded,
                  !self.isMuted,
                  case .failure(let error) = result else { return }
            let nativeError = (error as? WatchAudioCaptureStartupFailure)?.underlyingError
                ?? error as NSError
            self.capture.stop()
            self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "barge_in_capture_unavailable",
                message: "provider_response_preserved=1 response_cancelled=0 error_domain=\(nativeError.domain) error_code=\(nativeError.code)",
                errorDomain: nativeError.domain,
                errorCode: nativeError.code,
                stage: (error as? WatchAudioCaptureStartupFailure)?.stage
            ))
        }
    }

    private func handleBargeInSpeechStarted(_ preRoll: Data, detectorEpoch: UInt64) {
        guard responseBargeInGate.isCurrentDetectorEpoch(detectorEpoch) else {
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "stale_barge_in_speech_discarded",
                message: "callback_epoch=\(detectorEpoch) active_epoch=\(responseBargeInGate.detectorEpoch)"
            ))
            return
        }
        let playbackEchoMatch = audioPlayer.playbackEchoMatch(for: preRoll)
        let playbackAgeMilliseconds = responsePlaybackStartedUptime.map {
            max(0, Int(((ProcessInfo.processInfo.systemUptime - $0) * 1_000).rounded()))
        } ?? .max
        switch responseBargeInGate.speechDecision(
            playbackAgeMilliseconds: playbackAgeMilliseconds,
            likelyPlaybackEcho: playbackEchoMatch.isLikelyEcho
        ) {
        case .ignore:
            return
        case .ignoreBeforeOutput:
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "pre_output_speech_ignored",
                message: "provider_audio_started=0 speech_interrupt_enabled=0 pre_roll_samples=\(preRoll.count / MemoryLayout<Int16>.size)",
                sampleRate: WatchAudioCapture.outputSampleRate,
                samples: preRoll.count / MemoryLayout<Int16>.size
            ))
        case .ignoreInitialPlayback:
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "initial_playback_speech_deferred",
                message: "playback_age_ms=\(playbackAgeMilliseconds) waveform_correlation_milli=\(Int((playbackEchoMatch.waveformCorrelation * 1_000).rounded())) envelope_correlation_milli=\(Int((playbackEchoMatch.envelopeCorrelation * 1_000).rounded())) reference_samples=\(playbackEchoMatch.referenceSamples) captured_samples=\(playbackEchoMatch.capturedSamples)",
                sampleRate: WatchAudioCapture.outputSampleRate,
                samples: preRoll.count / MemoryLayout<Int16>.size
            ))
            scheduleBargeInRearm(afterRejectedDetectorEpoch: detectorEpoch)
        case .ignorePlaybackEcho:
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "playback_echo_speech_rejected",
                message: "playback_age_ms=\(playbackAgeMilliseconds) waveform_correlation_milli=\(Int((playbackEchoMatch.waveformCorrelation * 1_000).rounded())) envelope_correlation_milli=\(Int((playbackEchoMatch.envelopeCorrelation * 1_000).rounded())) reference_samples=\(playbackEchoMatch.referenceSamples) captured_samples=\(playbackEchoMatch.capturedSamples)",
                sampleRate: WatchAudioCapture.outputSampleRate,
                samples: preRoll.count / MemoryLayout<Int16>.size
            ))
            scheduleBargeInRearm(afterRejectedDetectorEpoch: detectorEpoch)
        case .interruptPlayback:
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "playback_barge_in_triggered",
                message: "provider_audio_started=1 speech_interrupt_enabled=1 pre_roll_samples=\(preRoll.count / MemoryLayout<Int16>.size)",
                sampleRate: WatchAudioCapture.outputSampleRate,
                samples: preRoll.count / MemoryLayout<Int16>.size
            ))
            bridge.send(WireEnvelope(kind: .stop, code: "playback_barge_in"))
            beginRecording(preRoll: preRoll)
        }
    }

    private func scheduleBargeInRearm(afterRejectedDetectorEpoch detectorEpoch: UInt64) {
        bargeInRearmTask?.cancel()
        bargeInRearmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.responseBargeInGate.isCurrentDetectorEpoch(detectorEpoch),
                  self.phase == .speaking,
                  !self.mediaServicesAreLost,
                  !self.sessionEnded,
                  !self.isMuted else { return }
            self.bargeInRearmTask = nil
            self.beginBargeInMonitoring()
        }
    }

    private func resetResponseBargeIn() {
        bargeInRearmTask?.cancel()
        bargeInRearmTask = nil
        responsePlaybackStartedUptime = nil
        responseBargeInGate.reset()
    }

    private func sendAudio(_ data: Data) {
        guard phase == .recording, hasDetectedSpeech, !data.isEmpty else { return }
        bridge.send(WireEnvelope(
            kind: .audioInput,
            data: data.base64EncodedString(),
            sampleRate: WatchAudioCapture.outputSampleRate,
            numChannels: WatchAudioCapture.outputChannels,
            samplesPerChannel: data.count / 2
        ))
    }

    private func speechDetected(_ preRoll: Data) {
        guard phase == .recording, !hasDetectedSpeech else { return }
        hasDetectedSpeech = true
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        sendAudio(preRoll)
    }

    private func handleAudioTurnDeliveryFailure(_ message: String) {
        guard !sessionEnded else { return }
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        capture.stop()
        hasDetectedSpeech = false
        resetResponseBargeIn()
        shouldStartRecordingWhenReady = false
        phase = .ready
        status = "Recording not sent"
        errorText = message
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_turn_delivery_failed",
            message: "full_turn_preserved=0 provider_started=0 user_retry_required=1"
        ))
    }

    private func reportCaptureDiagnostic(_ diagnostic: WatchCaptureDiagnostic) {
        WatchTelemetry.record(diagnostic)
        NSLog(
            "Codex Voice Watch audio: code=%@ sample_rate=%@ samples=%@ %@",
            diagnostic.code,
            diagnostic.sampleRate.map(String.init) ?? "none",
            diagnostic.samples.map(String.init) ?? "none",
            diagnostic.message
        )
        bridge.send(WireEnvelope(
            kind: .status,
            code: diagnostic.code,
            sampleRate: diagnostic.sampleRate,
            samplesPerChannel: diagnostic.samples,
            role: "watch.capture",
            message: diagnostic.message
        ))

        if diagnostic.code == "first_buffer" {
            audioRecoveryPending = false
        } else if diagnostic.code == "first_buffer_timeout" {
            let timeout = WatchAudioRecoveryError.firstBufferTimeout
            handleAudioFailure(timeout, reason: "first_buffer_timeout")
        }
    }

    private func scheduleCaptureWatchdog() {
        captureWatchdogTask?.cancel()
        captureWatchdogTask = Task { [weak self] in
            for interval in 1...3 {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.phase == .recording,
                      !self.hasDetectedSpeech,
                      !self.isMuted,
                      !self.sessionEnded else { return }
                self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                    code: "no_speech",
                    message: "seconds=\(interval * 8) detector_waiting=1"
                ))
            }
        }
    }

    private func handle(_ envelope: WireEnvelope) -> String {
        WatchTelemetry.recordEnvelope(
            kind: envelope.kind.rawValue,
            deliveryID: envelope.deliveryId,
            sequence: envelope.sequence
        )
        var outcome = "handled"
        var payloadBytes: Int?
        var warning = false
        defer {
            WatchTelemetry.recordEnvelopeDisposition(
                kind: envelope.kind.rawValue,
                outcome: outcome,
                deliveryID: envelope.deliveryId,
                sequence: envelope.sequence,
                payloadBytes: payloadBytes,
                warning: warning
            )
        }
        if let message = envelope.message, envelope.kind != .approval {
            NSLog("Codex Voice Watch backend %@: %@", envelope.kind.rawValue, message)
            status = message
        }

        switch envelope.kind {
        case .paired:
            NSLog("Codex Voice Watch relay: secure device pairing accepted")
            isPaired = true
            backendReady = false
            errorText = nil
            phase = .connecting
            if mediaServicesAreLost {
                outcome = "paired_waiting_for_audio_services"
                audioRecoveryPending = true
                shouldStartRecordingWhenReady = true
                status = "Waiting for Watch audio services"
                return outcome
            }
            outcome = "paired_backend_start_requested"
            requestBackendStart()
        case .ready:
            guard !sessionEnded else {
                outcome = "ready_ignored_session_ended"
                warning = true
                return outcome
            }
            NSLog("Codex Voice Watch relay: voice backend ready")
            backendReady = true
            errorText = nil
            backendReadyRetryTask?.cancel()
            backendReadyRetryTask = nil
            guard !mediaServicesAreLost else {
                outcome = "ready_waiting_for_audio_services"
                phase = .connecting
                status = "Waiting for Watch audio services"
                return outcome
            }
            if phase == .connecting || phase == .ready {
                outcome = "ready_recording_requested"
                phase = .ready
                startRecordingIfRequested()
            } else {
                outcome = "ready_state_preserved"
            }
        case .status:
            if envelope.message == "Thinking"
                || envelope.message == "Your agent is working"
                || envelope.message == "Passing request to your agent"
                || envelope.message == "Preparing answer through OpenRouter" {
                phase = .thinking
                outcome = "status_thinking_applied"
            } else {
                outcome = "status_applied"
            }
        case .audioOutput:
            guard phase != .recording else {
                outcome = "audio_discarded_while_recording"
                warning = true
                return outcome
            }
            guard !mediaServicesAreLost else {
                outcome = "audio_discarded_media_services_lost"
                warning = true
                return outcome
            }
            guard let encoded = envelope.data, let audio = Data(base64Encoded: encoded) else {
                outcome = "audio_base64_decode_failed"
                warning = true
                return outcome
            }
            payloadBytes = audio.count
            phase = .speaking
            status = "Speaking"
            guard audioPlayer.enqueue(audio) else {
                outcome = "audio_enqueue_rejected"
                warning = true
                return outcome
            }
            outcome = "audio_enqueued"
            let shouldArmBargeIn = responseBargeInGate.receivedFirstAudio()
            if shouldArmBargeIn {
                responsePlaybackStartedUptime = ProcessInfo.processInfo.systemUptime
                outcome = "first_audio_enqueued"
                reportCaptureDiagnostic(WatchCaptureDiagnostic(
                    code: "provider_first_audio_received",
                    message: "provider_audio_started=1 playback_commanded=1 speech_interrupt_enabled=1 playback_echo_guard=1"
                ))
                beginBargeInMonitoring()
            }
        case .audioOutputDone:
            guard !mediaServicesAreLost else {
                outcome = "audio_done_discarded_media_services_lost"
                warning = true
                return outcome
            }
            outcome = "audio_finish_requested"
            audioPlayer.finishStream()
        case .transcriptDelta:
            if envelope.role == "assistant" {
                outcome = "transcript_delta_applied"
                if phase != .speaking { phase = .thinking }
                assistantText += envelope.text ?? ""
            } else {
                outcome = "transcript_delta_ignored_role"
            }
        case .transcriptDone:
            if envelope.role == "assistant", let text = envelope.text, !text.isEmpty {
                outcome = "transcript_done_applied"
                assistantText = text
            } else {
                outcome = "transcript_done_ignored"
            }
        case .approval:
            if let requestID = envelope.requestId {
                outcome = "approval_presented"
                phase = .thinking
                status = "Approval needed"
                pendingApproval = ApprovalRequest(
                    requestID: requestID,
                    title: envelope.title ?? "Allow your agent?",
                    message: envelope.message ?? "Your agent wants permission to continue."
                )
            } else {
                outcome = "approval_missing_request_id"
                warning = true
            }
        case .error:
            guard !sessionEnded else {
                outcome = "error_ignored_session_ended"
                return outcome
            }
            capture.stop()
            audioPlayer.shutdown()
            resetResponseBargeIn()
            deactivateAudioSessionAfterFailure(reason: "backend_error")
            guard !mediaServicesAreLost else {
                outcome = "error_deferred_media_services_lost"
                warning = true
                return outcome
            }
            hasDetectedSpeech = false
            backendReady = false
            backendReadyRetryTask?.cancel()
            backendReadyRetryTask = nil
            captureWatchdogTask?.cancel()
            captureWatchdogTask = nil
            let message = envelope.message ?? "Something went wrong"
            errorText = message
            phase = credentials == nil ? .pairing : .connecting
            shouldStartRecordingWhenReady = credentials != nil
            if credentials != nil { requestBackendStart() }
            outcome = "backend_error_presented"
        default:
            outcome = "ignored_by_watch"
            break
        }
        return outcome
    }

    private func startRecordingIfRequested() {
        guard shouldStartRecordingWhenReady,
              phase == .ready,
              !isMuted,
              !sessionEnded else { return }
        guard audioSessionIsActive else {
            activateAudioSessionForPendingRecording()
            return
        }
        shouldStartRecordingWhenReady = false
        beginRecording()
    }

    private func activateAudioSessionForPendingRecording() {
        guard !audioSessionActivationInFlight else { return }
        guard !mediaServicesAreLost else {
            audioRecoveryPending = true
            phase = .connecting
            status = "Waiting for Watch audio services"
            return
        }

        audioSessionActivationInFlight = true
        audioRecoveryPending = true
        phase = .connecting
        status = "Preparing the voice session"
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_resume_activation_started",
            message: "generation=\(audioRecoveryGeneration) attempt=1"
        ))
        prepareAudioSession { [weak self] result in
            guard let self else { return }
            self.audioSessionActivationInFlight = false
            switch result {
            case .success:
                self.audioSessionIsActive = true
                self.audioRecoveryPending = false
                self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                    code: "audio_resume_activated",
                    message: "generation=\(self.audioRecoveryGeneration) attempt=1 \(self.audioSessionSnapshot())"
                ))
                if self.backendReady {
                    self.phase = .ready
                    self.startRecordingIfRequested()
                } else {
                    self.phase = .connecting
                    self.requestBackendStart()
                }
            case .failure(let error):
                self.audioSessionIsActive = false
                self.audioRecoveryPending = false
                self.handleAudioFailure(error, reason: "recording_resume_activation")
            }
        }
    }

    private func install(_ credentials: PairingCredentials, transferID: String?) {
        do {
            try PairingKeychain.save(credentials)
            NSLog("Codex Voice Watch pairing: secure credentials installed")
            pairingReceiver.acknowledge(transferID: transferID)
            let isNewTransfer = transferID != nil && transferID != lastInstalledTransferID
            if let transferID {
                lastInstalledTransferID = transferID
            }
            self.credentials = credentials
            isPaired = true
            backendReady = false
            backendReadyRetryTask?.cancel()
            backendReadyRetryTask = nil
            errorText = nil
            phase = .connecting
            status = "Secure pairing received from iPhone"
            connectWhenAudioIsReady(credentials, forceRestart: isNewTransfer)
        } catch {
            WatchTelemetry.recordFailure("pairing_install", error: error)
            errorText = error.localizedDescription
            phase = .pairing
        }
    }

    private func connectWhenAudioIsReady(
        _ credentials: PairingCredentials,
        forceRestart: Bool = false
    ) {
        pendingBridgeCredentials = credentials
        if forceRestart {
            bridge.stop()
            bridgeCredentials = nil
        }
        if bridgeCredentials == credentials,
           audioSessionIsActive || audioSessionActivationInFlight {
            return
        }
        bridgeCredentials = credentials

        if audioSessionIsActive {
            startPendingBridgeConnection()
            return
        }
        guard !audioSessionActivationInFlight else { return }

        audioSessionActivationInFlight = true
        phase = .connecting
        status = "Preparing the voice session"
        prepareAudioSession { [weak self] result in
            guard let self else { return }
            self.audioSessionActivationInFlight = false
            switch result {
            case .success:
                self.audioSessionIsActive = true
                self.startPendingBridgeConnection()
            case .failure(let error):
                self.audioSessionIsActive = false
                self.handleAudioFailure(error, reason: "session_activation")
            }
        }
    }

    private func startPendingBridgeConnection() {
        guard let credentials = pendingBridgeCredentials else { return }
        pendingBridgeCredentials = nil
        status = "Connecting to your Mac securely"
        prewarmCaptureForActiveSession()
        bridge.start(credentials: credentials, deviceName: "Apple Watch")
    }

    private func prewarmCaptureForActiveSession() {
        guard !sessionEnded, !isMuted, audioSessionIsActive else { return }
        let sessionGeneration = audioRecoveryGeneration
        capture.start(
            onAudio: { _ in },
            onSpeechStarted: { _ in },
            onSpeechEnded: {},
            onDiagnostic: { [weak self] diagnostic in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.audioRecoveryGeneration == sessionGeneration,
                          !self.mediaServicesAreLost,
                          !self.sessionEnded else { return }
                    self.reportCaptureDiagnostic(diagnostic)
                }
            }
        ) { [weak self] result in
            guard let self,
                  self.audioRecoveryGeneration == sessionGeneration,
                  !self.mediaServicesAreLost,
                  !self.sessionEnded,
                  !self.isMuted else { return }
            switch result {
            case .success:
                self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                    code: "audio_capture_prewarmed",
                    message: "engine_running=1 input_tap=1 before_backend_ready=1"
                ))
            case .failure(let error):
                self.handleAudioFailure(error, reason: "capture_start")
            }
        }
    }

    private func prepareAudioSession(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !mediaServicesAreLost else {
            completion(.failure(WatchAudioSessionError.mediaServicesUnavailable))
            return
        }
        guard !audioSessionActivationRequestOutstanding else {
            deferredAudioSessionPreparation = { [weak self] in
                self?.prepareAudioSession(completion: completion)
            }
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_activation_deferred",
                message: "reason=previous_native_request_outstanding"
            ))
            return
        }
        let session = AVAudioSession.sharedInstance()
        let sessionMode: AVAudioSession.Mode = .voiceChat
        let sessionCategory = "playAndRecord"
        let bluetoothHFP = 1
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_session_configuring",
            message: "category=\(sessionCategory) mode=\(sessionMode.rawValue) bluetooth_hfp=\(bluetoothHFP)"
        ))

        do {
            try session.setCategory(
                .playAndRecord,
                mode: sessionMode,
                policy: .default,
                options: [.allowBluetoothHFP]
            )
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_configured",
                message: "category=\(session.category.rawValue) mode=\(session.mode.rawValue)"
            ))
        } catch {
            reportCaptureDiagnostic(WatchCaptureDiagnostic.failure(
                code: "audio_session_failed",
                stage: "set_category",
                error: error,
                engineRunning: duplexAudioEngine.engineIsRunning
            ))
            completion(.failure(error))
            return
        }

        let activationAttemptID = UUID()
        audioSessionActivationAttemptID = activationAttemptID
        audioSessionActivationTimeoutTask?.cancel()
        audioSessionActivationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.audioSessionActivationAttemptID == activationAttemptID else { return }

            self.audioSessionActivationAttemptID = nil
            self.audioSessionActivationTimeoutTask = nil
            let failure = WatchAudioSessionError.activationTimedOut
            self.reportCaptureDiagnostic(WatchCaptureDiagnostic.failure(
                code: "audio_session_failed",
                stage: "activate_timeout",
                error: failure,
                engineRunning: self.duplexAudioEngine.engineIsRunning,
                detail: "timeout_seconds=8"
            ))
            completion(.failure(failure))
        }

        audioSessionActivationRequestOutstanding = true
        session.activate(options: []) { [weak self] activated, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioSessionActivationRequestOutstanding = false
                guard self.audioSessionActivationAttemptID == activationAttemptID else {
                    self.finishStaleAudioSessionActivation(activated: activated)
                    return
                }
                self.audioSessionActivationAttemptID = nil
                self.audioSessionActivationTimeoutTask?.cancel()
                self.audioSessionActivationTimeoutTask = nil
                guard activated, error == nil else {
                    let failure = error ?? WatchAudioSessionError.activationFailed
                    self.reportCaptureDiagnostic(WatchCaptureDiagnostic.failure(
                        code: "audio_session_failed",
                        stage: "activate",
                        error: failure,
                        engineRunning: self.duplexAudioEngine.engineIsRunning
                    ))
                    completion(.failure(failure))
                    return
                }

                let activeSession = AVAudioSession.sharedInstance()
                self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                    code: "audio_session_activated",
                    message: self.audioSessionSnapshot(),
                    sampleRate: Int(activeSession.sampleRate.rounded())
                ))
                do {
                    let graphGeneration = self.duplexAudioEngine.rebuildFreshGraph()
                    self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                        code: "audio_graph_recreated",
                        message: "reason=post_activation graph_generation=\(graphGeneration)"
                    ))
                    let graph = try self.duplexAudioEngine.configureForActiveSession { snapshot in
                        self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                            code: "audio_graph_snapshot",
                            message: snapshot.diagnosticMessage,
                            sampleRate: snapshot.playerSampleRate
                        ))
                    }
                    self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                        code: "audio_graph_configured",
                        message: "wire_rate=24000 wire_format=int16_interleaved direct_output=1 \(graph.diagnosticMessage)",
                        sampleRate: graph.playerSampleRate
                    ))
                    try self.duplexAudioEngine.validateVoiceProcessingGraph(graph)
                } catch {
                    self.reportCaptureDiagnostic(WatchCaptureDiagnostic.failure(
                        code: "audio_graph_failed",
                        stage: "configure_graph",
                        error: error,
                        engineRunning: self.duplexAudioEngine.engineIsRunning
                    ))
                    completion(.failure(error))
                    return
                }
                completion(.success(()))
            }
        }
    }

    private func cancelPendingAudioSessionActivation() {
        audioSessionActivationAttemptID = nil
        audioSessionActivationTimeoutTask?.cancel()
        audioSessionActivationTimeoutTask = nil
        deferredAudioSessionPreparation = nil
        deferredAudioSessionDeactivationRequired = false
        audioSessionActivationInFlight = false
    }

    private func finishStaleAudioSessionActivation(activated: Bool) {
        guard !mediaServicesAreLost else {
            deferredAudioSessionPreparation = nil
            deferredAudioSessionDeactivationRequired = false
            return
        }
        let shouldDeactivate = activated || deferredAudioSessionDeactivationRequired
        deferredAudioSessionDeactivationRequired = false
        if shouldDeactivate {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            audioSessionIsActive = false
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_stale_activation_deactivated",
                message: "newer_native_request=\(deferredAudioSessionPreparation == nil ? 0 : 1)"
            ))
        }
        if let deferredAudioSessionPreparation {
            self.deferredAudioSessionPreparation = nil
            deferredAudioSessionPreparation()
            return
        }
    }

    private func observeAudioSessionEvents() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        for name in [
            AVAudioSession.routeChangeNotification,
            AVAudioSession.interruptionNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ] {
            let token = center.addObserver(
                forName: name,
                object: session,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.recordAudioSessionEvent(notification)
                }
            }
            audioSessionObserverTokens.append(token)
        }
    }

    private func recordAudioSessionEvent(_ notification: Notification) {
        switch notification.name {
        case AVAudioSession.routeChangeNotification:
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.intValue ?? -1
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_event",
                message: mediaServicesAreLost
                    ? "type=route_change reason=\(reason) snapshot=deferred_until_reset"
                    : "type=route_change reason=\(reason) \(audioSessionSnapshot())"
            ))
        case AVAudioSession.interruptionNotification:
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.intValue ?? -1
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.intValue ?? 0
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_event",
                message: mediaServicesAreLost
                    ? "type=interruption interruption_type=\(type) interruption_options=\(options) snapshot=deferred_until_reset"
                    : "type=interruption interruption_type=\(type) interruption_options=\(options) \(audioSessionSnapshot())"
            ))
        case AVAudioSession.mediaServicesWereLostNotification:
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_event",
                message: "type=media_services_lost generation=\(audioRecoveryGeneration + 1)"
            ))
            handleMediaServicesWereLost(source: "notification")
        case AVAudioSession.mediaServicesWereResetNotification:
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_event",
                message: "type=media_services_reset generation=\(audioRecoveryGeneration + 1) \(audioSessionSnapshot())"
            ))
            handleMediaServicesWereReset()
        default:
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_event",
                message: "type=unknown"
            ))
        }
    }

    private func handleMediaServicesWereLost(source: String) {
        if mediaServicesAreLost {
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_recovery_waiting_for_reset",
                message: "source=\(source) generation=\(audioRecoveryGeneration) pending_operation=\(audioRecoveryPending ? 1 : 0) duplicate_notification=1 graph_discarded=0 activation_cancelled=0"
            ))
            return
        }

        mediaServicesAreLost = true
        audioRecoveryGeneration &+= 1
        let pendingOperation = hasStarted && !sessionEnded && !isMuted
        audioRecoveryPending = audioRecoveryPending || pendingOperation
        shouldStartRecordingWhenReady = audioRecoveryPending

        cancelPendingAudioSessionActivation()
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        captureStartRecoveryTask?.cancel()
        captureStartRecoveryTask = nil
        backendReadyRetryTask?.cancel()
        backendReadyRetryTask = nil
        #if DEBUG
        debugPlaybackWatchdogTask?.cancel()
        debugPlaybackWatchdogTask = nil
        debugCaptureProbeStarted = false
        #endif
        capture.invalidateAfterMediaServicesLoss()
        audioPlayer.invalidateAfterMediaServicesLoss()
        duplexAudioEngine.discardAfterMediaServicesLoss()
        audioSessionIsActive = false
        hasDetectedSpeech = false

        if audioRecoveryPending {
            bridge.send(WireEnvelope(kind: .stop))
            phase = .connecting
            status = "Waiting for Watch audio services"
            errorText = nil
        }
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_recovery_waiting_for_reset",
            message: "source=\(source) generation=\(audioRecoveryGeneration) pending_operation=\(audioRecoveryPending ? 1 : 0) duplicate_notification=0 graph_discarded=1 activation_cancelled=1"
        ))
    }

    private func handleMediaServicesWereReset() {
        let resetFollowedLoss = mediaServicesAreLost
        let pendingOperation = audioRecoveryPending
            || (hasStarted && !sessionEnded && !isMuted)
        mediaServicesAreLost = false
        audioRecoveryPending = pendingOperation
        audioRecoveryGeneration &+= 1
        let recoveryGeneration = audioRecoveryGeneration

        cancelPendingAudioSessionActivation()
        capture.invalidateAfterMediaServicesLoss()
        audioPlayer.invalidateAfterMediaServicesLoss()
        duplexAudioEngine.discardAfterMediaServicesLoss()
        audioSessionIsActive = false
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_graph_discarded",
            message: "reason=media_services_reset recovery_generation=\(recoveryGeneration) reset_followed_loss=\(resetFollowedLoss ? 1 : 0)"
        ))

        guard pendingOperation, !sessionEnded, !isMuted else {
            audioRecoveryPending = false
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_recovery_reset_idle",
                message: "generation=\(recoveryGeneration) pending_operation=0"
            ))
            return
        }

        phase = .connecting
        status = "Restoring the voice session"
        errorText = nil
        audioSessionActivationInFlight = true
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_recovery_reactivation_started",
            message: "generation=\(recoveryGeneration) attempt=1"
        ))
        prepareAudioSession { [weak self] result in
            guard let self,
                  self.audioRecoveryGeneration == recoveryGeneration,
                  !self.mediaServicesAreLost else { return }
            self.audioSessionActivationInFlight = false
            switch result {
            case .success:
                self.audioSessionIsActive = true
                self.audioRecoveryPending = false
                let graphGeneration = self.duplexAudioEngine.graphGeneration
                self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                    code: "audio_recovery_reactivated",
                    message: "generation=\(recoveryGeneration) graph_generation=\(graphGeneration) attempt=1 \(self.audioSessionSnapshot())"
                ))
                #if DEBUG
                if Self.debugAudioProbe {
                    self.phase = .ready
                    self.startDebugCaptureProbe()
                    return
                }
                #endif
                if self.pendingBridgeCredentials != nil {
                    self.startPendingBridgeConnection()
                } else if self.backendReady {
                    self.phase = .ready
                    self.startRecordingIfRequested()
                } else {
                    self.phase = .connecting
                    self.requestBackendStart()
                }
            case .failure(let error):
                self.audioRecoveryPending = false
                self.handleAudioFailure(
                    error,
                    reason: "media_services_reset_reactivation"
                )
            }
        }
    }

    private func deactivateAudioSessionAfterFailure(reason: String) {
        audioSessionIsActive = false
        guard !mediaServicesAreLost else { return }
        if audioSessionActivationRequestOutstanding {
            cancelPendingAudioSessionActivation()
            deferredAudioSessionDeactivationRequired = true
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_deactivation_deferred",
                message: "reason=\(reason) native_request_outstanding=1"
            ))
            return
        }

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            reportCaptureDiagnostic(WatchCaptureDiagnostic(
                code: "audio_session_deactivated_after_failure",
                message: "reason=\(reason)"
            ))
        } catch {
            reportCaptureDiagnostic(WatchCaptureDiagnostic.failure(
                code: "audio_session_deactivation_failed",
                stage: "deactivate_after_failure",
                error: error,
                engineRunning: duplexAudioEngine.engineIsRunning,
                detail: "reason=\(reason)"
            ))
            if isMediaServicesFailure(error) {
                handleMediaServicesWereLost(source: "deactivation_error")
            }
        }
    }

    private func audioSessionSnapshot() -> String {
        let session = AVAudioSession.sharedInstance()
        let inputRoutes = session.currentRoute.inputs
            .map { $0.portType.rawValue }
            .sorted()
            .joined(separator: ",")
        let outputRoutes = session.currentRoute.outputs
            .map { $0.portType.rawValue }
            .sorted()
            .joined(separator: ",")
        return String(
            format: "category=%@ mode=%@ options=%llu sample_rate=%.0f io_buffer_ms=%.1f input_available=%d input_channels=%d output_channels=%d input_latency_ms=%.1f output_latency_ms=%.1f input_routes=%@ output_routes=%@ other_audio=%d secondary_audio_silenced=%d",
            session.category.rawValue,
            session.mode.rawValue,
            session.categoryOptions.rawValue,
            session.sampleRate,
            session.ioBufferDuration * 1_000,
            session.isInputAvailable ? 1 : 0,
            session.inputNumberOfChannels,
            session.outputNumberOfChannels,
            session.inputLatency * 1_000,
            session.outputLatency * 1_000,
            inputRoutes.isEmpty ? "none" : inputRoutes,
            outputRoutes.isEmpty ? "none" : outputRoutes,
            session.isOtherAudioPlaying ? 1 : 0,
            session.secondaryAudioShouldBeSilencedHint ? 1 : 0
        )
    }

    private func requestBackendStart() {
        backendReadyRetryTask?.cancel()
        bridge.send(WireEnvelope(kind: .start))
        backendReadyRetryTask = Task { [weak self] in
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, let self, self.isPaired, !self.backendReady else { return }
                self.phase = .connecting
                self.status = attempt == 1
                    ? "Still connecting through OpenRouter"
                    : "Retrying OpenRouter securely"
                self.bridge.send(WireEnvelope(kind: .start))
            }
        }
    }

    #if DEBUG
    private static var debugAudioProbe: Bool {
        ProcessInfo.processInfo.arguments.contains("-CodexVoiceAudioProbe")
            || ProcessInfo.processInfo.arguments.contains("-CodexVoiceCaptureProbe")
    }

    private static var debugCaptureProbe: Bool {
        ProcessInfo.processInfo.arguments.contains("-CodexVoiceCaptureProbe")
    }

    private static func debugPlaybackPCM() -> (data: Data, source: String) {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-CodexVoiceAudioProbePCM"),
           arguments.indices.contains(index + 1),
           let fixture = try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])),
           !fixture.isEmpty,
           fixture.count.isMultiple(of: MemoryLayout<Int16>.size) {
            return (fixture, "backend_fixture")
        }

        let frameCount = RealtimeAudioPlayer.sampleRate / 4
        let halfPeriodFrames = 27
        var pcm = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let sample: Int16 = (frame / halfPeriodFrames).isMultiple(of: 2) ? 3_000 : -3_000
            var littleEndianSample = sample.littleEndian
            Swift.withUnsafeBytes(of: &littleEndianSample) { bytes in
                pcm.append(contentsOf: bytes)
            }
        }
        return (pcm, "synthetic_tone")
    }

    private static var debugPreviewState: String? {
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-CodexVoicePreviewState"),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1) else { return nil }
        return ProcessInfo.processInfo.arguments[index + 1]
    }

    private func startDebugAudioProbe() {
        guard !audioSessionActivationInFlight else { return }
        debugPlaybackWatchdogTask?.cancel()
        debugPlaybackWatchdogTask = nil
        debugCaptureProbeStarted = false
        isPaired = true
        sessionEnded = false
        phase = .connecting
        status = "Preparing microphone probe"
        errorText = nil
        audioSessionActivationInFlight = true
        reportCaptureDiagnostic(WatchCaptureDiagnostic(
            code: "audio_probe_started",
            message: "source=simulator_or_device bridge=0"
        ))

        prepareAudioSession { [weak self] result in
            guard let self else { return }
            self.audioSessionActivationInFlight = false
            switch result {
            case .failure(let error):
                self.handleAudioFailure(error, reason: "debug_probe_session_activation")
            case .success:
                self.audioSessionIsActive = true
                if Self.debugCaptureProbe {
                    self.phase = .recording
                    self.status = "Testing microphone before engine start"
                    self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                        code: "audio_probe_input_started",
                        message: "sequence=capture_before_playback"
                    ))
                    self.startDebugCaptureProbe()
                    return
                }
                self.phase = .speaking
                self.status = "Testing playback"
                let playbackFixture = Self.debugPlaybackPCM()
                let playbackPCM = playbackFixture.data
                let framePattern = [113, 997, 2_048, 509]
                var playbackChunks = [Data]()
                var byteOffset = 0
                var patternIndex = 0
                while byteOffset < playbackPCM.count {
                    let requestedBytes = framePattern[patternIndex % framePattern.count]
                        * MemoryLayout<Int16>.size
                    let end = min(playbackPCM.count, byteOffset + requestedBytes)
                    playbackChunks.append(playbackPCM.subdata(in: byteOffset..<end))
                    byteOffset = end
                    patternIndex += 1
                }
                self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                    code: "audio_probe_output_started",
                    message: "source=\(playbackFixture.source) pcm_bytes=\(playbackPCM.count) source_rate=\(RealtimeAudioPlayer.sampleRate) source_channels=1 source_chunks=\(playbackChunks.count)"
                ))
                let playbackSeconds = Double(playbackPCM.count / MemoryLayout<Int16>.size)
                    / Double(RealtimeAudioPlayer.sampleRate)
                let watchdogSeconds = max(3.0, playbackSeconds + 2.0)
                self.debugPlaybackWatchdogTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(watchdogSeconds))
                    guard !Task.isCancelled, let self, !self.debugCaptureProbeStarted else { return }
                    self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                        code: "audio_probe_output_failed",
                        message: "stage=data_played_back_timeout"
                    ))
                    self.status = "Playback callback timed out; testing microphone"
                    self.startDebugCaptureProbe()
                }
                playbackChunks.forEach { _ = self.audioPlayer.enqueue($0) }
                self.audioPlayer.finishStream()
            }
        }
    }

    private func startDebugCaptureProbe() {
        guard !debugCaptureProbeStarted else { return }
        debugCaptureProbeStarted = true
        debugPlaybackWatchdogTask?.cancel()
        debugPlaybackWatchdogTask = nil
        phase = .recording
        status = "Starting microphone stream"
        let sessionGeneration = audioRecoveryGeneration
        capture.start(
            onAudio: { _ in },
            onSpeechStarted: { [weak self] preRoll in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.audioRecoveryGeneration == sessionGeneration,
                          !self.mediaServicesAreLost,
                          !self.sessionEnded else { return }
                    self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                        code: "audio_probe_speech_started",
                        message: "pre_roll_bytes=\(preRoll.count)"
                    ))
                }
            },
            onSpeechEnded: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.audioRecoveryGeneration == sessionGeneration,
                          !self.mediaServicesAreLost,
                          !self.sessionEnded else { return }
                    self.reportCaptureDiagnostic(WatchCaptureDiagnostic(
                        code: "audio_probe_speech_ended",
                        message: "end_silence_detected=1"
                    ))
                }
            },
            onDiagnostic: { [weak self] diagnostic in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.audioRecoveryGeneration == sessionGeneration,
                          !self.mediaServicesAreLost,
                          !self.sessionEnded else { return }
                    self.reportCaptureDiagnostic(diagnostic)
                }
            }
        ) { [weak self] result in
            guard let self,
                  self.audioRecoveryGeneration == sessionGeneration,
                  !self.mediaServicesAreLost,
                  !self.sessionEnded else { return }
            switch result {
            case .success:
                self.phase = .recording
                self.status = "Microphone stream active"
            case .failure(let error):
                self.phase = .ready
                self.status = "Microphone probe failed"
                self.errorText = error.localizedDescription
            }
        }
    }

    private func applyDebugPreviewState() {
        guard let state = Self.debugPreviewState else { return }
        isPaired = true
        status = "Listening"
        errorText = nil
        switch state {
        case "connecting":
            phase = .connecting
            status = "Connecting to your Mac securely"
        case "error":
            phase = .connecting
            status = "Mac unavailable"
            errorText = "Check that Pedro Voice Agent is running on your Mac and try again."
        case "approval":
            phase = .thinking
            pendingApproval = ApprovalRequest(
                requestID: 1,
                title: "Run this command?",
                message: "Your agent wants permission to continue."
            )
        default:
            phase = .recording
        }
    }
    #endif
}

struct ApprovalRequest: Identifiable, Equatable {
    let requestID: Int
    let title: String
    let message: String
    var id: Int { requestID }
}

private enum WatchAudioSessionError: LocalizedError {
    case activationFailed
    case activationTimedOut
    case mediaServicesUnavailable

    var errorDescription: String? {
        switch self {
        case .activationFailed:
            "Apple Watch could not activate the voice audio session."
        case .activationTimedOut:
            "Apple Watch audio activation timed out."
        case .mediaServicesUnavailable:
            "Apple Watch audio services are restarting."
        }
    }
}

private enum WatchAudioRecoveryError: LocalizedError {
    case firstBufferTimeout

    var errorDescription: String? {
        "The Watch microphone started but did not deliver audio."
    }
}
