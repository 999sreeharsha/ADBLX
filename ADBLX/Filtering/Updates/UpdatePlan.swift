import Foundation

/// One outcome of diffing a fetched `FilterManifest` against the currently
/// `InstalledFilter`s. Pure data — `UpdateCoordinator` decides what to actually do with
/// each case; this type only describes what's true about each manifest entry (or, for
/// `.install`, each group of entries).
enum UpdateAction: Equatable {
    /// One or more entries in the same `FilterGroup` that are new, or whose
    /// version/checksum changed relative to what's installed. Grouped so
    /// `UpdateCoordinator` composes and installs them in a single `FilterPipeline` call —
    /// see the Sprint 3A design doc for why per-filter `.install` was replaced by this.
    case install(group: FilterGroup, entries: [FilterManifest.Entry])
    /// Installed filter no longer present in the manifest.
    case remove(filterID: String)
    /// Installed, unchanged, still entitled — no action needed.
    case keep(filterID: String)
    /// Not installed, gated behind a purchase that doesn't exist yet (no StoreKit this sprint).
    case skipPremium(FilterManifest.Entry)
}

struct UpdatePlan: Equatable {
    var actions: [UpdateAction]
}

/// Pure diff: no I/O, no async. Compares each manifest entry against the matching
/// `InstalledFilter` (by `id`) on `(version, checksumSHA256)`, then buckets every entry
/// that needs installing by `FilterGroup` — grouping is by key, not manifest adjacency,
/// so entries for the same group don't need to be consecutive in the manifest.
enum UpdatePlanner {
    static func plan(manifest: FilterManifest, installed: [InstalledFilter]) -> UpdatePlan {
        let installedByID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        var manifestIDs = Set<String>()
        var actions: [UpdateAction] = []
        var installsByGroup: [FilterGroup: [FilterManifest.Entry]] = [:]
        var groupOrder: [FilterGroup] = []

        for entry in manifest.entries {
            manifestIDs.insert(entry.id)

            if let existing = installedByID[entry.id] {
                if existing.installedVersion == entry.version && existing.checksumSHA256 == entry.checksumSHA256 {
                    actions.append(.keep(filterID: entry.id))
                    continue
                }
                // else: version/checksum changed — falls through to grouping below.
            } else if entry.premium {
                actions.append(.skipPremium(entry))
                continue
            }
            // else: new, non-premium entry — falls through to grouping below.

            if installsByGroup[entry.group] == nil {
                groupOrder.append(entry.group)
            }
            installsByGroup[entry.group, default: []].append(entry)
        }

        for group in groupOrder {
            actions.append(.install(group: group, entries: installsByGroup[group] ?? []))
        }

        for filter in installed where !manifestIDs.contains(filter.id) {
            actions.append(.remove(filterID: filter.id))
        }

        return UpdatePlan(actions: actions)
    }
}
