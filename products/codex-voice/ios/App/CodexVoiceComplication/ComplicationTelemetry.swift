import Foundation
import SentryWithoutUIKit

enum ComplicationTelemetry {
    private static let dsn = "https://a56304d3eee012e306ef36a869aa66e2@o4509707257905152.ingest.us.sentry.io/4511973556617216"

    static func start() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.pedro.CodexVoice.complication"
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
            scope.setTag(value: "complication", key: "component")
            scope.setTag(value: build, key: "build")
        }
        let render = SentrySDK.startTransaction(
            name: "complication.bundle.start",
            operation: "widget.lifecycle",
            bindToScope: true
        )
        SentrySDK.logger.info("Codex Voice component started", attributes: [
            "component": "complication",
            "build": build,
        ])
        render.finish()
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
