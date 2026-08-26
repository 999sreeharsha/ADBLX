import Testing
import Foundation
@testable import ADBLX

@Suite("FilterValidator")
struct FilterValidatorTests {
    @Test("rejects empty data")
    func rejectsEmpty() {
        let validator = FilterValidator()
        #expect(throws: FilterValidator.ValidationError.empty) {
            try validator.validate(Data())
        }
    }

    @Test("rejects data over the size ceiling")
    func rejectsOversized() {
        var validator = FilterValidator()
        validator.maxByteCount = 10
        #expect(throws: FilterValidator.ValidationError.tooLarge(byteCount: 11, limit: 10)) {
            try validator.validate(Data(repeating: 0x41, count: 11))
        }
    }

    @Test("rejects non-UTF8 bytes")
    func rejectsNonUTF8() {
        let validator = FilterValidator()
        #expect(throws: FilterValidator.ValidationError.notUTF8) {
            try validator.validate(Data([0xFF, 0xFE, 0xFD]))
        }
    }

    @Test("accepts valid UTF-8 ABP text")
    func acceptsValidABPText() throws {
        let validator = FilterValidator()
        try validator.validate(Data("||doubleclick.net^$third-party\n".utf8))
    }

    @Test("accepts valid UTF-8 JSON array")
    func acceptsValidJSON() throws {
        let validator = FilterValidator()
        try validator.validate(Data("[{\"a\":1}]".utf8))
    }
}
