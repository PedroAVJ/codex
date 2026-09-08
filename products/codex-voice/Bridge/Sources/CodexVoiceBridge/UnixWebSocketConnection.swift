import CryptoKit
import Darwin
import Foundation

/// A deliberately small RFC 6455 client for Codex's local Unix control socket.
/// The control socket rejects WebSocket extension negotiation, so this client
/// sends the exact extension-free upgrade that the app-server accepts.
final class UnixWebSocketConnection {
    private let socketPath: String
    private let queue: DispatchQueue
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var inputBuffer = Data()
    private var handshakeKey: String?
    private var handshakeComplete = false
    private var fragmentOpcode: UInt8?
    private var fragmentBuffer = Data()
    private var isClosed = false

    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(socketPath: String, queue: DispatchQueue) {
        self.socketPath = socketPath
        self.queue = queue
    }

    func connect() throws {
        guard descriptor == -1 else { return }

        let pathBytes = Array(socketPath.utf8CString)
        var address = sockaddr_un()
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixWebSocketError.socketPathTooLong
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixWebSocketError.systemCall("socket", errno) }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixWebSocketError.systemCall("connect", code)
        }

        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailableData() }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
        source.resume()

        let randomKey = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        handshakeKey = randomKey
        let request = """
        GET /rpc HTTP/1.1\r
        Host: localhost\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(randomKey)\r
        Sec-WebSocket-Version: 13\r
        \r

        """
        do {
            try writeAll(Data(request.utf8))
        } catch {
            finish(error)
            throw error
        }
    }

    func send(text: String) {
        guard handshakeComplete, !isClosed else { return }
        do {
            try sendFrame(opcode: 0x1, payload: Data(text.utf8))
        } catch {
            finish(error)
        }
    }

    func close() {
        guard !isClosed else { return }
        if handshakeComplete {
            try? sendFrame(opcode: 0x8, payload: Data())
        }
        finish(nil)
    }

    private func readAvailableData() {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            inputBuffer.append(contentsOf: bytes.prefix(count))
            do {
                if !handshakeComplete { try consumeHandshake() }
                if handshakeComplete { try consumeFrames() }
            } catch {
                finish(error)
            }
        } else if count == 0 {
            finish(UnixWebSocketError.connectionClosed)
        } else if errno != EINTR {
            finish(UnixWebSocketError.systemCall("read", errno))
        }
    }

    private func consumeHandshake() throws {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = inputBuffer.range(of: delimiter) else { return }
        let headerData = inputBuffer[..<range.lowerBound]
        inputBuffer.removeSubrange(..<range.upperBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw UnixWebSocketError.invalidHandshake
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard lines.first?.contains(" 101 ") == true else {
            throw UnixWebSocketError.upgradeRejected(lines.first ?? "invalid response")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard let key = handshakeKey,
              headers["upgrade"]?.lowercased() == "websocket",
              headers["sec-websocket-accept"] == Self.expectedAccept(for: key) else {
            throw UnixWebSocketError.invalidHandshake
        }

        handshakeComplete = true
        onOpen?()
    }

    private func consumeFrames() throws {
        while true {
            let bytes = [UInt8](inputBuffer)
            guard bytes.count >= 2 else { return }

            let first = bytes[0]
            let second = bytes[1]
            guard first & 0x70 == 0 else { throw UnixWebSocketError.unsupportedExtension }
            let isFinal = first & 0x80 != 0
            let opcode = first & 0x0f
            let isMasked = second & 0x80 != 0
            var payloadLength = UInt64(second & 0x7f)
            var cursor = 2

            if payloadLength == 126 {
                guard bytes.count >= cursor + 2 else { return }
                payloadLength = UInt64(bytes[cursor]) << 8 | UInt64(bytes[cursor + 1])
                cursor += 2
            } else if payloadLength == 127 {
                guard bytes.count >= cursor + 8 else { return }
                payloadLength = 0
                for byte in bytes[cursor..<(cursor + 8)] {
                    payloadLength = payloadLength << 8 | UInt64(byte)
                }
                cursor += 8
            }
            guard payloadLength <= UInt64(Int.max) else { throw UnixWebSocketError.frameTooLarge }

            var mask: ArraySlice<UInt8>?
            if isMasked {
                guard bytes.count >= cursor + 4 else { return }
                mask = bytes[cursor..<(cursor + 4)]
                cursor += 4
            }
            let length = Int(payloadLength)
            guard bytes.count >= cursor + length else { return }
            var payload = Array(bytes[cursor..<(cursor + length)])
            if let mask {
                let maskBytes = Array(mask)
                for index in payload.indices { payload[index] ^= maskBytes[index % 4] }
            }
            inputBuffer.removeFirst(cursor + length)
            try handleFrame(opcode: opcode, isFinal: isFinal, payload: Data(payload))
        }
    }

    private func handleFrame(opcode: UInt8, isFinal: Bool, payload: Data) throws {
        if opcode >= 0x8 {
            guard isFinal, payload.count <= 125 else { throw UnixWebSocketError.invalidControlFrame }
            switch opcode {
            case 0x8:
                try? sendFrame(opcode: 0x8, payload: payload)
                finish(nil)
            case 0x9:
                try sendFrame(opcode: 0xA, payload: payload)
            case 0xA:
                break
            default:
                throw UnixWebSocketError.unsupportedOpcode(opcode)
            }
            return
        }

        switch opcode {
        case 0x1:
            guard fragmentOpcode == nil else { throw UnixWebSocketError.invalidFragment }
            if isFinal {
                try deliverText(payload)
            } else {
                fragmentOpcode = opcode
                fragmentBuffer = payload
            }
        case 0x0:
            guard fragmentOpcode == 0x1 else { throw UnixWebSocketError.invalidFragment }
            fragmentBuffer.append(payload)
            if isFinal {
                let complete = fragmentBuffer
                fragmentBuffer.removeAll(keepingCapacity: false)
                fragmentOpcode = nil
                try deliverText(complete)
            }
        default:
            throw UnixWebSocketError.unsupportedOpcode(opcode)
        }
    }

    private func deliverText(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw UnixWebSocketError.invalidUTF8
        }
        onText?(text)
    }

    private func sendFrame(opcode: UInt8, payload: Data) throws {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count <= 125 {
            frame.append(0x80 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(UInt8((count >> 8) & 0xff))
            frame.append(UInt8(count & 0xff))
        } else {
            frame.append(0x80 | 127)
            let value = UInt64(count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((value >> UInt64(shift)) & 0xff))
            }
        }

        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame.append(contentsOf: mask)
        var masked = [UInt8](payload)
        for index in masked.indices { masked[index] ^= mask[index % 4] }
        frame.append(contentsOf: masked)
        try writeAll(frame)
    }

    private func writeAll(_ data: Data) throws {
        guard descriptor >= 0 else { throw UnixWebSocketError.connectionClosed }
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written > 0 {
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw UnixWebSocketError.systemCall("write", errno)
                }
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        handshakeComplete = false
        if let source = readSource {
            readSource = nil
            descriptor = -1
            source.cancel()
        } else if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        onClose?(error)
    }

    private static func expectedAccept(for key: String) -> String {
        let value = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        return Data(Insecure.SHA1.hash(data: value)).base64EncodedString()
    }
}

enum UnixWebSocketError: LocalizedError {
    case socketPathTooLong
    case systemCall(String, Int32)
    case connectionClosed
    case invalidHandshake
    case upgradeRejected(String)
    case unsupportedExtension
    case frameTooLarge
    case invalidControlFrame
    case invalidFragment
    case unsupportedOpcode(UInt8)
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong: "Codex control socket path is too long"
        case .systemCall(let operation, let code):
            "Codex control socket \(operation) failed (\(code))"
        case .connectionClosed: "Codex control socket closed"
        case .invalidHandshake: "Codex control socket returned an invalid WebSocket handshake"
        case .upgradeRejected(let status): "Codex control socket rejected WebSocket upgrade: \(status)"
        case .unsupportedExtension: "Codex control socket used an unsupported WebSocket extension"
        case .frameTooLarge: "Codex control socket sent an oversized frame"
        case .invalidControlFrame: "Codex control socket sent an invalid control frame"
        case .invalidFragment: "Codex control socket sent an invalid fragmented message"
        case .unsupportedOpcode(let opcode): "Codex control socket sent unsupported opcode \(opcode)"
        case .invalidUTF8: "Codex control socket sent invalid text"
        }
    }
}
