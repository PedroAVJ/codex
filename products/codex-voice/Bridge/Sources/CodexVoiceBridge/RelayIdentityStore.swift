import CodexVoiceProtocol
import CryptoKit
import Foundation

struct RelayIdentity: Codable, Equatable {
    let url: String
    let key: String

    var keyData: Data? {
        guard let data = Data(base64URLEncoded: key), data.count == 32 else { return nil }
        return data
    }

    var room: String? {
        keyData.map(SecureBridgeProtocol.relayRoom(for:))
    }

    func accessToken(
        role: RelayRole,
        clientID: String? = nil,
        expiresAt: Int,
        serverPrivateKey: P256.KeyAgreement.PrivateKey
    ) throws -> String {
        guard let room else { throw RelayIdentityError.invalidIdentity }
        return try RelayAccessToken.issue(
            claims: RelayAccessClaims(
                room: room,
                role: role,
                clientID: clientID,
                expiresAt: expiresAt
            ),
            serverPrivateKey: serverPrivateKey
        )
    }
}

final class RelayIdentityStore {
    private let identityURL: URL
    private let fileManager: FileManager

    init(supportDirectory: URL, fileManager: FileManager = .default) {
        identityURL = supportDirectory.appendingPathComponent("relay-identity.json")
        self.fileManager = fileManager
    }

    func load() -> RelayIdentity? {
        guard let data = try? Data(contentsOf: identityURL),
              let identity = try? JSONDecoder().decode(RelayIdentity.self, from: data),
              identity.keyData != nil,
              let url = URL(string: identity.url),
              url.scheme?.lowercased() == "wss",
              url.host != nil else { return nil }
        return identity
    }

    func loadOrCreate(relayURL: String) throws -> RelayIdentity {
        guard let endpoint = URL(string: relayURL),
              endpoint.scheme?.lowercased() == "wss",
              endpoint.host != nil else { throw RelayIdentityError.invalidURL }

        let key = load()?.key
            ?? SecureBridgeProtocol.randomBytes(count: 32).base64URLEncodedString()
        let identity = RelayIdentity(url: endpoint.absoluteString, key: key)
        let data = try JSONEncoder().encode(identity)
        try data.write(to: identityURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
        return identity
    }
}

enum RelayIdentityError: LocalizedError {
    case invalidURL
    case invalidIdentity

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The Codex Voice relay URL must be a secure wss:// endpoint."
        case .invalidIdentity: "The Codex Voice relay identity is invalid."
        }
    }
}
