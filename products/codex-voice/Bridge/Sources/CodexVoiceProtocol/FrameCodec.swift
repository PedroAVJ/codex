import Foundation

public enum FrameCodecError: Error, Equatable {
    case frameTooLarge(Int)
}

public struct FrameDecoder: Sendable {
    public static let maximumFrameBytes = 2 * 1024 * 1024
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= 4 {
            let length = Int(buffer[0]) << 24
                | Int(buffer[1]) << 16
                | Int(buffer[2]) << 8
                | Int(buffer[3])

            guard length <= Self.maximumFrameBytes else {
                throw FrameCodecError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }

            frames.append(buffer.subdata(in: 4..<(4 + length)))
            buffer.removeSubrange(0..<(4 + length))
        }

        return frames
    }
}

public enum FrameEncoder {
    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= FrameDecoder.maximumFrameBytes else {
            throw FrameCodecError.frameTooLarge(payload.count)
        }

        let length = UInt32(payload.count)
        var framed = Data(capacity: payload.count + 4)
        framed.append(UInt8((length >> 24) & 0xff))
        framed.append(UInt8((length >> 16) & 0xff))
        framed.append(UInt8((length >> 8) & 0xff))
        framed.append(UInt8(length & 0xff))
        framed.append(payload)
        return framed
    }
}

