import Foundation

public enum DNSArtifactValidationError: Error, Equatable, CustomStringConvertible {
    case fileTooSmall(actual: Int, minimum: Int)
    case fileTooLarge(actual: Int, maximum: Int)
    case invalidMagic(actual: UInt32, expected: UInt32)
    case unsupportedVersion(actual: UInt32, expected: UInt32)
    case ruleCountExceedsLimit(actual: UInt32, maximum: UInt32)
    case offsetsTableSizeMismatch(actual: UInt32, expected: UInt32)
    case fileLengthMismatch(actual: Int, expected: Int)
    case crc32Mismatch(actual: UInt32, expected: UInt32)
    case offsetOutOfBounds(index: Int, offset: UInt32, blobSize: UInt32)
    case stringNotTerminated(index: Int, offset: UInt32)
    case invalidStringOrdering(index: Int, previous: String, current: String)
    case duplicateEntry(index: Int, domain: String)
    
    public var description: String {
        switch self {
        case .fileTooSmall(let actual, let minimum):
            return "Artifact size (\(actual) bytes) is smaller than minimum required header size (\(minimum) bytes)."
        case .fileTooLarge(let actual, let maximum):
            return "Artifact size (\(actual) bytes) exceeds maximum allowable safety limit (\(maximum) bytes)."
        case .invalidMagic(let actual, let expected):
            return "Invalid artifact magic identifier: 0x\(String(actual, radix: 16)) (expected 0x\(String(expected, radix: 16)))."
        case .unsupportedVersion(let actual, let expected):
            return "Unsupported artifact version: \(actual) (expected \(expected))."
        case .ruleCountExceedsLimit(let actual, let maximum):
            return "Artifact rule count (\(actual)) exceeds maximum allowable limit (\(maximum))."
        case .offsetsTableSizeMismatch(let actual, let expected):
            return "Offsets table size (\(actual) bytes) does not equal ruleCount * 4 (\(expected) bytes)."
        case .fileLengthMismatch(let actual, let expected):
            return "Actual file size (\(actual) bytes) does not match total header calculation (\(expected) bytes)."
        case .crc32Mismatch(let actual, let expected):
            return "Payload CRC32 mismatch: computed 0x\(String(actual, radix: 16)), header specifies 0x\(String(expected, radix: 16))."
        case .offsetOutOfBounds(let index, let offset, let blobSize):
            return "Offset at index [\(index)] is \(offset), which is out of bounds for string blob size \(blobSize)."
        case .stringNotTerminated(let index, let offset):
            return "String at index [\(index)] (offset \(offset)) is not null-terminated before end of blob."
        case .invalidStringOrdering(let index, let previous, let current):
            return "Strings at index [\(index-1)] and [\(index)] violate strict lexicographical byte-ordering: '\(previous)' >= '\(current)'."
        case .duplicateEntry(let index, let domain):
            return "Duplicate domain detected at index [\(index)]: '\(domain)'."
        }
    }
}

