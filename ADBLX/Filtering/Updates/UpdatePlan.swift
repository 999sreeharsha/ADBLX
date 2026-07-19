import Foundation

/// One outcome of diffing a fetched `FilterManifest` against the currently
/// `InstalledFilter`s. Pure data — `UpdateCoordinator` decides what to actually do with
/// each case; this type only describes what's true about each manifest entry.
enum UpdateAction: Equatable {
    /// New filter, or an installed filter whose version/checksum changed.
    case install(FilterManifest.Entry)
    /// Installed filter no longer present in the manifest.
    case remove(filterID: String)
    /// Installed, unchanged, still entitled — no action needed.
    case keep(filterID: String)
    /// Not installed, gated behind a purchase that doesn't exist yet (no StoreKit this sprint).
    case skipPremium(FilterManifest.Entry)
    /// Non-`.ads` group — `RulePartitioner` can only route `.ads` this sprint.
    case unsupportedGroup(FilterManifest.Entry)
    /// A second (or later) `.ads`-group entry in the same plan that would also need
    /// installing. `FilterPipeline`/`RulePartitioner` support only one compiled `.ads`
    /// output per install call this sprint, so only the first such entry becomes
    /// `.install`; the rest surface here instead of silently overwriting it.
    case groupConflict(FilterManifest.Entry)
}

struct UpdatePlan: Equatable {
    var actions: [UpdateAction]
}

/// Pure diff: no I/O, no async. Compares each manifest entry against the matching
/// `InstalledFilter` (by `id`) on `(version, checksumSHA256)`.
enum UpdatePlanner {
    static func plan(manifest: FilterManifest, installed: [InstalledFilter]) -> UpdatePlan {
        let installedByID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        var manifestIDs = Set<String>()
        var actions: [UpdateAction] = []
        var groupsWithPendingInstall = Set<FilterGroup>()

        for entry in manifest.entries {
            manifestIDs.insert(entry.id)

            guard entry.group == .ads else {
                actions.append(.unsupportedGroup(entry))
                continue
            }

            if let existing = installedByID[entry.id] {
                if existing.installedVersion == entry.version && existing.checksumSHA256 == entry.checksumSHA256 {
                    actions.append(.keep(filterID: entry.id))
                } else if groupsWithPendingInstall.contains(entry.group) {
                    actions.append(.groupConflict(entry))
                } else {
                    actions.append(.install(entry))
                    groupsWithPendingInstall.insert(entry.group)
                }
            } else if entry.premium {
                actions.append(.skipPremium(entry))
            } else if groupsWithPendingInstall.contains(entry.group) {
                actions.append(.groupConflict(entry))
            } else {
                actions.append(.install(entry))
                groupsWithPendingInstall.insert(entry.group)
            }
        }

        for filter in installed where !manifestIDs.contains(filter.id) {
            actions.append(.remove(filterID: filter.id))
        }

        return UpdatePlan(actions: actions)
    }
}
