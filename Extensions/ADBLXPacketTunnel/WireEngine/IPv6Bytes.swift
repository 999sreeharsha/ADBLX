import Foundation

/// An IPv6 address held as two big-endian numbers (`DNSPacketParser` reads it that way) back to
/// the 16 bytes that go on the wire. Reading the tuple's memory instead gives each half's bytes
/// in the host's (little-endian) order, which reversed every address we wrote.
public enum IPv6Bytes {
    public static func make(_ address: (UInt64, UInt64)) -> [UInt8] {
        (0..<8).map { UInt8((address.0 >> UInt64(56 - 8 * $0)) & 0xFF) }
            + (0..<8).map { UInt8((address.1 >> UInt64(56 - 8 * $0)) & 0xFF) }
    }
}
