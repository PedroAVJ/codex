import CryptoKit
import Foundation

public enum SecureBridgeProtocol {
    public static let version = 2
    public static let serviceType = "_codexvoice._tcp"
    public static let pairingURLScheme = "codexvoice"
    public static let pairingURLHost = "pair"
    public static let watchPairingContextKey = "codexVoicePairingV2"
    public static let watchPairingTransferIDContextKey = "codexVoicePairingTransferIDV2"
    public static let watchPairingAcknowledgementContextKey = "codexVoicePairingAcknowledgementV2"

    public static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public static func deriveKey(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKey: P256.KeyAgreement.PublicKey,
        salt: Data,
        context: String
    ) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(context.utf8),
            outputByteCount: 32
        )
    }

    public static func seal<T: Encodable>(_ value: T, using key: SymmetricKey) throws -> String {
        let plaintext = try JSONEncoder().encode(value)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw SecureBridgeError.missingSealedPayload }
        return combined.base64URLEncodedString()
    }

    public static func open<T: Decodable>(_ type: T.Type, from encoded: String, using key: SymmetricKey) throws -> T {
        guard let combined = Data(base64URLEncoded: encoded) else {
            throw SecureBridgeError.invalidBase64
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(type, from: plaintext)
    }

    public static func ticketDigest(_ ticket: String) -> String {
        Data(SHA256.hash(data: Data(ticket.utf8))).base64URLEncodedString()
    }

    public static func relayRoom(for key: Data) -> String {
        Data(SHA256.hash(data: key)).base64URLEncodedString()
    }
}

public struct PairingLink: Codable, Equatable, Sendable {
    public let version: Int
    public let serviceName: String
    public let ticket: String
    public let serverPublicKey: String
    public let expiresAt: Int
    public let relayURL: String
    public let relayRoom: String
    public let relayKey: String
    public let relayAuth: String

    public init(
        version: Int = SecureBridgeProtocol.version,
        serviceName: String,
        ticket: String,
        serverPublicKey: String,
        expiresAt: Int,
        relayURL: String,
        relayRoom: String,
        relayKey: String,
        relayAuth: String
    ) {
        self.version = version
        self.serviceName = serviceName
        self.ticket = ticket
        self.serverPublicKey = serverPublicKey
        self.expiresAt = expiresAt
        self.relayURL = relayURL
        self.relayRoom = relayRoom
        self.relayKey = relayKey
        self.relayAuth = relayAuth
    }

    public init(url: URL) throws {
        guard url.scheme?.lowercased() == SecureBridgeProtocol.pairingURLScheme,
              url.host?.lowercased() == SecureBridgeProtocol.pairingURLHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SecureBridgeError.invalidPairingURL
        }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, values[item.name] == nil else {
                throw SecureBridgeError.invalidPairingURL
            }
            values[item.name] = value
        }
        guard let version = values["v"].flatMap(Int.init),
              version == SecureBridgeProtocol.version,
              let serviceName = values["service"], !serviceName.isEmpty,
              let ticket = values["ticket"], Data(base64URLEncoded: ticket)?.count == 32,
              let serverPublicKey = values["server"],
              let rawServerKey = Data(base64URLEncoded: serverPublicKey),
              (try? P256.KeyAgreement.PublicKey(rawRepresentation: rawServerKey)) != nil,
              let expiresAt = values["expires"].flatMap(Int.init),
              let relayURL = values["relay"],
              let relayEndpoint = URL(string: relayURL),
              relayEndpoint.scheme?.lowercased() == "wss",
              relayEndpoint.host != nil,
              let relayRoom = values["room"],
              Data(base64URLEncoded: relayRoom)?.count == 32,
              let relayKey = values["key"],
              let rawRelayKey = Data(base64URLEncoded: relayKey),
              rawRelayKey.count == 32,
              SecureBridgeProtocol.relayRoom(for: rawRelayKey) == relayRoom,
              let relayAuth = values["auth"], !relayAuth.isEmpty else {
            throw SecureBridgeError.invalidPairingURL
        }
        guard expiresAt > Int(Date().timeIntervalSince1970) else {
            throw SecureBridgeError.expiredPairingURL
        }

        self.init(
            version: version,
            serviceName: serviceName,
            ticket: ticket,
            serverPublicKey: serverPublicKey,
            expiresAt: expiresAt,
            relayURL: relayURL,
            relayRoom: relayRoom,
            relayKey: relayKey,
            relayAuth: relayAuth
        )
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = SecureBridgeProtocol.pairingURLScheme
        components.host = SecureBridgeProtocol.pairingURLHost
        components.queryItems = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "service", value: serviceName),
            URLQueryItem(name: "ticket", value: ticket),
            URLQueryItem(name: "server", value: serverPublicKey),
            URLQueryItem(name: "expires", value: String(expiresAt)),
            URLQueryItem(name: "relay", value: relayURL),
            URLQueryItem(name: "room", value: relayRoom),
            URLQueryItem(name: "key", value: relayKey),
            URLQueryItem(name: "auth", value: relayAuth),
        ]
        return components.url!
    }
}

