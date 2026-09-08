import CodexVoiceProtocol
import Foundation
import Testing
@testable import CodexVoiceBridge

@Test func pairingStoreRevokesOnlyTheRequestedDevice() throws {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/pairing-store-tests/\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try PairingStore(supportDirectory: directory)
    let relayIdentity = try RelayIdentityStore(supportDirectory: directory)
        .loadOrCreate(relayURL: "wss://relay.example.test/api/relay")

    func pair(id: String, name: String) throws {
        let link = try store.createPairingLink(serviceName: "Test bridge", relayIdentity: relayIdentity)
        try store.consumeTicket(
            link.ticket,
            clientID: id,
            publicKey: "public-key-\(id)",
            deviceName: name
        )
    }

    try pair(id: "watch", name: "Example Watch")
    try pair(id: "probe", name: "Bridge integration probe")

    #expect(try store.revokeDevice(id: "probe"))
    #expect(store.device(id: "probe") == nil)
    #expect(store.device(id: "watch")?.name == "Example Watch")
    #expect(try !store.revokeDevice(id: "missing"))
}
