import Foundation

enum GeminiWebSocketProtocolError: Error, LocalizedError {
    case invalidFrame
    case messageTooLarge
    case upgradeHeaderTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidFrame:
            "Gemini sent an invalid realtime frame"
        case .messageTooLarge:
            "Gemini sent an oversized realtime message"
        case .upgradeHeaderTooLarge:
            "Gemini sent an oversized upgrade response"
        }
    }
}

struct GeminiRealtimeUpgradeHeaderAccumulator {
    struct Result: Sendable {
        let header: Data
        let remainder: Data
    }

    static let maximumHeaderBytes = 16 * 1_024

    private static let separator = Data("\r\n\r\n".utf8)
    private var buffer = Data()

    var remainingCapacity: Int {
        max(0, Self.maximumHeaderBytes - buffer.count)
    }

    mutating func append(_ chunk: Data) throws -> Result? {
        guard chunk.count <= remainingCapacity else {
            throw GeminiWebSocketProtocolError.upgradeHeaderTooLarge
        }
        buffer.append(chunk)

        if let range = buffer.range(of: Self.separator) {
            let header = Data(buffer.prefix(upTo: range.lowerBound))
            let remainder = Data(buffer.suffix(from: range.upperBound))
            return Result(header: header, remainder: remainder)
        }

        guard buffer.count < Self.maximumHeaderBytes else {
            throw GeminiWebSocketProtocolError.upgradeHeaderTooLarge
        }
        return nil
    }
}

struct GeminiWebSocketFrameHeader: Sendable {
    static let maximumPayloadBytes = 8 * 1_024 * 1_024

    let isFinal: Bool
    let opcode: UInt8
    let headerBytes: Int
    let payloadBytes: Int

    var totalFrameBytes: Int {
        headerBytes + payloadBytes
    }

    static func parse(from data: Data) throws -> GeminiWebSocketFrameHeader? {
        guard data.count >= 2 else { return nil }

        let firstByte = data[0]
        let secondByte = data[1]
        let isFinal = (firstByte & 0x80) != 0
        let opcode = firstByte & 0x0F
        let lengthMarker = secondByte & 0x7F

        guard (firstByte & 0x70) == 0,
              (secondByte & 0x80) == 0,
              [0x00, 0x01, 0x02, 0x08, 0x09, 0x0A].contains(opcode) else {
            throw GeminiWebSocketProtocolError.invalidFrame
        }

        let isControlFrame = (opcode & 0x08) != 0
        if isControlFrame {
            guard isFinal, lengthMarker <= 125 else {
                throw GeminiWebSocketProtocolError.invalidFrame
            }
        }

        let headerBytes: Int
        let payloadLength: UInt64
        switch lengthMarker {
        case 126:
            headerBytes = 4
            guard data.count >= headerBytes else { return nil }
            payloadLength = UInt64(data[2]) << 8 | UInt64(data[3])
            guard payloadLength >= 126 else {
                throw GeminiWebSocketProtocolError.invalidFrame
            }
        case 127:
            headerBytes = 10
            guard data.count >= headerBytes else { return nil }
            guard (data[2] & 0x80) == 0 else {
                throw GeminiWebSocketProtocolError.invalidFrame
            }
            var extendedLength: UInt64 = 0
            for index in 2..<10 {
                extendedLength = (extendedLength << 8) | UInt64(data[index])
            }
            payloadLength = extendedLength
            guard payloadLength > UInt64(UInt16.max) else {
                throw GeminiWebSocketProtocolError.invalidFrame
            }
        default:
            headerBytes = 2
            payloadLength = UInt64(lengthMarker)
        }

        guard payloadLength <= UInt64(Self.maximumPayloadBytes) else {
            throw GeminiWebSocketProtocolError.messageTooLarge
        }
        guard payloadLength <= UInt64(Int.max - headerBytes) else {
            throw GeminiWebSocketProtocolError.messageTooLarge
        }
        if opcode == 0x08, payloadLength == 1 {
            throw GeminiWebSocketProtocolError.invalidFrame
        }

        return GeminiWebSocketFrameHeader(
            isFinal: isFinal,
            opcode: opcode,
            headerBytes: headerBytes,
            payloadBytes: Int(payloadLength)
        )
    }
}
