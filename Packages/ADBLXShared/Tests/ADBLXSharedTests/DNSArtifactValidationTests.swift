import XCTest
@testable import ADBLXShared

final class DNSArtifactValidationTests: XCTestCase {
    
    // MARK: - Helper to construct synthetic binary artifacts
    
    private func constructArtifact(
        domains: [String],
        corruptMagic: Bool = false,
        corruptCRC: Bool = false,
        corruptSize: Bool = false,
        corruptOffset: Bool = false,
        corruptTermination: Bool = false
    ) -> Data {
        var stringBlob = Data()
        var offsets: [UInt32] = []
        
        for domain in domains {
            offsets.append(UInt32(stringBlob.count))
            stringBlob.append(contentsOf: domain.utf8)
            if !corruptTermination {
                stringBlob.append(0x00) // Null terminator
            }
        }
        
        if corruptOffset, !offsets.isEmpty {
            offsets[0] = UInt32(stringBlob.count + 100) // Out of bounds
        }
        
        let ruleCount = UInt32(domains.count)
        let offsetsSize = ruleCount * 4
        let stringBlobSize = UInt32(stringBlob.count)
        
        // Compute CRC32 over offsets + string blob
        var payload = Data(capacity: Int(offsetsSize + stringBlobSize))
        for offset in offsets {
            var o = offset.littleEndian
            withUnsafeBytes(of: &o) { payload.append(contentsOf: $0) }
        }
        payload.append(stringBlob)
        
        var crc = CRC32.checksum(data: payload)
        if corruptCRC {
            crc ^= 0xDEADBEEF
        }
        
        let header = DNSArtifactHeader(
            magic: corruptMagic ? 0x12345678 : DNSArtifactFormat.magicUInt32,
            version: DNSArtifactFormat.currentVersion,
            ruleCount: ruleCount,
            offsetsTableSize: offsetsSize,
            stringBlobSize: stringBlobSize,
            payloadCRC32: crc
        )
        
        var fullData = header.serialize()
        fullData.append(payload)
        
        if corruptSize {
            fullData.append(0xFF) // Extra byte
        }
        
        return fullData
    }
    
    // MARK: - Test Cases
    
    func testHeaderSerializationAndDeserialization() {
        let original = DNSArtifactHeader(
            ruleCount: 100,
            stringBlobSize: 1500,
            payloadCRC32: 0xCAFEBABE
        )
        
        let serialized = original.serialize()
        XCTAssertEqual(serialized.count, DNSArtifactFormat.headerSize)
        
        let deserialized = DNSArtifactHeader.deserialize(from: serialized)
        XCTAssertNotNil(deserialized)
        XCTAssertEqual(deserialized, original)
        XCTAssertEqual(deserialized?.offsetsTableSize, 400)
        XCTAssertEqual(deserialized?.totalFileSize, 32 + 400 + 1500)
    }
    
    func testValidArtifactValidation() throws {
        // Domains in strictly sorted reversed-label format
        let sortedDomains = [
            "com.apple",
            "com.apple.developer",
            "com.example.ads",
            "net.doubleclick",
            "net.doubleclick.ad",
            "org.wikipedia"
        ]
        
        let data = constructArtifact(domains: sortedDomains)
        let header = try DNSArtifactValidator.validate(data: data)
        
        XCTAssertEqual(header.ruleCount, 6)
        XCTAssertEqual(header.version, 1)
        XCTAssertEqual(header.magic, DNSArtifactFormat.magicUInt32)
    }
    
    func testEmptyArtifactValidation() throws {
        let data = constructArtifact(domains: [])
        let header = try DNSArtifactValidator.validate(data: data)
        
        XCTAssertEqual(header.ruleCount, 0)
        XCTAssertEqual(header.totalFileSize, 32)
    }
    
    func testInvalidMagicRejected() {
        let data = constructArtifact(domains: ["com.example"], corruptMagic: true)
        XCTAssertThrowsError(try DNSArtifactValidator.validate(data: data)) { error in
            guard case DNSArtifactValidationError.invalidMagic = error else {
                XCTFail("Expected invalidMagic, got \(error)")
                return
            }
        }
    }
    