public enum DNSArtifactValidator {
    /// Validates raw binary data against the full structural and integrity contract.
    public static func validate(data: Data) throws -> DNSArtifactHeader {
        guard data.count >= DNSArtifactFormat.headerSize else {
            throw DNSArtifactValidationError.fileTooSmall(actual: data.count, minimum: DNSArtifactFormat.headerSize)
        }
        
        guard data.count <= DNSArtifactFormat.maxArtifactSizeBytes else {
            throw DNSArtifactValidationError.fileTooLarge(actual: data.count, maximum: DNSArtifactFormat.maxArtifactSizeBytes)
        }
        
        guard let header = DNSArtifactHeader.deserialize(from: data) else {
            throw DNSArtifactValidationError.fileTooSmall(actual: data.count, minimum: DNSArtifactFormat.headerSize)
        }
        
        guard header.magic == DNSArtifactFormat.magicUInt32 else {
            throw DNSArtifactValidationError.invalidMagic(actual: header.magic, expected: DNSArtifactFormat.magicUInt32)
        }
        
        guard header.version == DNSArtifactFormat.currentVersion else {
            throw DNSArtifactValidationError.unsupportedVersion(actual: header.version, expected: DNSArtifactFormat.currentVersion)
        }
        
        guard header.ruleCount <= DNSArtifactFormat.maxRuleCount else {
            throw DNSArtifactValidationError.ruleCountExceedsLimit(actual: header.ruleCount, maximum: DNSArtifactFormat.maxRuleCount)
        }
        
        guard header.offsetsTableSize == header.ruleCount * 4 else {
            throw DNSArtifactValidationError.offsetsTableSizeMismatch(actual: header.offsetsTableSize, expected: header.ruleCount * 4)
        }
        
        let expectedTotalSize = header.totalFileSize
        guard data.count == expectedTotalSize else {
            throw DNSArtifactValidationError.fileLengthMismatch(actual: data.count, expected: expectedTotalSize)
        }
        
        // 1. Verify CRC32 Checksum over payload (offsets table + string blob)
        let payloadSlice = data.subdata(in: DNSArtifactFormat.headerSize..<data.count)
        let computedCRC32 = CRC32.checksum(data: payloadSlice)
        guard computedCRC32 == header.payloadCRC32 else {
            throw DNSArtifactValidationError.crc32Mismatch(actual: computedCRC32, expected: header.payloadCRC32)
        }
        
        if header.ruleCount == 0 {
            return header
        }
        
        // 2. Validate Offsets Table & Lexicographical Ordering Invariants
        let blobStart = DNSArtifactFormat.headerSize + Int(header.offsetsTableSize)
        let blobSize = header.stringBlobSize
        
        try data.withUnsafeBytes { rawPtr in
            let base = rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            var previousBuffer: UnsafeBufferPointer<UInt8>? = nil
            var previousString: String = ""
            
            for i in 0..<Int(header.ruleCount) {
                let offset = rawPtr.load(fromByteOffset: DNSArtifactFormat.headerSize + i * 4, as: UInt32.self).littleEndian
                
                guard offset < blobSize else {
                    throw DNSArtifactValidationError.offsetOutOfBounds(index: i, offset: offset, blobSize: blobSize)
                }
                
                // Find string termination
                let stringStart = blobStart + Int(offset)
                var curr = stringStart
                while curr < data.count && base[curr] != 0 {
                    curr += 1
                }
                
                guard curr < data.count && base[curr] == 0 else {
                    throw DNSArtifactValidationError.stringNotTerminated(index: i, offset: offset)
                }
                
                let stringLen = curr - stringStart
                let currentBuffer = UnsafeBufferPointer(start: base.advanced(by: stringStart), count: stringLen)
                let currentString = String(decoding: currentBuffer, as: UTF8.self)
                
                if let prevBuf = previousBuffer {
                    // Exact unsigned byte-for-byte comparison matching C2 binary search
                    let cmp = compareBytes(prevBuf, currentBuffer)
                    if cmp == 0 {
                        throw DNSArtifactValidationError.duplicateEntry(index: i, domain: currentString)
                    } else if cmp > 0 {
                        throw DNSArtifactValidationError.invalidStringOrdering(index: i, previous: previousString, current: currentString)
                    }
                }
                
                previousBuffer = currentBuffer
                previousString = currentString
            }
        }
        
        return header
    }
    
    /// Byte-for-byte unsigned lexicographical comparison.
    /// Returns negative if a < b, positive if a > b, 0 if equal.
    private static func compareBytes(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
        let minLen = min(a.count, b.count)
        for i in 0..<minLen {
            if a[i] < b[i] { return -1 }
            if a[i] > b[i] { return 1 }
        }
        if a.count < b.count { return -1 }
        if a.count > b.count { return 1 }
        return 0
    }
}
