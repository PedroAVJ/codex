import Foundation
import Sentry

enum BridgeTelemetry {
    private static let defaultDSN = "https://a56304d3eee012e306ef36a869aa66e2@o4509707257905152.ingest.us.sentry.io/4511973556617216"

    static func start() {
        let environment = ProcessInfo.processInfo.environment
        SentrySDK.start { options in
            options.dsn = environment["CODEX_VOICE_SENTRY_DSN"] ?? defaultDSN
            options.environment = environment["SENTRY_ENVIRONMENT"] ?? "production"
            options.releaseName = environment["SENTRY_RELEASE"] ?? "codex-voice-bridge@0.3.11"
            options.sendDefaultPii = false
            options.enableCrashHandler = true
            options.enableAppHangTracking = true
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
            scope.setTag(value: "bridge", key: "component")
            scope.setTag(value: "openrouter", key: "voice.provider")
            scope.setTag(value: "pcm16_24000_mono", key: "audio.wire_format")
        }
        let launch = SentrySDK.startTransaction(
            name: "bridge.process.start",
            operation: "app.lifecycle",
            bindToScope: true
        )
        stage("bridge_started")
        launch.finish()
    }

    static func stage(_ code: String, attributes: [String: Any] = [:]) {
        var values = attributes
        values["component"] = "bridge"
        values["code"] = code
        SentrySDK.logger.info("Codex Voice bridge stage completed", attributes: values)
    }

    static func warning(_ code: String, attributes: [String: Any] = [:]) {
        var values = attributes
        values["component"] = "bridge"
        values["code"] = code
        SentrySDK.logger.warn("Codex Voice bridge warning", attributes: values)
    }

    static func failure(_ code: String, error: Error) {
        let source = error as NSError
        SentrySDK.logger.error("Codex Voice bridge operation failed", attributes: [
            "component": "bridge",
            "code": code,
            "error_domain": source.domain,
            "error_code": source.code,
        ])
        let sanitized = NSError(
            domain: source.domain,
            code: source.code,
            userInfo: [NSDebugDescriptionErrorKey: "Codex Voice bridge operation failed"]
        )
        SentrySDK.capture(error: sanitized) { scope in
            scope.setTag(value: code, key: "operation")
        }
        SentrySDK.span?.finish(status: .internalError)
    }

    static func beginVoiceTurn() {
        SentrySDK.span?.finish(status: .cancelled)
        _ = SentrySDK.startTransaction(
            name: "bridge.voice.turn",
            operation: "voice.turn",
            bindToScope: true
        )
        stage("voice_turn_started")
    }

    static func voiceStage(_ code: String, operation: String) {
        let child = SentrySDK.span?.startChild(operation: operation, description: code)
        child?.finish(status: .ok)
        stage(code)
    }

    static func finishVoiceTurn() {
        stage("voice_turn_finished")
        SentrySDK.span?.finish(status: .ok)
    }

    static func cancelVoiceTurn(_ code: String) {
        warning(code)
        SentrySDK.span?.finish(status: .cancelled)
    }

    static func watchDiagnostic(code: String, sampleRate: Int?) {
        var attributes: [String: Any] = [
            "component": "bridge",
            "source_component": "watch",
            "code": code,
        ]
        if let sampleRate { attributes["sample_rate"] = sampleRate }
        if code.hasSuffix("_failed") || code == "first_buffer_timeout" {
            SentrySDK.logger.error("Watch diagnostic reported failure", attributes: attributes)
        } else {
            SentrySDK.logger.info("Watch diagnostic received", attributes: attributes)
        }
    }

    static func flush() {
        SentrySDK.flush(timeout: 5)
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
