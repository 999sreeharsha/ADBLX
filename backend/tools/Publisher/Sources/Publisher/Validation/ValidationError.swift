import Foundation

enum ValidationError: Error, Equatable {
    case emptyRegistry
    case invalidGroup(id: String, found: String)
    case duplicateRegistryID(id: String)
    case missingMetadata(id: String)
    case metadataIDMismatch(filename: String, declaredID: String)
    case orphanedMetadata(id: String)
    case duplicateMetadata(id: String)
    case missingPayload(id: String, expectedPath: String)

    /// Registry=0, Metadata=1, Payload=2 — fixed category order for deterministic reporting.
    private var categoryRank: Int {
        switch self {
        case .emptyRegistry, .invalidGroup, .duplicateRegistryID:
            return 0
        case .missingMetadata, .metadataIDMismatch, .orphanedMetadata, .duplicateMetadata:
            return 1
        case .missingPayload:
            return 2
        }
    }

    private var sortKey: String {
        switch self {
        case .emptyRegistry:
            return ""
        case .invalidGroup(let id, _), .duplicateRegistryID(let id),
             .missingMetadata(let id), .orphanedMetadata(let id),
             .duplicateMetadata(let id), .missingPayload(let id, _):
            return id
        case .metadataIDMismatch(let filename, _):
            return filename
        }
    }

    static func < (lhs: ValidationError, rhs: ValidationError) -> Bool {
        if lhs.categoryRank != rhs.categoryRank {
            return lhs.categoryRank < rhs.categoryRank
        }
        return lhs.sortKey < rhs.sortKey
    }
}

extension ValidationError: Comparable {}

struct ValidationReport: Equatable {
    let errors: [ValidationError]

    var isValid: Bool { errors.isEmpty }
}
