import Foundation

/// The input to one `FilterPipeline.install(_:reloadStrategy:)` call: every filter source
/// that should compose into a single compiled `Compiled/<Group>.json`.
///
/// **Invariant:** every `FilterSource` in `sources` belongs to `group`. This is
/// established once, by `UpdatePlanner` (which only ever buckets a manifest entry into
/// the bucket matching `entry.group`) and by `FilterPipeline.installBundledSnapshotIfNeeded`
/// (which hand-builds a single-source, single-group composition). Downstream components
/// (`CompositionService`, `RuleCompiler`, `RulePartitioner`) rely on this invariant and do
/// not revalidate it.
///
/// **Ordering:** `sources` order is authoritative and preserved end-to-end — manifest
/// order in, manifest order out of `CompositionService`. Nothing reorders it.
struct GroupComposition: Equatable {
    let group: FilterGroup
    let sources: [FilterSource]
}
