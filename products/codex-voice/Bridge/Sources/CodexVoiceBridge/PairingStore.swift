import CodexVoiceProtocol
import CryptoKit
import Foundation

struct PairedDevice: Codable, Equatable {
    let id: String
    let publicKey: String
    let name: String
    let pairedAt: Int
}

struct PairingStoreStatus: Codable {
    let pairedDeviceCount: Int
    let pendingPairingExpiresAt: Int?
    let serverKeyReady: Bool
}

final class PairingStore {
    private struct PendingTicket: Codable {
        let digest: String
        let expiresAt: Int
    }

    private struct State: Codable {
        var devices: [PairedDevice] = []
        var pendingTicket: PendingTicket?
    }

    let supportDirectory: URL
    private let stateURL: URL
    private let serverKeyURL: URL
    private let fileManager: FileManager

    init(supportDirectory: URL, fileManager: FileManager = .default) throws {
        self.supportDirectory = supportDirectory
        self.fileManager = fileManager
        stateURL = supportDirectory.appendingPathComponent("pairing-state.json")
        serverKeyURL = supportDirectory.appendingPathComponent("server-key.bin")
        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
    }

    func serverPrivateKey() throws -> P256.KeyAgreement.PrivateKey {
        if let data = try? Data(contentsOf: serverKeyURL),
           let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }

        let key = P256.KeyAgreement.PrivateKey()
        try writeSecurely(key.rawRepresentation, to: serverKeyURL)
        return key
    }

    func createPairingLink(
        serviceName: String,
        relayIdentity: RelayIdentity,
        lifetime: TimeInterval = 600
    ) throws -> PairingLink {
        let ticket = SecureBridgeProtocol.randomBytes(count: 32).base64URLEncodedString()
        let expiresAt = Int(Date().addingTimeInterval(lifetime).timeIntervalSince1970)
        var state = loadState()
        state.pendingTicket = PendingTicket(
            digest: SecureBridgeProtocol.ticketDigest(ticket),
            expiresAt: expiresAt
        )
        try save(state)
        let server = try serverPrivateKey()
        guard let room = relayIdentity.room else { throw RelayIdentityError.invalidIdentity }
        return PairingLink(
            serviceName: serviceName,
            ticket: ticket,
            serverPublicKey: server.publicKey.rawRepresentation.base64URLEncodedString(),
            expiresAt: expiresAt,
            relayURL: relayIdentity.url,
            relayRoom: room,
            relayKey: relayIdentity.key,
            relayAuth: try relayIdentity.accessToken(
                role: .device,
                expiresAt: expiresAt,
                serverPrivateKey: server
            )
        )
    }

    func hasValidTicket(_ ticket: String) -> Bool {
        let state = loadState()
        guard let pending = state.pendingTicket,
              pending.expiresAt > Int(Date().timeIntervalSince1970) else { return false }
        return pending.digest == SecureBridgeProtocol.ticketDigest(ticket)
    }

    func consumeTicket(
        _ ticket: String,
        clientID: String,
        publicKey: String,
        deviceName: String
    ) throws {
        var state = loadState()
        guard let pending = state.pendingTicket,
              pending.expiresAt > Int(Date().timeIntervalSince1970),
              pending.digest == SecureBridgeProtocol.ticketDigest(ticket) else {
            throw SecureBridgeError.unauthorisedDevice
        }
        state.pendingTicket = nil
        state.devices.removeAll { $0.id == clientID }
        state.devices.append(PairedDevice(
            id: clientID,
            publicKey: publicKey,
            name: String(deviceName.prefix(80)),
            pairedAt: Int(Date().timeIntervalSince1970)
        ))
        try save(state)
    }

    func device(id: String) -> PairedDevice? {
        loadState().devices.first { $0.id == id }
    }

    @discardableResult
    func revokeDevice(id: String) throws -> Bool {
        var state = loadState()
        let previousCount = state.devices.count
        state.devices.removeAll { $0.id == id }
        guard state.devices.count != previousCount else { return false }
        try save(state)
        return true
    }

    func revokeAllDevices() throws {
        var state = loadState()
        state.devices.removeAll()
        state.pendingTicket = nil
        try save(state)
    }

    func status() -> PairingStoreStatus {
        let state = loadState()
        let expiry = state.pendingTicket.flatMap {
            $0.expiresAt > Int(Date().timeIntervalSince1970) ? $0.expiresAt : nil
        }
        return PairingStoreStatus(
            pairedDeviceCount: state.devices.count,
            pendingPairingExpiresAt: expiry,
            serverKeyReady: fileManager.fileExists(atPath: serverKeyURL.path)
        )
    }

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private func save(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        try writeSecurely(data, to: stateURL)
    }

    private func writeSecurely(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
