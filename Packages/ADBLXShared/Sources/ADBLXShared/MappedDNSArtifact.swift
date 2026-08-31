import Foundation

public final class MappedDNSArtifact {
    public let data: Data
    public let header: DNSArtifactHeader
    private let offsetsStart: Int
    private let blobStart: Int
    private let blobSize: Int
    
    public init(fileURL: URL) throws {
        // Map using .alwaysMapped so pages fault into memory on demand without full heap copies
        let mappedData = try Data(contentsOf: fileURL, options: .alwaysMapped)
        let validatedHeader = try DNSArtifactValidator.validate(data: mappedData)
        
        self.data = mappedData
        self.header = validatedHeader
        self.offsetsStart = DNSArtifactFormat.headerSize
        self.blobStart = offsetsStart + Int(validatedHeader.offsetsTableSize)
        self.blobSize = Int(validatedHeader.stringBlobSize)
    }
    
    public init(validatedData: Data, header: DNSArtifactHeader) {
        self.data = validatedData
        self.header = header
        self.offsetsStart = DNSArtifactFormat.headerSize
        self.blobStart = offsetsStart + Int(header.offsetsTableSize)
        self.blobSize = Int(header.stringBlobSize)
    }
    
    public var ruleCount: UInt32 {
        header.ruleCount
    }
    
    /// Performs direct byte-pointer binary search against the mapped artifact.
    ///
    /// - Parameter target: Exact reversed-label UTF-8 prefix buffer to match (e.g. `net.doubleclick`).
    /// - Returns: `true` if the target exactly matches an entry in the artifact.
    public func contains(target: UnsafeBufferPointer<UInt8>) -> Bool {
        guard header.ruleCount > 0 else { return false }
        
        return data.withUnsafeBytes { rawPtr -> Bool in
            let base = rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            var low = 0
            var high = Int(header.ruleCount) - 1
            
            while low <= high {
                let mid = low + (high - low) / 2
                
                // Read Little-Endian UInt32 offset directly from mapped memory
                let offset = rawPtr.load(fromByteOffset: offsetsStart + mid * 4, as: UInt32.self).littleEndian
                let startIdx = blobStart + Int(offset)
                
                // Direct byte comparison, zero allocations
                var curr = startIdx
                var i = 0
                var isLess = false
                var isGreater = false
                
                while i < target.count && curr < data.count && base[curr] != 0 {
                    let tb = target[i]
                    let mb = base[curr]
                    if tb < mb { isLess = true; break }
                    if tb > mb { isGreater = true; break }
                    i += 1
                    curr += 1
                }
                
                if isLess {
                    high = mid - 1
                } else if isGreater {
                    low = mid + 1
                } else {
                    let targetEnded = (i == target.count)
                    let midEnded = (curr >= data.count || base[curr] == 0)
                    
                    if targetEnded && midEnded {
                        return true
                    } else if targetEnded {
                        high = mid - 1
                    } else {
                        low = mid + 1
                    }
                }
            }
            
            return false
        }
    }
    
    /// Evaluates a domain query using reversed-label suffix walk against the mapped artifact.
    ///
    /// Checks exact reversed labels: "com", "com.google", "com.google.www".
    public func matchesDomain(domain: String) -> Bool {
        let parts = domain.split(separator: ".")
        let reversedSuffix = parts.reversed().joined(separator: ".")
        let utf8Bytes = Array(reversedSuffix.utf8)
        
        return utf8Bytes.withUnsafeBufferPointer { ptr -> Bool in
            guard ptr.count > 0, let baseAddress = ptr.baseAddress else { return false }
            var checkLen = 0
            while checkLen <= ptr.count {
                if checkLen == ptr.count || ptr[checkLen] == 46 /* '.' */ {
                    let prefixBuf = UnsafeBufferPointer(start: baseAddress, count: checkLen)
                    if contains(target: prefixBuf) {
                        return true
                    }
                }
                checkLen += 1
            }
            return false
        }
    }
}
