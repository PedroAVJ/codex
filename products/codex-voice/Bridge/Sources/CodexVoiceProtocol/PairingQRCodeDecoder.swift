#if os(iOS) || os(macOS)
import Foundation
import Vision

public enum PairingQRCodeDecoder {
    public static func decode(_ imageData: Data) throws -> PairingLink {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(data: imageData).perform([request])

        var pairingError: Error?
        for observation in request.results ?? [] {
            guard let payload = observation.payloadStringValue,
                  let url = URL(string: payload),
                  url.scheme?.lowercased() == SecureBridgeProtocol.pairingURLScheme,
                  url.host?.lowercased() == SecureBridgeProtocol.pairingURLHost else {
                continue
            }

            do {
                return try PairingLink(url: url)
            } catch {
                pairingError = error
            }
        }

        if let pairingError {
            throw pairingError
        }
        throw PairingQRCodeError.notFound
    }
}

public enum PairingQRCodeError: LocalizedError {
    case notFound
    case unreadableImage

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "That image does not contain a valid Voice Relay pairing QR."
        case .unreadableImage:
            "Voice Relay could not read that shared image."
        }
    }
}
#endif