public struct PairingCredentials: Codable, Equatable, Sendable {
    public var clientID: String?
    public var clientPrivateKey: String
    public var serverPublicKey: String
    public var serviceName: String
    public var ticket: String?
    public var relayURL: String
    public var relayRoom: String
    public var relayKey: String
    public var relayAuth: String

    public init(pairingLink: PairingLink) {
        let privateKey = P256.KeyAgreement.PrivateKey()
        self.clientID = nil
        self.clientPrivateKey = privateKey.rawRepresentation.base64URLEncodedString()
        self.serverPublicKey = pairingLink.serverPublicKey
        self.serviceName = pairingLink.serviceName
        self.ticket = pairingLink.ticket
        self.relayURL = pairingLink.relayURL
        self.relayRoom = pairingLink.relayRoom
        self.relayKey = pairingLink.relayKey
        self.relayAuth = pairingLink.relayAuth
    }

    public var clientPrivateKeyValue: P256.KeyAgreement.PrivateKey? {
        guard let raw = Data(base64URLEncoded: clientPrivateKey) else { return nil }
        return try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    public var clientPublicKey: String? {
        clientPrivateKeyValue?.publicKey.rawRepresentation.base64URLEncodedString()
    }

    public var serverPublicKeyValue: P256.KeyAgreement.PublicKey? {
        guard let raw = Data(base64URLEncoded: serverPublicKey) else { return nil }
        return try? P256.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    public var relayKeyValue: SymmetricKey? {
        guard let data = Data(base64URLEncoded: relayKey), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    public mutating func complete(clientID: String, relayAuth: String) {
        self.clientID = clientID
        self.relayAuth = relayAuth
        ticket = nil
    }
}

public enum RelayRole: String, Codable, Sendable {
    case host
    case device
}

public struct RelayAccessClaims: Codable, Equatable, Sendable {
    public let version: Int
    public let room: String
    public let role: RelayRole
    public let clientID: String?
    public let expiresAt: Int

    public init(
        version: Int = 1,
        room: String,
        role: RelayRole,
        clientID: String? = nil,
        expiresAt: Int
    ) {
        self.version = version
        self.room = room
        self.role = role
        self.clientID = clientID
        self.expiresAt = expiresAt
    }
}

public enum RelayAccessToken {
    public static func issue(
        claims: RelayAccessClaims,
        serverPrivateKey: P256.KeyAgreement.PrivateKey
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(claims).base64URLEncodedString()
        let signingKey = try P256.Signing.PrivateKey(rawRepresentation: serverPrivateKey.rawRepresentation)
        let signature = try signingKey.signature(for: Data(payload.utf8))
        return payload + "." + signature.derRepresentation.base64URLEncodedString()
    }

    public static func verify(
        _ token: String,
        serverPublicKey: P256.KeyAgreement.PublicKey,
        now: Int = Int(Date().timeIntervalSince1970)
    ) throws -> RelayAccessClaims {
        do {
            let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  let payload = Data(base64URLEncoded: String(pieces[0])),
                  let signatureData = Data(base64URLEncoded: String(pieces[1])) else {
                throw SecureBridgeError.invalidRelayToken
            }
            let signingKey = try P256.Signing.PublicKey(rawRepresentation: serverPublicKey.rawRepresentation)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            guard signingKey.isValidSignature(signature, for: Data(pieces[0].utf8)) else {
                throw SecureBridgeError.invalidRelayToken
            }
            let claims = try JSONDecoder().decode(RelayAccessClaims.self, from: payload)
            guard claims.version == 1, claims.expiresAt > now else {
                throw SecureBridgeError.invalidRelayToken
            }
            return claims
        } catch {
            throw SecureBridgeError.invalidRelayToken
        }
    }
}

public struct RelayMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ready
        case frame
        case close
        case error
    }

    public var kind: Kind
    public var channel: String?
    public var payload: String?
    public var message: String?
    public var deliveryId: String?
    public var sequence: Int?

    public init(
        kind: Kind,
        channel: String? = nil,
        payload: String? = nil,
        message: String? = nil,
        deliveryId: String? = nil,
        sequence: Int? = nil
    ) {
        self.kind = kind
        self.channel = channel
        self.payload = payload
        self.message = message
        self.deliveryId = deliveryId
        self.sequence = sequence
    }
}

public struct BridgePacket: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hello
        case helloAck
        case sealed
        case error
    }

    public var kind: Kind
    public var version: Int
    public var clientID: String?
    public var clientPublicKey: String?
    public var clientNonce: String?
    public var ticket: String?
    public var data: String?
    public var message: String?
    public var deliveryId: String?
    public var sequence: Int?

    public init(
        kind: Kind,
        version: Int = SecureBridgeProtocol.version,
        clientID: String? = nil,
        clientPublicKey: String? = nil,
        clientNonce: String? = nil,
        ticket: String? = nil,
        data: String? = nil,
        message: String? = nil,
        deliveryId: String? = nil,
        sequence: Int? = nil
    ) {
        self.kind = kind
        self.version = version
        self.clientID = clientID
        self.clientPublicKey = clientPublicKey
        self.clientNonce = clientNonce
        self.ticket = ticket
        self.data = data
        self.message = message
        self.deliveryId = deliveryId
        self.sequence = sequence
    }
}

