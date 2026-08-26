import Foundation

public enum CRC32 {
    private static let table: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            return c
        }
    }()

    public static func checksum(bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    public static func checksum(data: Data) -> UInt32 {
        data.withUnsafeBytes { ptr in
            checksum(bytes: ptr)
        }
    }
}
