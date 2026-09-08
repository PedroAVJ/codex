import CodexVoiceProtocol
import Foundation

protocol PacketConnection: AnyObject {
    var onPacket: ((BridgePacket) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }

    func start()
    func send(_ packet: BridgePacket)
    func close()
}

final class RelayPacketConnection: PacketConnection {
    let channel: String
    var onPacket: ((BridgePacket) -> Void)?
    var onClose: (() -> Void)?

    private let sendPacket: (String, BridgePacket) -> Void
    private let closeChannel: (String) -> Void
    private var didClose = false

    init(
        channel: String,
        sendPacket: @escaping (String, BridgePacket) -> Void,
        closeChannel: @escaping (String) -> Void
    ) {
        self.channel = channel
        self.sendPacket = sendPacket
        self.closeChannel = closeChannel
    }

    func start() {}

    func send(_ packet: BridgePacket) {
        guard !didClose else { return }
        sendPacket(channel, packet)
    }

    func receive(_ packet: BridgePacket) {
        guard !didClose else { return }
        onPacket?(packet)
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        closeChannel(channel)
        onClose?()
    }

    func remoteClosed() {
        guard !didClose else { return }
        didClose = true
        onClose?()
    }
}
