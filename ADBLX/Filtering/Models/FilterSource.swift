import Foundation

/// One filter's normalized source data, ready to be composed with sibling filters in the
/// same `FilterGroup` before compilation. Deliberately has no `group` field — the group
/// is a property of the `GroupComposition` this source lives inside, not of the source
/// itself, so nothing downstream can construct a composition whose sources disagree with
/// its own group.
struct FilterSource: Equatable {
    let filterID: String
    let version: String
    let checksumSHA256: String
    let data: Data
}
