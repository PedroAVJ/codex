import Foundation
import SentryWithoutUIKit

enum WatchTelemetry {
    private static let dsn = "https://a56304d3eee012e306ef36a869aa66e2@o4509707257905152.ingest.us.sentry.io/4511973556617216"

    static func start() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.pedro.CodexVoice.watch"
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.releaseName = "\(bundleIdentifier)@\(version)+\(build)"
            options.sendDefaultPii = false
            options.enableCrashHandler = false
            options.enableAppHangTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.tracesSampleRate = 1.0
            options.enableLogs = true
            options.debug = false
            options.beforeSend = { event in
                sanitize(event)
            }
            options.beforeSendSpan = { span in
                sanitize(span)
            }
            options.beforeSendLog = { log in
                sanitize(log)
            }
        }
        SentrySDK.configureScope { scope in
            scope.setUser(noGeolocationUser())
            scope.setTag(value: "watch", key: "component")
            scope.setTag(value: build, key: "build")
            scope.setTag(value: "pcm16_24000_mono", key: "audio.wire_format")
        }
        let launch = SentrySDK.startTransaction(
            name: "watch.app.start",
            operation: "app.lifecycle",
            bindToScope: true
        )
        SentrySDK.logger.info("Codex Voice component started", attributes: [
            "component": "watch",
            "build": build,
        ])
        launch.finish()

        if ProcessInfo.processInfo.arguments.contains("-CodexVoiceSentryVerification") {
            verifyLiveIngestion()
        }
    }

    static func record(_ diagnostic: WatchCaptureDiagnostic) {
        beginVoiceTraceIfNeeded(for: diagnostic.code)

        var attributes: [String: Any] = [
            "component": "watch",
            "code": diagnostic.code,
            "diagnostic_details": diagnostic.message,
        ]
        if let sampleRate = diagnostic.sampleRate { attributes["sample_rate"] = sampleRate }
        if let stage = diagnostic.stage { attributes["stage"] = stage }
        if let errorDomain = diagnostic.errorDomain {
            attributes["error_domain"] = errorDomain
            attributes["native_error_domain"] = errorDomain
        }
        if let errorCode = diagnostic.errorCode {
            attributes["error_code"] = errorCode
            attributes["native_error_code"] = String(errorCode)
        }
        if let failedCall = diagnostic.failedCall { attributes["failed_call"] = failedCall }

        if isFailure(diagnostic.code) {
            SentrySDK.logger.error("Watch audio stage failed", attributes: attributes)
            let error = NSError(
                domain: diagnostic.errorDomain ?? "CodexVoiceWatch.Audio",
                code: diagnostic.errorCode ?? 1,
                userInfo: [NSDebugDescriptionErrorKey: "Watch audio stage failed"]
            )
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: diagnostic.code, key: "audio.code")
                scope.setTag(value: diagnostic.stage ?? "unknown", key: "audio.stage")
                if let failedCall = diagnostic.failedCall {
                    scope.setExtra(value: failedCall, key: "audio.failed_call")
                }
            }
        } else if diagnostic.code == "first_buffer_timeout"
            || diagnostic.code == "no_speech"
            || diagnostic.code == "barge_in_capture_unavailable" {
            SentrySDK.logger.warn("Watch audio progress warning", attributes: attributes)
        } else {
            SentrySDK.logger.info("Watch audio stage completed", attributes: attributes)
        }

        updateVoiceTraceAfterRecording(for: diagnostic.code)
    }

    static func recordEnvelope(kind: String, deliveryID: String?, sequence: Int?) {
        var attributes: [String: Any] = [
            "component": "watch",
            "kind": kind,
        ]
        if let deliveryID { attributes["delivery_id"] = deliveryID }
        if let sequence { attributes["delivery_sequence"] = sequence }
        SentrySDK.logger.info("Watch bridge envelope received", attributes: attributes)
    }

    static func recordEnvelopeDisposition(
        kind: String,
        outcome: String,
        deliveryID: String?,
        sequence: Int?,
        payloadBytes: Int? = nil,
        warning: Bool = false
    ) {
        var attributes: [String: Any] = [
            "component": "watch",
            "kind": kind,
            "delivery_outcome": outcome,
        ]
        if let deliveryID { attributes["delivery_id"] = deliveryID }
        if let sequence { attributes["delivery_sequence"] = sequence }
        if let payloadBytes { attributes["payload_bytes"] = payloadBytes }
        if warning {
            SentrySDK.logger.warn("Watch bridge envelope handled with warning", attributes: attributes)
        } else {
            SentrySDK.logger.info("Watch bridge envelope handled", attributes: attributes)
        }
    }

    static func recordTransport(_ diagnostic: BridgeTransportDiagnostic) {
        var attributes: [String: Any] = [
            "component": "watch",
            "code": diagnostic.code,
        ]
        if let value = diagnostic.connectionID { attributes["transport_connection_id"] = value }
        if let value = diagnostic.deliveryID { attributes["delivery_id"] = value }
        if let value = diagnostic.sequence { attributes["delivery_sequence"] = value }
        if let value = diagnostic.envelopeKind { attributes["envelope_kind"] = value }
        if let value = diagnostic.deliveryOutcome { attributes["delivery_outcome"] = value }
        if let value = diagnostic.frameBytes { attributes["frame_bytes"] = value }
        if let value = diagnostic.payloadBytes { attributes["payload_bytes"] = value }
        if let value = diagnostic.latencyMilliseconds { attributes["delivery_latency_ms"] = value }
        if let value = diagnostic.previousSequence { attributes["previous_delivery_sequence"] = value }
        if let value = diagnostic.maximumMessageBytes { attributes["maximum_message_bytes"] = value }
        if let value = diagnostic.readyState { attributes["websocket_ready_state"] = value }
        if let value = diagnostic.closeCode { attributes["websocket_close_code"] = value }
        if let value = diagnostic.errorDomain {
            attributes["error_domain"] = value
            attributes["native_error_domain"] = value
        }
        if let value = diagnostic.errorCode {
            attributes["error_code"] = value
            attributes["native_error_code"] = String(value)
        }
        if let value = diagnostic.audioTurnID { attributes["audio_turn_id"] = value }
        if let value = diagnostic.audioTurnSequence { attributes["audio_turn_sequence"] = value }
        if let value = diagnostic.finalAudioSequence { attributes["final_audio_sequence"] = value }
        if let value = diagnostic.queueDepth { attributes["audio_queue_depth"] = value }
        if let value = diagnostic.queueBytes { attributes["audio_queue_bytes"] = value }
        if let value = diagnostic.replayCount { attributes["audio_replay_count"] = value }

        switch diagnostic.level {
        case .info:
            SentrySDK.logger.info("Watch relay transport stage completed", attributes: attributes)
        case .warning:
            SentrySDK.logger.warn("Watch relay transport warning", attributes: attributes)
        case .error:
            SentrySDK.logger.error("Watch relay transport failed", attributes: attributes)
            if shouldCaptureTransportIssue(diagnostic.code) {
                let error = NSError(
                    domain: diagnostic.errorDomain ?? "CodexVoiceWatch.Transport",
                    code: diagnostic.errorCode ?? 1,
                    userInfo: [NSDebugDescriptionErrorKey: "Watch relay transport failed"]
                )
                SentrySDK.capture(error: error) { scope in
                    scope.setTag(value: diagnostic.code, key: "transport.operation")
                    if let deliveryID = diagnostic.deliveryID {
                        scope.setExtra(value: deliveryID, key: "delivery.id")
                    }
                    if let sequence = diagnostic.sequence {
                        scope.setExtra(value: sequence, key: "delivery.sequence")
                    }
                }
            }
        }
    }

    static func recordLifecycle(_ code: String) {
        SentrySDK.logger.info("Watch lifecycle stage completed", attributes: [
            "component": "watch",
            "code": code,
        ])
    }

    static func recordFailure(_ code: String, error: Error) {
        let source = error as NSError
        let sanitized = NSError(
            domain: source.domain,
            code: source.code,
            userInfo: [NSDebugDescriptionErrorKey: "Watch operation failed"]
        )
        SentrySDK.logger.error("Watch operation failed", attributes: [
            "component": "watch",
            "code": code,
            "error_domain": source.domain,
            "error_code": source.code,
        ])
        SentrySDK.capture(error: sanitized) { scope in
            scope.setTag(value: code, key: "operation")
        }
        SentrySDK.span?.finish(status: .internalError)
    }

    private static func beginVoiceTraceIfNeeded(for code: String) {
        guard code == "capture_attempt" else { return }
        SentrySDK.span?.finish(status: .cancelled)
        _ = SentrySDK.startTransaction(
            name: "watch.voice.turn",
            operation: "voice.turn",
            bindToScope: true
        )
    }

    private static func updateVoiceTraceAfterRecording(for code: String) {
        switch code {
        case "speech_ended":
            let span = SentrySDK.span?.startChild(
                operation: "watch.audio.commit",
                description: "speech committed to bridge"
            )
            span?.finish()
        case "output_first_buffer":
            let span = SentrySDK.span?.startChild(
                operation: "watch.audio.first_output",
                description: "first provider audio converted"
            )
            span?.finish()
        case "output_finished":
            SentrySDK.span?.finish(status: .ok)
        case let failure where isFailure(failure):
            SentrySDK.span?.finish(status: .internalError)
        default:
            break
        }
    }

    private static func verifyLiveIngestion() {
        let transaction = SentrySDK.startTransaction(
            name: "watch.telemetry.verification",
            operation: "telemetry.verify",
            bindToScope: true
        )
        let span = transaction.startChild(
            operation: "telemetry.emit",
            description: "emit controlled verification signals"
        )
        SentrySDK.logger.info("Watch telemetry verification log", attributes: [
            "component": "watch",
            "verification": true,
        ])
        let error = NSError(
            domain: "CodexVoice.TelemetryVerification",
            code: 1,
            userInfo: [NSDebugDescriptionErrorKey: "Controlled Sentry verification event"]
        )
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: "true", key: "verification")
        }
        span.finish(status: .ok)
        transaction.finish(status: .ok)
        SentrySDK.flush(timeout: 5)
    }

    private static func isFailure(_ code: String) -> Bool {
        code.hasSuffix("_failed")
            || code == "first_buffer_timeout"
            || code == "audio_recovery_exhausted"
    }

    private static func shouldCaptureTransportIssue(_ code: String) -> Bool {
        code == "websocket_receive_failed"
            || code == "relay_frame_open_failed"
            || code == "secure_envelope_open_failed"
            || code == "delivery_ack_timeout"
            || code == "audio_turn_delivery_aborted"
            || code == "audio_turn_commit_rejected"
    }

    private static func noGeolocationUser() -> User {
        let user = User()
        user.ipAddress = "0.0.0.0"
        return user
    }

    private static func sanitize(_ event: Event) -> Event {
        event.user = noGeolocationUser()
        event.request = nil

        var tags = event.tags ?? [:]
        tags.removeValue(forKey: "app.device")
        event.tags = tags

        var context = event.context ?? [:]
        context.removeValue(forKey: "culture")
        if var app = context["app"] {
            app.removeValue(forKey: "device_app_hash")
            context["app"] = app
        }
        if var device = context["device"] {
            device.removeValue(forKey: "locale")
            context["device"] = device
        }
        event.context = context
        return event
    }

    private static func sanitize(_ log: SentryLog) -> SentryLog {
        log.setAttribute(nil, forKey: "user.id")
        log.setAttribute(nil, forKey: "user.name")
        log.setAttribute(nil, forKey: "user.email")
        return log
    }

    private static func sanitize(_ span: Span) -> Span {
        for key in [
            "user.id",
            "user.name",
            "user.email",
            "app.device",
            "device_app_hash",
            "device.locale",
            "url.query",
            "http.request.header.authorization",
        ] {
            span.removeData(key: key)
        }
        span.removeTag(key: "app.device")
        return span
    }
}
