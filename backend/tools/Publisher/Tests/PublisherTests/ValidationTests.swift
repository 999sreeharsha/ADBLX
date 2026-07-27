import XCTest
@testable import Publisher

final class ValidationTests: XCTestCase {
    func test_emptyRegistry() {
        let registry = Registry(registryVersion: 1, filters: [])
        let errors = Validator.validateRegistry(registry)
        XCTAssertEqual(errors, [.emptyRegistry])
    }

    func test_invalidGroup() {
        let entry = makeEntry(id: "easylist", group: "advertisements")
        let registry = Registry(registryVersion: 1, filters: [entry])
        let errors = Validator.validateRegistry(registry)
        XCTAssertEqual(errors, [.invalidGroup(id: "easylist", found: "advertisements")])
    }

    func test_duplicateRegistryID() {
        let entryA = makeEntry(id: "easylist", group: "ads")
        let entryB = makeEntry(id: "easylist", group: "privacy")
        let registry = Registry(registryVersion: 1, filters: [entryA, entryB])
        let errors = Validator.validateRegistry(registry)
        XCTAssertEqual(errors, [.duplicateRegistryID(id: "easylist")])
    }

    func test_collectsMultipleIndependentErrors() {
        let entryA = makeEntry(id: "easylist", group: "advertisements")
        let entryB = makeEntry(id: "easylist", group: "privacy")
        let registry = Registry(registryVersion: 1, filters: [entryA, entryB])
        let errors = Validator.validateRegistry(registry)

        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.contains(.invalidGroup(id: "easylist", found: "advertisements")))
        XCTAssertTrue(errors.contains(.duplicateRegistryID(id: "easylist")))
    }

    func test_validRegistryProducesNoErrors() {
        let registry = Registry(registryVersion: 1, filters: [makeEntry(id: "easylist", group: "ads")])
        XCTAssertEqual(Validator.validateRegistry(registry), [])
    }

    func test_sortOrderIsCategoryThenID() {
        let unsorted: [ValidationError] = [
            .invalidGroup(id: "zeta", found: "bad"),
            .duplicateRegistryID(id: "alpha"),
            .emptyRegistry
        ]
        XCTAssertEqual(unsorted.sorted(), [.emptyRegistry, .duplicateRegistryID(id: "alpha"), .invalidGroup(id: "zeta", found: "bad")])
    }

    private func makeEntry(id: String, group: String) -> RegistryEntry {
        RegistryEntry(
            id: id, name: id, upstreamProject: "Test", upstreamDownloadURL: "https://example.invalid/\(id).txt",
            license: "MIT", group: group, enabledByDefault: true, premium: false, notes: nil
        )
    }
}