public struct HandshakeAcknowledgement: Codable, Equatable, Sendable {
    public let clientID: String
    public let serverNonce: String
    public let serverName: String
    public let isNewPairing: Bool

    public init(clientID: String, serverNonce: String, serverName: String, isNewPairing: Bool) {
        self.clientID = clientID
        self.serverNonce = serverNonce
        self.serverName = serverName
        self.isNewPairing = isNewPairing
    }
}

public enum SecureBridgeError: LocalizedError, Equatable {
    case invalidPairingURL
    case expiredPairingURL
    case invalidBase64
    case invalidKey
    case invalidHandshake
    case unauthorisedDevice
    case missingSealedPayload
    case invalidRelayToken

    public var errorDescription: String? {
        switch self {
        case .invalidPairingURL: "That is not a valid Pedro Voice Agent pairing QR code."
        case .expiredPairingURL: "That pairing QR code has expired. Generate a new one on the Mac."
        case .invalidBase64: "The secure bridge payload is invalid."
        case .invalidKey: "The secure bridge key is invalid."
        case .invalidHandshake: "The secure bridge handshake failed."
        case .unauthorisedDevice: "This device is not paired with the Mac."
        case .missingSealedPayload: "The secure bridge could not seal the payload."
        case .invalidRelayToken: "The remote relay authorisation is invalid or expired."
        }
    }
}

public extension Data {
    init?(base64URLEncoded string: String) {
        var value = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value.append(String(repeating: "=", count: 4 - remainder)) }
        self.init(base64Encoded: value)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
