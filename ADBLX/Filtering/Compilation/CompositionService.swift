import Foundation

/// Merges every `FilterSource` in a `GroupComposition` into one rule set before
/// compilation. Composition happens at the JSON-array level (decode each source,
/// concatenate the decoded arrays, re-encode once) rather than raw byte concatenation,
/// because `RuleCompiler`'s current implementation assumes its input is a single valid
/// Safari content-blocker JSON array — concatenating two such arrays as raw bytes would
/// not itself be valid JSON.
///
/// Pure, no I/O, `nonisolated` — same shape as `RuleCompiler`/`RulePartitioner`.
protocol CompositionService: Sendable {
    nonisolated func compose(_ sources: [FilterSource], group: FilterGroup) throws -> ComposedRules
}

enum CompositionServiceError: Error, Equatable {
    case invalidSource(filterID: String)
}

struct JSONArrayCompositionService: CompositionService {
    nonisolated func compose(_ sources: [FilterSource], group: FilterGroup) throws -> ComposedRules {
        var merged: [Any] = []
        for source in sources {
            guard let array = try? JSONSerialization.jsonObject(with: source.data) as? [Any] else {
                throw CompositionServiceError.invalidSource(filterID: source.filterID)
            }
            merged.append(contentsOf: array)
        }
        // .sortedKeys: without it, JSONSerialization does not guarantee stable key
        // ordering for the dictionaries inside `merged` across separate encode calls —
        // "same ordered input twice → byte-identical output" depends on this.
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        return ComposedRules(group: group, data: data, sourceCount: sources.count, ruleCount: merged.count)
    }
}
