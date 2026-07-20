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

    /// Installs an entire group's composition in one pass: validate every source, compose
    /// them into one rule set, compile once, partition once, write `Compiled/<Group>.json`
    /// once, merge every source into `installed_filters.json`, then reload per
    /// `reloadStrategy`. This is the pipeline's single entry point — see the Sprint 3A
    /// design doc for why Sprint 1/2's one-filter-at-a-time `install` was replaced by this.
    func install(
        _ composition: GroupComposition,
        reloadStrategy: ReloadStrategy = .immediate
    ) async throws -> PipelineResult {
        for source in composition.sources {
            try validator.validate(source.data)
        }

        let composed = try compositionService.compose(composition.sources, group: composition.group)
        let compiled = try await compiler.compile(source: composed.data, group: composition.group)
        let partition = try await partitioner.partition(compiled, group: composition.group)

        let destinationURL = try await store.directoryURL(.compiled)
            .appendingPathComponent("\(partition.group.rawValue.capitalized).json")
        try writer.write(partition.json, to: destinationURL)

        var existingFilters = (try? await loadInstalledFilters()) ?? []
        for source in composition.sources {
            let installedFilter = InstalledFilter(
                id: source.filterID,
                group: composition.group,
                installedVersion: source.version,
                checksumSHA256: source.checksumSHA256,
                lastUpdated: compiled.statistics.lastUpdated,
                ruleCount: compiled.ruleCount
            )
            existingFilters.removeAll { $0.id == source.filterID }
            existingFilters.append(installedFilter)
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

    /// TRANSITIONAL — Sprint 1/2's single-filter entry point. Kept only so
    /// `UpdateCoordinator` keeps compiling until it migrates onto
    /// `install(_:reloadStrategy:)` directly (Sprint 3A Task 10). Delegates to the new
    /// method with a one-source, `.ads` `GroupComposition` — deleted in Task 11 once
    /// `UpdateCoordinator` no longer calls it.
    func install(
        filterID: String,
        source: Data,
        version: String = "bundled-snapshot",
        reloadStrategy: ReloadStrategy = .immediate
    ) async throws -> PipelineResult {
        let composition = GroupComposition(
            group: .ads,
            sources: [FilterSource(
                filterID: filterID,
                version: version,
                checksumSHA256: Checksum.sha256Hex(of: source),
                data: source
            )]
        )
        return try await install(composition, reloadStrategy: reloadStrategy)
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
