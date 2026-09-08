// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexVoice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "codex-voice-bridge", targets: ["CodexVoiceBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.24.0"),
    ],
    targets: [
        .target(
            name: "CodexVoiceProtocol",
            path: "Bridge/Sources/CodexVoiceProtocol"
        ),
        .executableTarget(
            name: "CodexVoiceBridge",
            dependencies: [
                "CodexVoiceProtocol",
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Bridge/Sources/CodexVoiceBridge",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "CodexVoiceProtocolTests",
            dependencies: ["CodexVoiceProtocol"],
            path: "Bridge/Tests/CodexVoiceProtocolTests"
        ),
        .testTarget(
            name: "CodexVoiceBridgeTests",
            dependencies: ["CodexVoiceBridge", "CodexVoiceProtocol"],
            path: "Bridge/Tests/CodexVoiceBridgeTests"
        ),
    ]
)
