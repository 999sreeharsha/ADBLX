import Foundation

/// Everything the DEBUG developer section shows, gathered off the main actor. Counts, enum
/// case names and product IDs only — nothing here is logged.
nonisolated struct DeveloperDiagnostics: Sendable {
    struct GroupCount: Equatable, Sendable {
        let group: FilterGroup
        let ruleCount: Int
    }

    var entitlementCase = "unresolved"
    var validUntil: Date?
    var paidProductID: String?
    var verifiedCount = 0
    var unverifiedErrors: [String] = []
    var trial = "unknown"
    var groupCounts: [GroupCount] = []
    var reloads: [ReloadResultLog.Entry] = []

    static func caseName(of state: EntitlementState) -> String {
        switch state {
        case .free: return "free"
        case .trial: return "trial"
        case .monthly: return "monthly"
        case .annual: return "annual"
        case .lifetime: return "lifetime"
        }
    }

    /// `InstalledFilter.ruleCount` is already the group-level compiled count (see gotchas.md),
    /// so the group's count is the max over its filters; a group with none installed is 0.
    static func groupRuleCounts(from filters: [InstalledFilter]) -> [GroupCount] {
        let groups: [FilterGroup] = [.ads, .privacy, .annoyances, .regional]
        return groups.map { group in
            GroupCount(group: group, ruleCount: filters.filter { $0.group == group }.map(\.ruleCount).max() ?? 0)
        }
    }

    static func trialDescription(_ snapshot: TrialSnapshot) -> String {
        switch snapshot {
        case .notStarted: return "notStarted"
        case .active(_, let days): return "active daysRemaining=\(days)"
        case .expired: return "expired"
        }
    }

    #if DEBUG
    /// Recompiles every installed group from its stored list with the current compiler and
    /// reloads the extensions, so a compiler fix reaches the device without a list update.
    /// Returns "group=ruleCount" pairs, or the failing error's type name.
    static func recompileAll(pipeline: FilterPipeline, gate: FilterTransactionGate = .shared) async -> String {
        do {
            let results = try await gate.run { try await pipeline.syncAllowlist() }
            return results.map { "\($0.group.rawValue)=\($0.compiledRuleCount)" }.joined(separator: " ")
        } catch {
            return "failed: \(type(of: error))"
        }
    }
    #endif

    /// Refreshes entitlement first so the screen shows what StoreKit reports right now.
    static func gather(
        service: StoreKitSubscriptionService,
        trial: TrialSource,
        store: FilterStore,
        reloadLog: ReloadResultLog = .shared
    ) async -> DeveloperDiagnostics {
        await service.refreshEntitlements()
        let snapshot = await service.snapshot()
        var result = DeveloperDiagnostics()
        result.entitlementCase = caseName(of: snapshot.state)
        result.validUntil = snapshot.state.validUntil
        result.paidProductID = snapshot.paidProductID
        result.verifiedCount = snapshot.verifiedCount
        result.unverifiedErrors = snapshot.unverifiedErrors
        result.trial = trialDescription(await trial.snapshot(at: Date()))
        let filters = (try? await store.read("installed_filters.json", in: .metadata))
            .flatMap { try? JSONDecoder().decode([InstalledFilter].self, from: $0) } ?? []
        result.groupCounts = groupRuleCounts(from: filters)
        result.reloads = reloadLog.entries()
        return result
    }
}
