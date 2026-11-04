import XCTest
@testable import Publisher

/// Pins the shape of the manifest that is actually committed, so a stale or hand-edited
/// `backend/public/manifest.json` (e.g. one generated before `aa64fef` dropped
/// `/backend/public` from `sourceURL`) cannot ship. `publish-pages.sh` copies
/// `backend/public/` verbatim to the root of the Pages site, so the live URL of a payload
/// is `<base>/filters/<group>/<id>.txt`.
final class CommittedManifestTests: XCTestCase {
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    private func loadManifest() throws -> [[String: Any]] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("backend/public/manifest.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["entries"] as? [[String: Any]])
    }

    func testEverySourceURLHasTheServedShapeAndNoRepoPath() throws {
        let entries = try loadManifest()
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let id = try XCTUnwrap(entry["id"] as? String)
            let group = try XCTUnwrap(entry["group"] as? String)
            let sourceURL = try XCTUnwrap(entry["sourceURL"] as? String)
            XCTAssertTrue(sourceURL.hasPrefix("https://"), id)
            XCTAssertTrue(sourceURL.hasSuffix("/filters/\(group)/\(id).txt"), "\(id): \(sourceURL)")
            XCTAssertFalse(sourceURL.contains("backend/public"), "\(id): \(sourceURL)")
        }
    }

    func testEveryEntryPointsAtAPublishedPayloadAndAllShareOneBase() throws {
        let entries = try loadManifest()
        var bases = Set<String>()
        for entry in entries {
            let id = try XCTUnwrap(entry["id"] as? String)
            let group = try XCTUnwrap(entry["group"] as? String)
            let sourceURL = try XCTUnwrap(entry["sourceURL"] as? String)
            bases.insert(String(sourceURL.dropLast("/filters/\(group)/\(id).txt".count)))
            let payload = repoRoot.appendingPathComponent("backend/public/filters/\(group)/\(id).txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path), id)
        }
        XCTAssertEqual(bases.count, 1, "entries must share one publishBaseURL: \(bases)")
    }
}
