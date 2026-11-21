import Foundation
import CryptoKit

enum WebSocketOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

struct WebSocketMessage {
    let opcode: WebSocketOpcode
    let payload: Data

    var text: String? {
        String(data: payload, encoding: .utf8)
    }
}

final class WebSocketParser {
    private var buffer = Data()
    private var fragmentedOpcode: WebSocketOpcode?
    private var fragmentedPayload = Data()
    private let maximumMessageSize = 512 * 1024

    func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete data/control message, or nil when more bytes
    /// are needed. Client-to-server frames must be masked.
    func nextMessage() -> WebSocketMessage? {
        while true {
            guard buffer.count >= 2 else { return nil }
            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.startIndex + 1]
            let fin = (b0 & 0x80) != 0
            let rsv = b0 & 0x70
            guard rsv == 0 else {
                buffer.removeAll()
                return nil
            }
            guard let opcode = WebSocketOpcode(rawValue: b0 & 0x0F) else {
                buffer.removeAll()
                return nil
            }
            let masked = (b1 & 0x80) != 0
            guard masked else {
                buffer.removeAll()
                return nil
            }

            var length = UInt64(b1 & 0x7F)
            var offset = 2
            if length == 126 {
                guard buffer.count >= 4 else { return nil }
                length = UInt64(buffer[buffer.startIndex + 2]) << 8
                    | UInt64(buffer[buffer.startIndex + 3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return nil }
                length = 0
                for index in 0..<8 {
                    length = (length << 8) | UInt64(buffer[buffer.startIndex + 2 + index])
                }
                offset = 10
            }

            let isControl = opcode.rawValue >= 0x8
            if isControl {
                guard fin, length <= 125 else {
                    buffer.removeAll()
                    return nil
                }
            }
            guard length <= UInt64(maximumMessageSize) else {
                buffer.removeAll()
                return nil
            }
            guard buffer.count >= offset + 4 + Int(length) else { return nil }

            let maskStart = buffer.startIndex + offset
            let mask = [UInt8](buffer[maskStart..<maskStart + 4])
            let payloadStart = maskStart + 4
            var payload = Data(buffer[payloadStart..<payloadStart + Int(length)])
            for index in payload.indices {
                payload[index] ^= mask[(index - payload.startIndex) % 4]
            }
            buffer.removeFirst(offset + 4 + Int(length))

            if isControl {
                return WebSocketMessage(opcode: opcode, payload: payload)
            }

            if opcode == .continuation {
                guard let original = fragmentedOpcode else {
                    buffer.removeAll()
                    return nil
                }
                fragmentedPayload.append(payload)
                guard fragmentedPayload.count <= maximumMessageSize else {
                    buffer.removeAll()
                    return nil
                }
                if fin {
                    let message = WebSocketMessage(opcode: original, payload: fragmentedPayload)
                    fragmentedOpcode = nil
                    fragmentedPayload = Data()
                    return message
                }
                continue
            }

            if fin {
                return WebSocketMessage(opcode: opcode, payload: payload)
            }
            fragmentedOpcode = opcode
            fragmentedPayload = payload
        }
    }
}

enum WebSocketCodec {
    static func acceptValue(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    static func frame(opcode: WebSocketOpcode, payload: Data) -> Data {
        var data = Data()
        data.append(0x80 | opcode.rawValue)
        let count = payload.count
        if count < 126 {
            data.append(UInt8(count))
        } else if count <= 65_535 {
            data.append(126)
            data.append(UInt8((count >> 8) & 0xFF))
            data.append(UInt8(count & 0xFF))
        } else {
            data.append(127)
            var length = UInt64(count)
            for _ in 0..<8 {
                data.append(UInt8((length >> 56) & 0xFF))
                length <<= 8
            }
        }
        data.append(payload)
        return data
    }

    static func text(_ string: String) -> Data {
        frame(opcode: .text, payload: Data(string.utf8))
    }

    static func close(code: UInt16, reason: String) -> Data {
        var payload = Data([UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)])
        payload.append(Data(reason.utf8.prefix(120)))
        return frame(opcode: .close, payload: payload)
    }
}
