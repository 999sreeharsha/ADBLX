import Foundation

/// Fast intermediate line token emitted by ABPLexer.
public enum LexedABPLine: Sendable, Equatable {
    case empty
    case comment(String)
    case network(isException: Bool, rawPattern: String, rawOptions: [String])
    case cosmetic(isException: Bool, isProcedural: Bool, isScriptlet: Bool, rawDomains: String, rawBody: String)
}
