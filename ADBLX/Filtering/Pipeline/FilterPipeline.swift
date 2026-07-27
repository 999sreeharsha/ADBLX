// ADBLX/Filtering/Pipeline/FilterPipeline.swift
import Foundation

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

    init(
        validator: FilterValidator,
        compiler: RuleCompiler,
        compositionService: CompositionService,
        partitioner: RulePartitioner,
        store: FilterStore,
        writer: AtomicRuleWriter,
        reloader: ReloadCoordinator
    ) {
        self.validator = validator
        self.compiler = compiler
        self.compositionService = compositionService
        self.partitioner = partitioner
        self.store = store
        self.writer = writer
        self.reloader = reloader
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
                // lastUpdated/ruleCount are placeholders overwritten by installGroup once
                // compile statistics are known — see installGroup's merge step below.
                lastUpdated: Date(),
                ruleCount: 0
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
        let composed = try compositionService.compose(composition.sources, group: composition.group)
        let compiled = try await compiler.compile(source: composed.data, group: composition.group)
        let partition = try await partitioner.partition(compiled, group: composition.group)

        let destinationURL = try await store.directoryURL(.compiled)
            .appendingPathComponent("\(partition.group.rawValue.capitalized).json")
        try writer.write(partition.json, to: destinationURL)

        var existingFilters = (try? await loadInstalledFilters()) ?? []
        existingFilters.removeAll { removingFilterIDs.contains($0.id) }
        for entry in upsertingFilterEntries {
            let resolved = InstalledFilter(
                id: entry.id,
                group: entry.group,
                installedVersion: entry.installedVersion,
                checksumSHA256: entry.checksumSHA256,
                lastUpdated: compiled.statistics.lastUpdated,
                ruleCount: compiled.ruleCount
            )
            existingFilters.removeAll { $0.id == resolved.id }
            existingFilters.append(resolved)
        }
        let installedFiltersData = try JSONEncoder().encode(existingFilters)
        try await store.writeMetadata(installedFiltersData, filename: "installed_filters.json")

        let statisticsData = try JSONEncoder().encode(compiled.statistics)
        try await store.writeMetadata(statisticsData, filename: "statistics.json")

        let reloadResults: [ReloadCoordinator.ReloadResult]
        if reloadStrategy == .immediate {
            reloadResults = await reloader.reload(extensionIdentifiers: [partition.extensionIdentifier])
        } else {
            reloadResults = []
        }

        return PipelineResult(
            group: composition.group,
            compiledRuleCount: compiled.ruleCount,
            installedRuleCount: partition.ruleCount,
            compileStatistics: compiled.statistics,
            reloadResults: reloadResults
        )
    }

    /// Sprint 1: always (re)installs from the bundled snapshot on every call — "IfNeeded"
    /// becomes meaningful once Part 10 adds version comparison against a fetched manifest.
    /// Reinstalling identical content on every launch is harmless (same bytes, same reload).
    func installBundledSnapshotIfNeeded() async throws -> PipelineResult {
        guard let bundledURL = Bundle.main.url(forResource: "blockerList", withExtension: "json") else {
            throw FilterPipelineError.bundledSnapshotMissing
        }
        let data = try Data(contentsOf: bundledURL)
        let composition = GroupComposition(
            group: .ads,
            sources: [FilterSource(
                filterID: "ads-bundled",
                version: "bundled-snapshot",
                checksumSHA256: Checksum.sha256Hex(of: data),
                data: data
            )]
        )
        return try await install(composition)
    }

    private func loadInstalledFilters() async throws -> [InstalledFilter] {
        let data = try await store.read("installed_filters.json", in: .metadata)
        return try JSONDecoder().decode([InstalledFilter].self, from: data)
    }
}

enum ReloadStrategy {
    case immediate
    case deferred
}

struct PipelineResult {
    var group: FilterGroup
    var compiledRuleCount: Int
    var installedRuleCount: Int
    var compileStatistics: RuleStatistics
    var reloadResults: [ReloadCoordinator.ReloadResult]
}

enum FilterPipelineError: Error {
    case bundledSnapshotMissing
}
