import AppKit
import CodexVoiceProtocol
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum BridgeCommand {
    static func runIfRequested(arguments: [String]) throws -> Bool {
        guard arguments.count > 1 else { return false }
        switch arguments[1] {
        case "pair":
            try createPairingQR(arguments: Array(arguments.dropFirst(2)))
            return true
        case "configure-openrouter-key", "configure-api-key":
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let value = String(data: data, encoding: .utf8) else {
                throw OpenRouterAPIKeyStoreError.invalidKey
            }
            try OpenRouterAPIKeyStore.save(value)
            print("OpenRouter API key saved in the login Keychain.")
            return true
        case "status":
            try printStatus(arguments: Array(arguments.dropFirst(2)))
            return true
        case "check-openrouter":
            try printOpenRouterStatus()
            return true
        case "revoke-devices":
            let store = try PairingStore(supportDirectory: supportDirectory(from: Array(arguments.dropFirst(2))))
            try store.revokeAllDevices()
            print("All Codex Voice device identities were revoked.")
            return true
        case "revoke-device":
            let commandArguments = Array(arguments.dropFirst(2))
            guard let clientID = value(after: "--client-id", in: commandArguments),
                  !clientID.isEmpty else {
                throw BridgeCommandError.clientIDRequired
            }
            let store = try PairingStore(supportDirectory: supportDirectory(from: commandArguments))
            guard try store.revokeDevice(id: clientID) else {
                throw BridgeCommandError.deviceNotFound
            }
            print("Codex Voice device identity revoked.")
            return true
        default:
            return false
        }
    }

    private static func createPairingQR(arguments: [String]) throws {
        let supportDirectory = supportDirectory(from: arguments)
        let output = value(after: "--output", in: arguments).map(URL.init(fileURLWithPath:))
            ?? supportDirectory.appendingPathComponent("pairing-qr.png")
        let linkOutput = value(after: "--link-output", in: arguments).map(URL.init(fileURLWithPath:))
        let serviceName = value(after: "--service-name", in: arguments)
            ?? "\(Host.current().localizedName ?? "Mac") Voice Relay"
        let store = try PairingStore(supportDirectory: supportDirectory)
        let relayStore = RelayIdentityStore(supportDirectory: supportDirectory)
        let relayIdentity: RelayIdentity
        if let relayURL = value(after: "--relay-url", in: arguments) {
            relayIdentity = try relayStore.loadOrCreate(relayURL: relayURL)
        } else if let existing = relayStore.load() {
            relayIdentity = existing
        } else {
            throw BridgeCommandError.relayNotConfigured
        }
        let link = try store.createPairingLink(
            serviceName: serviceName,
            relayIdentity: relayIdentity
        )
        try renderQRCode(value: link.url.absoluteString, to: output)
        if let linkOutput {
            try writePrivate(Data(link.url.absoluteString.utf8), to: linkOutput)
        }
        print("Pairing QR created: \(output.path)")
        print("Expires: \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(link.expiresAt))))")
    }

    private static func printStatus(arguments: [String]) throws {
        let store = try PairingStore(supportDirectory: supportDirectory(from: arguments))
        let server = try store.serverPrivateKey()
        let status = store.status()
        let relayIdentity = RelayIdentityStore(supportDirectory: store.supportDirectory).load()
        let relayStateURL = store.supportDirectory.appendingPathComponent("relay-state.json")
        let relayState = (try? Data(contentsOf: relayStateURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var object: [String: Any] = [
            "apiKeyConfigured": OpenRouterAPIKeyStore.load() != nil,
            "openRouterAPIKeyConfigured": OpenRouterAPIKeyStore.load() != nil,
            "voiceProvider": "openrouter",
            "pairedDeviceCount": status.pairedDeviceCount,
            "relayConfigured": relayIdentity != nil,
            "relayConnected": relayState?["connected"] as? Bool ?? false,
            "relayStatusMessage": relayState?["message"] as? String ?? "Not connected",
            "relayStateUpdatedAt": relayState?["updatedAt"] as? Int ?? 0,
            "serverPublicKey": server.publicKey.rawRepresentation.base64URLEncodedString(),
            "serverKeyReady": status.serverKeyReady,
        ]
        object["pendingPairingExpiresAt"] = status.pendingPairingExpiresAt ?? NSNull()
        object["relayURL"] = relayIdentity?.url ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func printOpenRouterStatus() throws {
        guard let apiKey = OpenRouterAPIKeyStore.load() else {
            throw BridgeCommandError.openRouterNotConfigured
        }
        let object = try OpenRouterAccountStatus.fetch(apiKey: apiKey)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func renderQRCode(value: String, to output: URL) throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)) else {
            throw BridgeCommandError.qrGenerationFailed
        }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw BridgeCommandError.qrGenerationFailed
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw BridgeCommandError.qrGenerationFailed
        }
        try writePrivate(png, to: output)
    }

    private static func writePrivate(_ data: Data, to output: URL) throws {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }

    private static func supportDirectory(from arguments: [String]) -> URL {
        if let override = value(after: "--support-dir", in: arguments) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexVoice", isDirectory: true)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

enum BridgeCommandError: LocalizedError {
    case qrGenerationFailed
    case relayNotConfigured
    case openRouterNotConfigured
    case clientIDRequired
    case deviceNotFound

    var errorDescription: String? {
        switch self {
        case .qrGenerationFailed: "The pairing QR code could not be generated."
        case .relayNotConfigured: "The remote relay is not configured. Reinstall Codex Voice with --relay-url."
        case .openRouterNotConfigured: "OpenRouter is not configured. Run configure-openrouter-key first."
        case .clientIDRequired: "revoke-device requires --client-id."
        case .deviceNotFound: "The requested Codex Voice device identity was not found."
        }
    }
}
