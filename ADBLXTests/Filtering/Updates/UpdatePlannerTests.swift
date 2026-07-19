// ADBLXTests/Filtering/Updates/UpdatePlannerTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("UpdatePlanner")
struct UpdatePlannerTests {
    private func entry(
        id: String, group: FilterGroup = .ads, version: String = "2026-07-18",
        checksum: String = "checksum-a", premium: Bool = false
    ) -> FilterManifest.Entry {
        FilterManifest.Entry(
            id: id, name: id, group: group,
            sourceURL: URL(string: "https://example.com/\(id).txt")!,
            version: version, checksumSHA256: checksum, ruleCount: 10,
            enabledByDefault: true, premium: premium
        )
    }

    private func installed(
        id: String, group: FilterGroup = .ads, version: String = "2026-07-18",
        checksum: String = "checksum-a"
    ) -> InstalledFilter {
        InstalledFilter(
            id: id, group: group, installedVersion: version, checksumSHA256: checksum,
            lastUpdated: Date(timeIntervalSince1970: 1_752_000_000), ruleCount: 10
        )
    }

    @Test("new manifest entry with no installed counterpart produces .install")
    func newEntryProducesInstall() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easylist")])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [.install(entry(id: "easylist"))])
    }

    @Test("unchanged installed entry produces .keep")
    func unchangedEntryProducesKeep() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easylist")])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [installed(id: "easylist")])
        #expect(plan.actions == [.keep(filterID: "easylist")])
    }

    @Test("changed version on an installed entry produces .install")
    func changedVersionProducesInstall() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easylist", version: "2026-07-19")])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [installed(id: "easylist", version: "2026-07-18")])
        #expect(plan.actions == [.install(entry(id: "easylist", version: "2026-07-19"))])
    }

    @Test("changed checksum on an installed entry produces .install")
    func changedChecksumProducesInstall() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easylist", checksum: "checksum-b")])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [installed(id: "easylist", checksum: "checksum-a")])
        #expect(plan.actions == [.install(entry(id: "easylist", checksum: "checksum-b"))])
    }

    @Test("installed filter absent from the manifest produces .remove")
    func removedFromManifestProducesRemove() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [installed(id: "fanboy")])
        #expect(plan.actions == [.remove(filterID: "fanboy")])
    }

    @Test("never-installed premium entry produces .skipPremium, not .keep")
    func neverInstalledPremiumProducesSkipPremium() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "premium-list", premium: true)])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [.skipPremium(entry(id: "premium-list", premium: true))])
    }

    @Test("already-installed premium entry with a version change still produces .install")
    func installedPremiumEntryStillUpdates() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "premium-list", version: "v2", premium: true)])
        let plan = UpdatePlanner.plan(
            manifest: manifest,
            installed: [installed(id: "premium-list", version: "v1")]
        )
        #expect(plan.actions == [.install(entry(id: "premium-list", version: "v2", premium: true))])
    }

    @Test("non-.ads group entry produces .unsupportedGroup")
    func nonAdsGroupProducesUnsupportedGroup() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easyprivacy", group: .privacy)])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [.unsupportedGroup(entry(id: "easyprivacy", group: .privacy))])
    }

    @Test("second .ads entry needing install in the same plan produces .groupConflict")
    func secondAdsInstallInSamePlanProducesGroupConflict() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [
            entry(id: "easylist"),
            entry(id: "peter-lowe", checksum: "checksum-c"),
        ])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [
            .install(entry(id: "easylist")),
            .groupConflict(entry(id: "peter-lowe", checksum: "checksum-c")),
        ])
    }

    @Test("empty manifest and empty installed list produces an empty plan")
    func emptyInputsProduceEmptyPlan() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions.isEmpty)
    }
}
