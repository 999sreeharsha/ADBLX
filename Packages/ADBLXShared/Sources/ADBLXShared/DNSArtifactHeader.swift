import Foundation

public struct DNSArtifactHeader: Equatable {
    public let magic: UInt32
    public let version: UInt32
    public let ruleCount: UInt32
    public let offsetsTableSize: UInt32
    public let stringBlobSize: UInt32
    public let payloadCRC32: UInt32
    public let reserved0: UInt32
    public let reserved1: UInt32
    
    public init(
        ruleCount: UInt32,
        stringBlobSize: UInt32,
        payloadCRC32: UInt32,
        version: UInt32 = DNSArtifactFormat.currentVersion
    ) {
        self.magic = DNSArtifactFormat.magicUInt32
        self.version = version
        self.ruleCount = ruleCount
        self.offsetsTableSize = ruleCount * 4
        self.stringBlobSize = stringBlobSize
        self.payloadCRC32 = payloadCRC32
        self.reserved0 = 0
        self.reserved1 = 0
    }
    
    public init(
        magic: UInt32,
        version: UInt32,
        ruleCount: UInt32,
        offsetsTableSize: UInt32,
        stringBlobSize: UInt32,
        payloadCRC32: UInt32,
        reserved0: UInt32 = 0,
        reserved1: UInt32 = 0
    ) {
        self.magic = magic
        self.version = version
        self.ruleCount = ruleCount
        self.offsetsTableSize = offsetsTableSize
        self.stringBlobSize = stringBlobSize
        self.payloadCRC32 = payloadCRC32
        self.reserved0 = reserved0
        self.reserved1 = reserved1
    }
    
    public var totalFileSize: Int {
        DNSArtifactFormat.headerSize + Int(offsetsTableSize) + Int(stringBlobSize)
    }
    
    public func serialize() -> Data {
        var data = Data(capacity: DNSArtifactFormat.headerSize)
        var m = magic.littleEndian
        var v = version.littleEndian
        var r = ruleCount.littleEndian
        var o = offsetsTableSize.littleEndian
        var s = stringBlobSize.littleEndian
        var c = payloadCRC32.littleEndian
        var res0 = reserved0.littleEndian
        var res1 = reserved1.littleEndian
        
        withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &r) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &o) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &res0) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &res1) { data.append(contentsOf: $0) }
        
        return data
    }
    
    public static func deserialize(from data: Data) -> DNSArtifactHeader? {
        guard data.count >= DNSArtifactFormat.headerSize else { return nil }
        
        return data.withUnsafeBytes { ptr -> DNSArtifactHeader? in
            let m = ptr.load(fromByteOffset: 0, as: UInt32.self).littleEndian
            let v = ptr.load(fromByteOffset: 4, as: UInt32.self).littleEndian
            let r = ptr.load(fromByteOffset: 8, as: UInt32.self).littleEndian
            let o = ptr.load(fromByteOffset: 12, as: UInt32.self).littleEndian
            let s = ptr.load(fromByteOffset: 16, as: UInt32.self).littleEndian
            let c = ptr.load(fromByteOffset: 20, as: UInt32.self).littleEndian
            let res0 = ptr.load(fromByteOffset: 24, as: UInt32.self).littleEndian
            let res1 = ptr.load(fromByteOffset: 28, as: UInt32.self).littleEndian
            
            return DNSArtifactHeader(
                magic: m,
                version: v,
                ruleCount: r,
                offsetsTableSize: o,
                stringBlobSize: s,
                payloadCRC32: c,
                reserved0: res0,
                reserved1: res1
            )
        }
    }
}