    func testCRC32MismatchRejected() {
        let data = constructArtifact(domains: ["com.example"], corruptCRC: true)
        XCTAssertThrowsError(try DNSArtifactValidator.validate(data: data)) { error in
            guard case DNSArtifactValidationError.crc32Mismatch = error else {
                XCTFail("Expected crc32Mismatch, got \(error)")
                return
            }
        }
    }
    
    func testFileSizeMismatchRejected() {
        let data = constructArtifact(domains: ["com.example"], corruptSize: true)
        XCTAssertThrowsError(try DNSArtifactValidator.validate(data: data)) { error in
            guard case DNSArtifactValidationError.fileLengthMismatch = error else {
                XCTFail("Expected fileLengthMismatch, got \(error)")
                return
            }
        }
    }
    
    func testOutOfBoundsOffsetRejected() {
        let data = constructArtifact(domains: ["com.example"], corruptOffset: true)
        XCTAssertThrowsError(try DNSArtifactValidator.validate(data: data)) { error in
            guard case DNSArtifactValidationError.offsetOutOfBounds = error else {
                XCTFail("Expected offsetOutOfBounds, got \(error)")
                return
            }
        }
    }
    
    func testUnsortedByteOrderingRejected() {
        // Out of order! "net.doubleclick" before "com.apple"
        let unsorted = ["net.doubleclick", "com.apple"]
        let data = constructArtifact(domains: unsorted)
        
        XCTAssertThrowsError(try DNSArtifactValidator.validate(data: data)) { error in
            guard case DNSArtifactValidationError.invalidStringOrdering(let idx, let prev, let curr) = error else {
                XCTFail("Expected invalidStringOrdering, got \(error)")
                return
            }
            XCTAssertEqual(idx, 1)
            XCTAssertEqual(prev, "net.doubleclick")
            XCTAssertEqual(curr, "com.apple")
        }
    }
    
    func testDuplicateDomainRejected() {
        let duplicates = ["com.apple", "com.apple"]
        let data = constructArtifact(domains: duplicates)
        
        XCTAssertThrowsError(try DNSArtifactValidator.validate(data: data)) { error in
            guard case DNSArtifactValidationError.duplicateEntry(let idx, let domain) = error else {
                XCTFail("Expected duplicateEntry, got \(error)")
                return
            }
            XCTAssertEqual(idx, 1)
            XCTAssertEqual(domain, "com.apple")
        }
    }
    
    func testManifestAndCurrentPointerSerialization() throws {
        let manifest = DNSGenerationManifest(
            generation: 42,
            publishedAt: 1771987200,
            blocklistCount: 402148,
            allowlistCount: 15,
            sha256Blocklist: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            sha256Allowlist: "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let manifestData = try encoder.encode(manifest)
        
        let decoder = JSONDecoder()
        let decodedManifest = try decoder.decode(DNSGenerationManifest.self, from: manifestData)
        XCTAssertEqual(decodedManifest, manifest)
        XCTAssertEqual(decodedManifest.generation, 42)
        
        let pointer = DNSCurrentPointer(generationNumber: 42, publishedAt: 1771987200)
        XCTAssertEqual(pointer.activeGeneration, "000042")
        
        let pointerData = try encoder.encode(pointer)
        let decodedPointer = try decoder.decode(DNSCurrentPointer.self, from: pointerData)
        XCTAssertEqual(decodedPointer, pointer)
    }
    
    func testSHA256Computation() {
        let data = "test-payload".data(using: .utf8)!
        let hash = DNSGenerationManifest.computeSHA256(data: data)
        XCTAssertEqual(hash.count, 64)
        // Known SHA-256 for "test-payload" is 6f06dd0e26608013eff30bb1e951cda7de3fdd9e78e907470e0dd5c0ed25e273
        XCTAssertEqual(hash, "6f06dd0e26608013eff30bb1e951cda7de3fdd9e78e907470e0dd5c0ed25e273")
    }
}
