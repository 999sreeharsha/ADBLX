import XCTest
@testable import Publisher

/// `manifestVersion` is what the app's rollback rule compares, so it must change on every publish
/// that changes the manifest, and only then. See docs/Security/ManifestTrust.md (Rollback).
final class ManifestVersionTests: XCTestCase {
    private func entry(_ id: String, ruleCount: Int = 1) -> ManifestEntry {
        ManifestEntry(
            id: id, name: id, group: "ads", sourceURL: "https://cdn.adblx.com/filters/ads/\(id).txt",
            version: "2026-11-06", checksumSHA256: String(repeating: "a", count: 64), ruleCount: ruleCount,
            enabledByDefault: true, premium: false
        )
    }

    private func assertRefused(
        _ requested: String?, previous: Manifest?, entries: [ManifestEntry],
        _ expected: ManifestVersionError, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try ManifestVersion.resolve(entries: entries, requested: requested, previous: previous), file: file, line: line) {
            XCTAssertEqual($0 as? ManifestVersionError, expected, file: file, line: line)
        }
    }

    func test_theFirstPublishNeedsAVersion() {
        assertRefused(nil, previous: nil, entries: [entry("easylist")], .required)
    }

    func test_theFirstPublishUsesTheGivenVersion() throws {
        XCTAssertEqual(
            try ManifestVersion.resolve(entries: [entry("easylist")], requested: "2026-11-06T09:30:00Z", previous: nil),
            "2026-11-06T09:30:00Z"
        )
    }

    // Fixed width, UTC and "Z" only, so string order is time order on every device.
    func test_aVersionThatIsNotAUTCTimestampIsRefused() {
        for bad in ["2026-11-06", "2026-11-06T09:30:00+05:30", "2026-11-06T09:30Z", "2026-11-06 09:30:00Z",
                    "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "2026-11-06T24:00:00Z", "2026-11-06T09:30:00.5Z"] {
            assertRefused(bad, previous: nil, entries: [entry("easylist")], .malformed(bad))
        }
    }

    // Unchanged inputs must give a byte-identical manifest, so re-running publish changes nothing.
    func test_unchangedEntriesKeepTheCommittedVersion() throws {
        let previous = Manifest(manifestVersion: "2026-11-06T09:30:00Z", entries: [entry("easylist")])

        for requested in [nil, "2026-11-07T00:00:00Z"] {
            XCTAssertEqual(
                try ManifestVersion.resolve(entries: [entry("easylist")], requested: requested, previous: previous),
                "2026-11-06T09:30:00Z"
            )
        }
    }

    // A date-only version can't be published again: the app accepts only the timestamp format.
    func test_unchangedEntriesUnderADateOnlyVersionNeedANewVersion() throws {
        let previous = Manifest(manifestVersion: "2026-11-05", entries: [entry("easylist")])

        assertRefused(nil, previous: previous, entries: [entry("easylist")], .required)
        XCTAssertEqual(
            try ManifestVersion.resolve(entries: [entry("easylist")], requested: "2026-11-06T09:30:00Z", previous: previous),
            "2026-11-06T09:30:00Z"
        )
    }

    func test_changedEntriesNeedAVersion() {
        let previous = Manifest(manifestVersion: "2026-11-06T09:30:00Z", entries: [entry("easylist")])

        assertRefused(nil, previous: previous, entries: [entry("easylist", ruleCount: 2)], .required)
    }

    // Removing a list or changing a flag, not just new list content, must move the version on.
    func test_changedEntriesNeedAVersionLaterThanTheCommittedOne() throws {
        let previous = Manifest(manifestVersion: "2026-11-06T09:30:00Z", entries: [entry("easylist"), entry("easyprivacy")])
        let changed = [entry("easylist")]

        for notLater in ["2026-11-06T09:30:00Z", "2026-11-06T09:29:59Z", "2025-12-31T23:59:59Z"] {
            assertRefused(notLater, previous: previous, entries: changed, .notLater(requested: notLater, committed: "2026-11-06T09:30:00Z"))
        }
        XCTAssertEqual(
            try ManifestVersion.resolve(entries: changed, requested: "2026-11-06T09:30:01Z", previous: previous),
            "2026-11-06T09:30:01Z"
        )
    }

    // The committed manifest today has a date-only version; it counts as that day at midnight UTC.
    func test_aDateOnlyCommittedVersionCountsAsMidnightUTC() throws {
        let previous = Manifest(manifestVersion: "2026-11-05", entries: [entry("easylist")])
        let changed = [entry("easylist", ruleCount: 2)]

        assertRefused("2026-11-05T00:00:00Z", previous: previous, entries: changed, .notLater(requested: "2026-11-05T00:00:00Z", committed: "2026-11-05"))
        XCTAssertEqual(
            try ManifestVersion.resolve(entries: changed, requested: "2026-11-05T00:00:01Z", previous: previous),
            "2026-11-05T00:00:01Z"
        )
    }
}
