import Foundation

enum Validator {
    static let validGroups: Set<String> = ["ads", "privacy", "annoyances", "regional"]

    /// Registry-level checks only. Pure function — no filesystem access.
    /// Accumulates every independent error found; does not stop at the first.
    static func validateRegistry(_ registry: Registry) -> [ValidationError] {
        var errors: [ValidationError] = []

        if registry.filters.isEmpty {
            errors.append(.emptyRegistry)
        }

        for entry in registry.filters where !validGroups.contains(entry.group) {
            errors.append(.invalidGroup(id: entry.id, found: entry.group))
        }

        var seenIDs: Set<String> = []
        var duplicateIDs: Set<String> = []
        for entry in registry.filters {
            if seenIDs.contains(entry.id) {
                duplicateIDs.insert(entry.id)
            }
            seenIDs.insert(entry.id)
        }
        for id in duplicateIDs.sorted() {
            errors.append(.duplicateRegistryID(id: id))
        }

        return errors
    }
}
