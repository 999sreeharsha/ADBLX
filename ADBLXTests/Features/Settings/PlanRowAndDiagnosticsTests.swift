import Testing
import Foundation
@testable import ADBLX

@Suite("Settings Plan row text")
struct PlanRowTextTests {
    private let end = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("each PlanState maps to its row text", arguments: [
        (PlanState.premium(.subscription), "Premium"),
        (PlanState.premium(.lifetime), "Lifetime"),
        (PlanState.trial(daysRemaining: 9, endsAt: Date(timeIntervalSince1970: 2_000_000_000)), "Free trial · 9 days left"),
        (PlanState.trial(daysRemaining: 1, endsAt: Date(timeIntervalSince1970: 2_000_000_000)), "Free trial · 1 day left"),
        (PlanState.trialExpired(endedAt: Date(timeIntervalSince1970: 2_000_000_000)), "Trial ended"),
        (PlanState.free, "Free")
    ])
    func rowText(state: PlanState, expected: String) {
        #expect(PlanStateDisplay.planRowText(for: state) == expected)
    }
}

@Suite("Developer diagnostics")
struct DeveloperDiagnosticsTests {
    @Test("manifest rejections show the consecutive count and the last reason's case name only")
    func manifestRejectionDescription() {
        let log = ManifestRejectionLog()
        #expect(DeveloperDiagnostics.manifestRejections(log) == "none")

        log.recordRejection(.signature)
        log.recordRejection(.belowMinimum)
        #expect(DeveloperDiagnostics.manifestRejections(log) == "2 in a row, last belowMinimum")
    }

    @Test("entitlement case names carry no dates")
    func caseNames() {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(DeveloperDiagnostics.caseName(of: .free) == "free")
        #expect(DeveloperDiagnostics.caseName(of: .trial(expiresAt: date)) == "trial")
        #expect(DeveloperDiagnostics.caseName(of: .monthly(expiresAt: date)) == "monthly")
        #expect(DeveloperDiagnostics.caseName(of: .annual(expiresAt: date)) == "annual")
        #expect(DeveloperDiagnostics.caseName(of: .lifetime) == "lifetime")
    }

    @Test("per-group rule counts: one entry per group in fixed order, group-level count, 0 when absent")
    func groupCounts() {
        let filters = [
            InstalledFilter(id: "easylist", group: .ads, installedVersion: "1", checksumSHA256: "x", lastUpdated: Date(), ruleCount: 73_294),
            InstalledFilter(id: "easyprivacy", group: .privacy, installedVersion: "1", checksumSHA256: "x", lastUpdated: Date(), ruleCount: 55_749)
        ]
        let counts = DeveloperDiagnostics.groupRuleCounts(from: filters)
        #expect(counts.map(\.group) == [.ads, .privacy, .annoyances, .regional])
        #expect(counts.map(\.ruleCount) == [73_294, 55_749, 0, 0])
    }

    @Test("Recompile all rebuilds every installed group from its stored list")
    func recompileAll() async throws {
        let store = FilterStore.temporary()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store, allowlistStore: AllowlistStore(store: store))
        let data = Data("##.cookie-bar\nexample.com##.promo".utf8)
        _ = try await pipeline.install(GroupComposition(group: .annoyances, sources: [
            FilterSource(filterID: "fanboy-annoyances", version: "1", checksumSHA256: Checksum.sha256Hex(of: data), data: data)
        ]), reloadStrategy: .deferred)
        // Stale output, as left on disk by an older compiler.
        try await store.writeCompiledForTesting(Data("[]".utf8), filename: "Annoyances.json")

        let summary = await DeveloperDiagnostics.recompileAll(pipeline: pipeline)

        #expect(summary == "annoyances=2")
        let rules = try JSONSerialization.jsonObject(with: try await store.read("Annoyances.json", in: .compiled)) as? [Any]
        #expect(rules?.count == 2)
    }
}

private extension FilterStore {
    func writeCompiledForTesting(_ data: Data, filename: String) throws {
        try data.write(to: try directoryURL(.compiled).appendingPathComponent(filename))
    }
}

@Suite("ReloadResultLog", .serialized)
struct ReloadResultLogTests {
    @Test("keeps only the latest result per extension, with an error name and no error text")
    func latestPerExtension() {
        let log = ReloadResultLog()
        log.record(extensionIdentifier: "a", success: false, error: ReloadCoordinator.ReloadError.timedOut)
        log.record(extensionIdentifier: "a", success: true, error: nil)
        log.record(extensionIdentifier: "b", success: false, error: NSError(domain: "NSCocoaErrorDomain", code: 4099))

        let entries = log.entries()
        #expect(entries.map(\.extensionIdentifier) == ["a", "b"])
        #expect(entries[0].outcome == "ok")
        #expect(entries[1].outcome == "failed NSCocoaErrorDomain#4099")
    }
}
