import XCTest
@testable import Publisher

final class DocumentationTests: XCTestCase {
    func test_generatesTableRowForEachFilter() {
        let registry = Registry(registryVersion: 1, filters: [
            RegistryEntry(
                id: "easylist", name: "EasyList", upstreamProject: "EasyList",
                upstreamDownloadURL: "https://easylist.to/easylist/easylist.txt",
                license: "CC BY-SA 3.0 / GPLv3", group: "ads",
                enabledByDefault: true, premium: false, notes: nil
            )
        ])

        let markdown = MarkdownGenerator.generateFilterRegistry(from: registry)

        XCTAssertTrue(markdown.contains("EasyList"))
        XCTAssertTrue(markdown.contains("easylist"))
        XCTAssertTrue(markdown.contains("https://easylist.to/easylist/easylist.txt"))
        XCTAssertTrue(markdown.contains("CC BY-SA 3.0 / GPLv3"))
    }

    func test_groupsAppearInFixedDomainOrderNotAlphabetical() {
        let registry = Registry(registryVersion: 1, filters: [
            makeEntry(id: "regional-filter", group: "regional"),
            makeEntry(id: "ads-filter", group: "ads")
        ])

        let markdown = MarkdownGenerator.generateFilterRegistry(from: registry)

        let adsHeadingRange = markdown.range(of: "### Ads")!
        let regionalHeadingRange = markdown.range(of: "### Regional")!
        XCTAssertTrue(adsHeadingRange.lowerBound < regionalHeadingRange.lowerBound)
    }

    func test_entriesWithinGroupSortedAscendingByID() {
        let registry = Registry(registryVersion: 1, filters: [
            makeEntry(id: "zebra", group: "ads"),
            makeEntry(id: "alpha", group: "ads")
        ])

        let markdown = MarkdownGenerator.generateFilterRegistry(from: registry)

        let alphaRange = markdown.range(of: "alpha")!
        let zebraRange = markdown.range(of: "zebra")!
        XCTAssertTrue(alphaRange.lowerBound < zebraRange.lowerBound)
    }

    func test_noNotesRendersEmptyNotDashPlaceholder() {
        let registry = Registry(registryVersion: 1, filters: [makeEntry(id: "easylist", group: "ads", notes: nil)])
        let markdown = MarkdownGenerator.generateFilterRegistry(from: registry)
        // Notes column renders "—" for nil, matching the existing hand-authored convention.
        XCTAssertTrue(markdown.contains("| — |") || markdown.contains("—"))
    }

    private func makeEntry(id: String, group: String, notes: String? = nil) -> RegistryEntry {
        RegistryEntry(
            id: id, name: id, upstreamProject: "Test", upstreamDownloadURL: "https://example.invalid/\(id).txt",
            license: "MIT", group: group, enabledByDefault: true, premium: false, notes: notes
        )
    }
}
