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
    func install(filterID: String, source: Data) async throws -> PipelineResult {
        try validator.validate(source)
        let compiled = try await compiler.compile(source: source, filterID: filterID)
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

        // Sprint 1: single-entry overwrite (only the Ads filter is pipeline-managed this
        // sprint). Multi-filter accumulation arrives with the manifest-driven flow in Part 10.
        let installedFilter = InstalledFilter(
            id: filterID,
            group: .ads,
            installedVersion: "bundled-snapshot",
            checksumSHA256: Checksum.sha256Hex(of: source),
            lastUpdated: compiled.statistics.lastUpdated,
            ruleCount: compiled.ruleCount
        )
        let installedFiltersData = try JSONEncoder().encode([installedFilter])
        try await store.writeMetadata(installedFiltersData, filename: "installed_filters.json")

        let statisticsData = try JSONEncoder().encode(compiled.statistics)
        try await store.writeMetadata(statisticsData, filename: "statistics.json")

        let reloadResults = await reloader.reload(extensionIdentifiers: extensionIdentifiers)

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
