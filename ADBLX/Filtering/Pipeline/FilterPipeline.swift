// ADBLX/Filtering/Pipeline/FilterPipeline.swift
import Foundation

/// Sole orchestrator of the rule pipeline: validate → compile → partition → atomic write →
/// persist metadata → reload. Every other Filtering/ type stays single-purpose; this is the
/// one place that knows the sequence, owns timing, and will own progress/cancellation/retry
/// as those needs arrive.
///
/// Target: main app ONLY.
actor FilterPipeline {
    private let validator: FilterValidator
    private let compiler: RuleCompiler
    private let partitioner: RulePartitioner
    private let store: FilterStore
    private let writer: AtomicRuleWriter
    private let reloader: ReloadCoordinator

    init(
        validator: FilterValidator,
        compiler: RuleCompiler,
        partitioner: RulePartitioner,
        store: FilterStore,
        writer: AtomicRuleWriter,
        reloader: ReloadCoordinator
    ) {
        self.validator = validator
        self.compiler = compiler
        self.partitioner = partitioner
        self.store = store
        self.writer = writer
        self.reloader = reloader
    }

    /// Runs the full pipeline for one filter source and returns a summary of what happened —
    /// callers (ViewModel, logging, future Metrics/UI status) read this one object instead of
    /// interrogating each stage afterward.
    ///
    /// `version`: the value recorded as `InstalledFilter.installedVersion`. Defaults to
    /// `"bundled-snapshot"`, matching Sprint 1's only caller. `UpdateCoordinator`
    /// (Sprint 2) passes the manifest entry's real version — `UpdatePlanner` compares
    /// this value against `FilterManifest.Entry.version` to decide `.keep` vs
    /// `.install` on the next run, so an un-passed (default) version here would make a
    /// manifest-driven install never converge to `.keep`.
    ///
    /// `reloadStrategy`: `.immediate` (default) reloads the affected extensions before
    /// returning, matching Sprint 1 behavior exactly. `.deferred` skips the reload —
    /// used by `UpdateCoordinator` (Sprint 2) so a multi-filter batch triggers exactly
    /// one reload after every filter in the batch has installed successfully, rather
    /// than one reload per filter.
    func install(
        filterID: String,
        source: Data,
        version: String = "bundled-snapshot",
        reloadStrategy: ReloadStrategy = .immediate
    ) async throws -> PipelineResult {
        try validator.validate(source)
        let compiled = try await compiler.compile(source: source, group: .ads)
        let partitions = try await partitioner.partition(compiled)

        var installedRuleCount = 0
        var extensionIdentifiers: [String] = []
        for partition in partitions {
            let destinationURL = try await store.directoryURL(.compiled)
                .appendingPathComponent("\(partition.group.rawValue.capitalized).json")
            try writer.write(partition.json, to: destinationURL)
            installedRuleCount += partition.ruleCount
            extensionIdentifiers.append(partition.extensionIdentifier)
        }

        // Sprint 2: accumulate rather than overwrite — read the existing list, replace
        // this filterID's entry if present (by id) or append it, write the merged array
        // back. Compiled/<Group>.json above is still one file per group, still
        // overwritten per call — true multi-source rule composition per group is
        // deferred (see Sprint 2 design doc, "Known dependency on Sprint 1's
        // single-entry metadata overwrite").
        let installedFilter = InstalledFilter(
            id: filterID,
            group: .ads,
            installedVersion: version,
            checksumSHA256: Checksum.sha256Hex(of: source),
            lastUpdated: compiled.statistics.lastUpdated,
            ruleCount: compiled.ruleCount
        )
        var existingFilters = (try? await loadInstalledFilters()) ?? []
        existingFilters.removeAll { $0.id == filterID }
        existingFilters.append(installedFilter)
        let installedFiltersData = try JSONEncoder().encode(existingFilters)
        try await store.writeMetadata(installedFiltersData, filename: "installed_filters.json")

        let statisticsData = try JSONEncoder().encode(compiled.statistics)
        try await store.writeMetadata(statisticsData, filename: "statistics.json")

        let reloadResults: [ReloadCoordinator.ReloadResult]
        if reloadStrategy == .immediate {
            reloadResults = await reloader.reload(extensionIdentifiers: extensionIdentifiers)
        } else {
            reloadResults = []
        }

        return PipelineResult(
            filterID: filterID,
            compiledRuleCount: compiled.ruleCount,
            installedRuleCount: installedRuleCount,
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
        return try await install(filterID: "ads-bundled", source: data)
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
    var filterID: String
    var compiledRuleCount: Int
    var installedRuleCount: Int
    var compileStatistics: RuleStatistics
    var reloadResults: [ReloadCoordinator.ReloadResult]
}

enum FilterPipelineError: Error {
    case bundledSnapshotMissing
}
