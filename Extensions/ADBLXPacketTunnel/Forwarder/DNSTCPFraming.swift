import Foundation

/// DNS over TCP (RFC 1035 section 4.2.2): each message is preceded by its length in two bytes.
public enum DNSTCPFraming {
    public static func frame(_ message: Data) -> Data {
        var out = Data(capacity: message.count + 2)
        out.append(UInt8((message.count >> 8) & 0xFF))
        out.append(UInt8(message.count & 0xFF))
        out.append(message)
        return out
    }
}

/// Reassembles messages from a TCP byte stream, which may split or join them anywhere.
public struct DNSTCPFrameReader {
    private var bytes: [UInt8] = []

    public init() {}

    /// The messages now complete, in order. Nil if the stream is broken (a zero-length message).
    public mutating func append(_ data: Data) -> [Data]? {
        bytes.append(contentsOf: data)
        var messages: [Data] = []
        while bytes.count >= 2 {
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            if length == 0 { return nil }
            guard bytes.count >= 2 + length else { break }
            messages.append(Data(bytes[2..<(2 + length)]))
            bytes.removeFirst(2 + length)
        }
        return messages
    }
}
