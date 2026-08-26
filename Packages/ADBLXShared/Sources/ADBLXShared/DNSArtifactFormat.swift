import Foundation

public enum DNSArtifactFormat {
    /// 4-byte ASCII Magic bytes: 'A' 'D' 'B' 'L' (0x41, 0x44, 0x42, 0x4C)
    public static let magicBytes: [UInt8] = [0x41, 0x44, 0x42, 0x4C]
    public static let magicUInt32: UInt32 = 0x4C424441 // Little-endian representation of "ADBL"
    
    /// Current format specification version
    public static let currentVersion: UInt32 = 1
    
    /// Fixed header length in bytes
    public static let headerSize: Int = 32
    
    /// Safety boundaries to prevent unbounded allocations or out-of-bounds pointer crashes
    public static let maxRuleCount: UInt32 = 2_000_000
    public static let maxArtifactSizeBytes: Int = 100 * 1024 * 1024 // 100 MB
    
    /// Standard file names inside generation directories
    public static let blocklistFilename = "block.bin"
    public static let allowlistFilename = "allow.bin"
    public static let manifestFilename = "manifest.json"
    public static let currentPointerFilename = "current.json"
}
