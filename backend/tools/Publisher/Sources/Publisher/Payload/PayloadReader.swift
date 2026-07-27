import Foundation
import CryptoKit

struct PayloadInfo: Equatable {
    let checksumSHA256: String
    let ruleCount: Int
}

enum PayloadReaderError: Error, Equatable {
    case fileNotFound(path: String)
}

enum PayloadReader {
    static func read(fileAt url: URL) throws -> PayloadInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PayloadReaderError.fileNotFound(path: url.path)
        }

        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        let checksum = digest.map { String(format: "%02x", $0) }.joined()

        let text = String(decoding: data, as: UTF8.self)
        let ruleCount = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("!") }
            .count

        return PayloadInfo(checksumSHA256: checksum, ruleCount: ruleCount)
    }
}
