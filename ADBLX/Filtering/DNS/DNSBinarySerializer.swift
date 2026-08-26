import Foundation
import ADBLXShared

public enum DNSBinarySerializer {
    public enum SerializationError: Error, Equatable {
        case validationFailed(DNSArtifactValidationError)
        case emptyDomainList
    }
    
    /// Serializes an array of reversed-label domain strings into a binary C2 artifact.
    ///
    /// Ensures:
    /// - Deduplication of identical entries.
    /// - Strict unsigned byte-for-byte lexicographical sorting (`utf8.lexicographicallyPrecedes`).
    /// - Construction of 32-byte header with payload CRC32.
    /// - Post-serialization validation via `DNSArtifactValidator`.
    public static func serialize(reversedDomains: [String]) throws -> Data {
        // 1. Sort using exact unsigned byte-for-byte comparison
        var sorted = reversedDomains.sorted { a, b in
            a.utf8.lexicographicallyPrecedes(b.utf8)
        }
        
        // 2. Deduplicate in single sorted pass
        var unique: [String] = []
        unique.reserveCapacity(sorted.count)
        
        for item in sorted {
            if unique.last != item {
                unique.append(item)
            }
        }
        
        // 3. Build string blob & offsets table
        var stringBlob = Data()
        var offsets: [UInt32] = []
        offsets.reserveCapacity(unique.count)
        
        for domain in unique {
            offsets.append(UInt32(stringBlob.count))
            stringBlob.append(contentsOf: domain.utf8)
            stringBlob.append(0x00) // Null terminator
        }
        
        let ruleCount = UInt32(unique.count)
        let offsetsSize = ruleCount * 4
        let stringBlobSize = UInt32(stringBlob.count)
        
        // 4. Construct payload and compute CRC32
        var payload = Data(capacity: Int(offsetsSize + stringBlobSize))
        for offset in offsets {
            var o = offset.littleEndian
            withUnsafeBytes(of: &o) { payload.append(contentsOf: $0) }
        }
        payload.append(stringBlob)
        
        let crc = CRC32.checksum(data: payload)
        
        // 5. Construct 32-byte header
        let header = DNSArtifactHeader(
            ruleCount: ruleCount,
            stringBlobSize: stringBlobSize,
            payloadCRC32: crc
        )
        
        var fullData = header.serialize()
        fullData.append(payload)
        
        // 6. Immediate post-serialization validation
        do {
            _ = try DNSArtifactValidator.validate(data: fullData)
        } catch let err as DNSArtifactValidationError {
            throw SerializationError.validationFailed(err)
        }
        
        return fullData
    }
}
