internal import Expo
import React
import ReactAppDependencyProvider
import UIKit

@main
@MainActor
final class AppDelegate: ExpoAppDelegate {
    var window: UIWindow?

    private var reactNativeDelegate: ExpoReactNativeFactoryDelegate?
    private var reactNativeFactory: RCTReactNativeFactory?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        // Start the existing encrypted pairing engine before JavaScript asks
        // for its first snapshot. Credential values never cross this bridge.
        _ = CodexVoiceCoordinator.shared
        if let incomingURL = launchOptions?[.url] as? URL {
            CodexVoiceCoordinator.shared.open(incomingURL)
        }

        let delegate = CodexVoiceReactNativeDelegate()
        let factory = ExpoReactNativeFactory(delegate: delegate)
        delegate.dependencyProvider = RCTAppDependencyProvider()
        reactNativeDelegate = delegate
        reactNativeFactory = factory

        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        factory.startReactNative(
            withModuleName: "main",
            in: window,
            launchOptions: launchOptions
        )

        return super.application(
            application,
            didFinishLaunchingWithOptions: launchOptions
        )
    }

    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        CodexVoiceCoordinator.shared.open(url)
        return super.application(app, open: url, options: options)
            || RCTLinkingManager.application(app, open: url, options: options)
    }

    override func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        let linked = RCTLinkingManager.application(
            application,
            continue: userActivity,
            restorationHandler: restorationHandler
        )
        return super.application(
            application,
            continue: userActivity,
            restorationHandler: restorationHandler
        ) || linked
    }
}

private final class CodexVoiceReactNativeDelegate: ExpoReactNativeFactoryDelegate {
    override func sourceURL(for bridge: RCTBridge) -> URL? {
        bridge.bundleURL ?? bundleURL()
    }

    override func bundleURL() -> URL? {
#if DEBUG
        RCTBundleURLProvider.sharedSettings().jsBundleURL(
            forBundleRoot: ".expo/.virtual-metro-entry"
        )
#else
        Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
    }
}
