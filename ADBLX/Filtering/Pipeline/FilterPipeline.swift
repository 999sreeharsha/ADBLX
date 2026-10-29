import Foundation
import os
import WebKit

/// Sole orchestrator of the rule pipeline: validate → compose → compile → partition →
/// atomic write → persist metadata → reload. Every other Filtering/ type stays
/// single-purpose; this is the one place that knows the sequence, owns timing, and will
/// own progress/cancellation/retry as those needs arrive.
///
/// Target: main app ONLY.
actor FilterPipeline {
    private let validator: FilterValidator
    private let compiler: RuleCompiler
    private let compositionService: CompositionService
    private let partitioner: RulePartitioner
    private let store: FilterStore
    private let writer: AtomicRuleWriter
    private let reloader: ReloadCoordinator
    private let allowlistStore: AllowlistStore?
    
    private static let signposter = OSSignposter(subsystem: "com.ADBLX", category: "FilterPipeline")

    init(
        validator: FilterValidator,
        compiler: RuleCompiler,
        compositionService: CompositionService,
        partitioner: RulePartitioner,
        store: FilterStore,
        writer: AtomicRuleWriter,
        reloader: ReloadCoordinator,
        allowlistStore: AllowlistStore? = nil
    ) {
        self.validator = validator
        self.compiler = compiler
        self.compositionService = compositionService
        self.partitioner = partitioner
        self.store = store
        self.writer = writer
        self.reloader = reloader
        self.allowlistStore = allowlistStore
    }

    /// Installs an entire group's composition in one pass: validate every source, persist
    /// each source's verified raw payload to `Filters/` (Sprint 8.0 Commit 3 — the canonical
    /// local cache `.remove` reads from to recompose without the network), compose them into
    /// one rule set, compile once, partition once, write `Compiled/<Group>.json` once, merge
    /// every source into `installed_filters.json`, then reload per `reloadStrategy`.
    func install(
        _ composition: GroupComposition,
        reloadStrategy: ReloadStrategy = .immediate
    ) async throws -> PipelineResult {
        let totalState = Self.signposter.beginInterval("Pipeline.install", id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("Pipeline.install", totalState) }
        
        for source in composition.sources {
            try validator.validate(source.data)
        }
        for source in composition.sources {
            try await store.writeFilterPayload(source.data, filterID: source.filterID)
        }

        let installedFilters: [InstalledFilter] = composition.sources.map { source in
            InstalledFilter(
                id: source.filterID,
                group: composition.group,
                installedVersion: source.version,
                checksumSHA256: source.checksumSHA256,
                lastUpdated: Date(),
                ruleCount: 0,
                premium: source.premium
            )
        }
        return try await installGroup(
            composition,
            upsertingFilterEntries: installedFilters,
            removingFilterIDs: [],
            reloadStrategy: reloadStrategy
        )
    }

    /// Removes one filter from `group`: loads the group's remaining installed sources'
    /// raw payloads from `Filters/`, recomposes the group without `filterID`, and deletes
    /// `filterID`'s entry from `installed_filters.json` and its `Filters/<filterID>.json`
    /// payload. Reuses the same `installGroup` pipeline as `install` — no parallel removal
    /// path (Sprint 8.0 Architectural Constraints).
    func remove(
        filterID: String,
        group: FilterGroup,
        reloadStrategy: ReloadStrategy = .immediate
    ) async throws -> PipelineResult {
        let existingFilters = (try? await loadInstalledFilters()) ?? []
        let remaining = existingFilters.filter { $0.group == group && $0.id != filterID }

        var sources: [FilterSource] = []
        for filter in remaining {
            let data = try await store.readFilterPayload(filterID: filter.id)
            sources.append(FilterSource(
                filterID: filter.id,
                version: filter.installedVersion,
                checksumSHA256: filter.checksumSHA256,
                data: data
            ))
        }

        let composition = GroupComposition(group: group, sources: sources)
        let result = try await installGroup(
            composition,
            upsertingFilterEntries: [],
            removingFilterIDs: [filterID],
            reloadStrategy: reloadStrategy
        )
        try? await store.removeFilterPayload(filterID: filterID)
        return result
    }

    /// Recomposes all installed filter groups with the latest canonical allowlist rules,
    /// atomic-writes to `Compiled/<Group>.json`, and reloads affected extensions.
    func syncAllowlist(reloadStrategy: ReloadStrategy = .immediate) async throws -> [PipelineResult] {
        let existingFilters = (try? await loadInstalledFilters()) ?? []
        let installedGroups = Set(existingFilters.map(\.group))
        let targetGroups: [FilterGroup] = installedGroups.isEmpty ? [.ads] : Array(installedGroups).sorted(by: { $0.rawValue < $1.rawValue })

        var results: [PipelineResult] = []
        var extensionsToReload: [String] = []

        for group in targetGroups {
            let groupFilters = existingFilters.filter { $0.group == group }
            var sources: [FilterSource] = []
            for filter in groupFilters {
                if let data = try? await store.readFilterPayload(filterID: filter.id) {
                    sources.append(FilterSource(
                        filterID: filter.id,
                        version: filter.installedVersion,
                        checksumSHA256: filter.checksumSHA256,
                        data: data
                    ))
                }
            }

            if sources.isEmpty && group == .ads {
                if let bundledURL = Bundle.main.url(forResource: "blockerList", withExtension: "json"),
                   let data = try? Data(contentsOf: bundledURL) {
                    sources.append(FilterSource(
                        filterID: "ads-bundled",
                        version: "bundled-snapshot",
                        checksumSHA256: Checksum.sha256Hex(of: data),
                        data: data
                    ))
                }
            }

            guard !sources.isEmpty else { continue }

            let composition = GroupComposition(group: group, sources: sources)
            let result = try await installGroup(
                composition,
                upsertingFilterEntries: [],
                removingFilterIDs: [],
                reloadStrategy: .deferred
            )
            results.append(result)

            let partition = try await partitioner.partition(
                CompiledRuleSet(group: group, rawJSON: Data(), ruleCount: 0, statistics: result.compileStatistics),
                group: group
            )
            extensionsToReload.append(partition.extensionIdentifier)
        }

        if reloadStrategy == .immediate && !extensionsToReload.isEmpty {
            let reloadResults = await reloader.reload(extensionIdentifiers: extensionsToReload)
            for idx in results.indices {
                results[idx].reloadResults = reloadResults
            }
        }

        return results
    }

    /// Pure composition pipeline shared by `install` and `remove`: compose → compile →
    /// partition → atomic write `Compiled/<Group>.json` → merge `installed_filters.json`
    /// (remove `removingFilterIDs`, then upsert `upsertingFilterEntries`) → write
    /// `statistics.json` → reload per `reloadStrategy`. Knows nothing about where
    /// `composition.sources` originated (network, disk, bundled snapshot) — that's each
    /// caller's responsibility.
    private func installGroup(
        _ composition: GroupComposition,
        upsertingFilterEntries: [InstalledFilter],
        removingFilterIDs: Set<String>,
        reloadStrategy: ReloadStrategy
    ) async throws -> PipelineResult {
        let composeState = Self.signposter.beginInterval("Pipeline.compose", id: Self.signposter.makeSignpostID())
        let allowlistDomains = await allowlistStore?.loadDomains() ?? []
        let allowlistRules = SafariAllowlistCompiler.compile(domains: allowlistDomains)
        let composed = try compositionService.compose(
            composition.sources,
            group: composition.group,
            allowlistRules: allowlistRules
        )
        Self.signposter.endInterval("Pipeline.compose", composeState)

        let compileState = Self.signposter.beginInterval("Pipeline.compile", id: Self.signposter.makeSignpostID())
        let compiled = try await compiler.compile(source: composed.data, group: composition.group)
        Self.signposter.endInterval("Pipeline.compile", compileState)

        let partitionState = Self.signposter.beginInterval("Pipeline.partition", id: Self.signposter.makeSignpostID())
        let partition = try await partitioner.partition(compiled, group: composition.group)
        Self.signposter.endInterval("Pipeline.partition", partitionState)

        // WebKit In-Process DFA Ingestion Gate:
        // Validate that Safari's runtime DFA compiler accepts this exact JSON before writing to disk
        if partition.ruleCount > 0,
           let jsonString = String(data: partition.json, encoding: .utf8),
           let dfaStore = WKContentRuleListStore.default() {
            let gateIdentifier = "pipeline_gate_\(composition.group.rawValue)"
            let gateState = Self.signposter.beginInterval("Pipeline.webKitGate", id: Self.signposter.makeSignpostID())
            do {
                _ = try await dfaStore.compileContentRuleList(
                    forIdentifier: gateIdentifier,
                    encodedContentRuleList: jsonString
                )
                Self.signposter.endInterval("Pipeline.webKitGate", gateState)
                // Explicitly purge the transient gate entry to prevent unbounded disk/metadata growth
                try? await dfaStore.removeContentRuleList(forIdentifier: gateIdentifier)
            } catch {
                Self.signposter.endInterval("Pipeline.webKitGate", gateState)
                try? await dfaStore.removeContentRuleList(forIdentifier: gateIdentifier)
                Self.logger.error("WebKit DFA compiler rejected \(composition.group.rawValue) JSON: \(error.localizedDescription)")
                throw FilterPipelineError.webKitCompilationRejected(
                    group: composition.group,
                    reason: error.localizedDescription
                )
            }
        }

        let writeState = Self.signposter.beginInterval("Pipeline.atomicWrite", id: Self.signposter.makeSignpostID())
        let destinationURL = try await store.directoryURL(.compiled)
            .appendingPathComponent("\(partition.group.rawValue.capitalized).json")
        try writer.write(partition.json, to: destinationURL)
        Self.signposter.endInterval("Pipeline.atomicWrite", writeState)

        var existingFilters = (try? await loadInstalledFilters()) ?? []
        existingFilters.removeAll { removingFilterIDs.contains($0.id) }

        var upsertsByID: [String: InstalledFilter] = [:]
        for entry in upsertingFilterEntries {
            upsertsByID[entry.id] = entry
        }

        for index in existingFilters.indices {
            let existing = existingFilters[index]
            guard existing.group == composition.group else { continue }
            let source = upsertsByID.removeValue(forKey: existing.id) ?? existing
            existingFilters[index] = InstalledFilter(
                id: source.id,
                group: source.group,
                installedVersion: source.installedVersion,
                checksumSHA256: source.checksumSHA256,
                lastUpdated: compiled.statistics.lastUpdated,
                ruleCount: compiled.ruleCount,
                premium: entry.premium
            )
        }
        for entry in upsertsByID.values {
            existingFilters.append(InstalledFilter(
                id: entry.id,
                group: entry.group,
                installedVersion: entry.installedVersion,
                checksumSHA256: entry.checksumSHA256,
                lastUpdated: compiled.statistics.lastUpdated,
                ruleCount: compiled.ruleCount,
                premium: source.premium
            ))
        }
        let installedFiltersData = try JSONEncoder().encode(existingFilters)
        try await store.writeMetadata(installedFiltersData, filename: "installed_filters.json")

        let statisticsData = try JSONEncoder().encode(compiled.statistics)
        try await store.writeMetadata(statisticsData, filename: "statistics.json")

        let reloadState = Self.signposter.beginInterval("Pipeline.reload", id: Self.signposter.makeSignpostID())
        let reloadResults: [ReloadCoordinator.ReloadResult]
        if reloadStrategy == .immediate {
            reloadResults = await reloader.reload(extensionIdentifiers: [partition.extensionIdentifier])
        } else {
            reloadResults = []
        }
        Self.signposter.endInterval("Pipeline.reload", reloadState)

        return PipelineResult(
            group: composition.group,
            compiledRuleCount: compiled.ruleCount,
            installedRuleCount: partition.ruleCount,
            compileStatistics: compiled.statistics,
            reloadResults: reloadResults
        )
    }

    private static let logger = Logger(subsystem: "com.ADBLX", category: "FilterPipeline")

    /// Resolves a bundled resource URL searching main bundle, current bundle, and all loaded bundles
    /// across root and "Filters" subdirectory.
    private func bundledURL(forResource name: String, withExtension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Filters") {
            return url
        }
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: name, withExtension: ext) ??
                         bundle.url(forResource: name, withExtension: ext, subdirectory: "Filters") {
                return url
            }
        }
        return nil
    }

    /// Installs the bundled snapshot baseline for each configured filter group independently:
    /// Ads (EasyList -> fallback blockerList fixture), Privacy (EasyPrivacy), Annoyances (Fanboy Annoyances).
    ///
    /// Per-group isolation: failure in one filter list does not prevent remaining groups from installing.
    func installBundledSnapshotIfNeeded(includePremium: Bool = false) async throws -> [PipelineResult] {
        var results: [PipelineResult] = []
        var atLeastOneInstalled = false

        // 1. Ads Group (EasyList -> Fallback: blockerList.json fixture)
        if let adsURL = bundledURL(forResource: "easylist", withExtension: "txt") {
            do {
                let adsData = try Data(contentsOf: adsURL)
                let adsComp = GroupComposition(
                    group: .ads,
    private func loadInstalledFilters() async throws -> [InstalledFilter] {
        let data = try await store.read("installed_filters.json", in: .metadata)
        return try JSONDecoder().decode([InstalledFilter].self, from: data)
    }
}

// MARK: - Bundled snapshots

extension FilterPipeline {
                    sources: [FilterSource(
                        filterID: "easylist",
                        version: "bundled-baseline",
                        checksumSHA256: Checksum.sha256Hex(of: adsData),
                        data: adsData
                    )]
                )
                let result = try await install(adsComp, reloadStrategy: .immediate)
                results.append(result)
                atLeastOneInstalled = true
            } catch {
                Self.logger.error("Failed to install bundled EasyList: \(error, privacy: .public)")
            }
        } else if let fallbackURL = bundledURL(forResource: "blockerList", withExtension: "json") {
            do {
                let fallbackData = try Data(contentsOf: fallbackURL)
                let fallbackComp = GroupComposition(
                    group: .ads,
                    sources: [FilterSource(
                        filterID: "ads-bundled",
                        version: "bundled-snapshot",
                        checksumSHA256: Checksum.sha256Hex(of: fallbackData),
                        data: fallbackData
                    )]
                )
                let result = try await install(fallbackComp, reloadStrategy: .immediate)
                results.append(result)
                atLeastOneInstalled = true
            } catch {
                Self.logger.error("Failed to install bundled fallback fixture: \(error, privacy: .public)")
            }
        }

        // 2. Privacy Group (EasyPrivacy)
        if let privacyURL = bundledURL(forResource: "easyprivacy", withExtension: "txt") {
            do {
                let privacyData = try Data(contentsOf: privacyURL)
                let privacyComp = GroupComposition(
                    group: .privacy,
                    sources: [FilterSource(
                        filterID: "easyprivacy",
                        version: "bundled-baseline",
                        checksumSHA256: Checksum.sha256Hex(of: privacyData),
                        data: privacyData
                    )]
                )
                let result = try await install(privacyComp, reloadStrategy: .immediate)
                results.append(result)
                atLeastOneInstalled = true
            } catch {
                Self.logger.error("Failed to install bundled EasyPrivacy: \(error, privacy: .public)")
            }
        }

        // 3. Premium groups are bundled but installed only for entitled users: a fresh
        // free/expired install must never receive Annoyances rules.
        if includePremium {
            let premiumResults = await installBundledPremiumSnapshot()
            results.append(contentsOf: premiumResults)
            atLeastOneInstalled = atLeastOneInstalled || !premiumResults.isEmpty
        }

        guard atLeastOneInstalled else {
            throw FilterPipelineError.bundledSnapshotMissing
        }

        return results
    }

    /// Installs the bundled premium lists (today: Fanboy Annoyances) as the offline baseline
    /// for an entitled user. Callers must have verified entitlement. Failures are logged and
    /// yield no result for that list; the normal update path will install it from the network.
    func installBundledPremiumSnapshot(reloadStrategy: ReloadStrategy = .immediate) async -> [PipelineResult] {
        guard let annoyancesURL = bundledURL(forResource: "fanboy-annoyances", withExtension: "txt") else {
            return []
        }
        do {
            let annoyancesData = try Data(contentsOf: annoyancesURL)
            let composition = GroupComposition(
                group: .annoyances,
                sources: [FilterSource(
                    filterID: BundledPremiumCatalog.annoyancesFilterID,
                    version: "bundled-baseline",
                    checksumSHA256: Checksum.sha256Hex(of: annoyancesData),
                    data: annoyancesData,
                    premium: true
                )]
            )
            return [try await install(composition, reloadStrategy: reloadStrategy)]
        } catch {
            Self.logger.error("Failed to install bundled premium snapshot: \(error, privacy: .public)")
            return []
        }
    }
}

enum ReloadStrategy {
    case immediate
    case deferred
}

struct PipelineResult: Sendable {
    var group: FilterGroup
    var compiledRuleCount: Int
    var installedRuleCount: Int
    var compileStatistics: RuleStatistics
    var reloadResults: [ReloadCoordinator.ReloadResult]
}

enum FilterPipelineError: Error, Equatable {
    case bundledSnapshotMissing
    case webKitCompilationRejected(group: FilterGroup, reason: String)
}
