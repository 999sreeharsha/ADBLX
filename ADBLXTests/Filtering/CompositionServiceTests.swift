// ADBLXTests/Filtering/CompositionServiceTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("JSONArrayCompositionService")
struct CompositionServiceTests {
    private func rule(_ urlFilter: String) -> Data {
        Data("[{\"trigger\":{\"url-filter\":\"\(urlFilter)\"},\"action\":{\"type\":\"block\"}}]".utf8)
    }

    @Test("single source composes into a ComposedRules with matching rule count")
    func singleSourceComposes() throws {
        let source = FilterSource(filterID: "easylist", version: "v1", checksumSHA256: "a", data: rule("a.*"))
        let service = JSONArrayCompositionService()

        let composed = try service.compose([source], group: .ads)

        #expect(composed.group == .ads)
        #expect(composed.sourceCount == 1)
        #expect(composed.ruleCount == 1)
        let decoded = try JSONSerialization.jsonObject(with: composed.data) as? [Any]
        #expect(decoded?.count == 1)
    }

    @Test("multiple sources merge into one array in source order")
    func multipleSourcesMergeInOrder() throws {
        let easyList = FilterSource(filterID: "easylist", version: "v1", checksumSHA256: "a", data: rule("a.*"))
        let peterLowe = FilterSource(filterID: "peter-lowe", version: "v1", checksumSHA256: "b", data: rule("b.*"))
        let service = JSONArrayCompositionService()

        let composed = try service.compose([easyList, peterLowe], group: .ads)

        #expect(composed.sourceCount == 2)
        #expect(composed.ruleCount == 2)
        let decoded = try JSONSerialization.jsonObject(with: composed.data) as? [[String: Any]]
        let firstFilter = (decoded?.first?["trigger"] as? [String: Any])?["url-filter"] as? String
        let secondFilter = (decoded?.last?["trigger"] as? [String: Any])?["url-filter"] as? String
        #expect(firstFilter == "a.*")
        #expect(secondFilter == "b.*")
    }

    @Test("composing the same ordered sources twice produces byte-identical output")
    func composingTwiceIsDeterministic() throws {
        let easyList = FilterSource(filterID: "easylist", version: "v1", checksumSHA256: "a", data: rule("a.*"))
        let peterLowe = FilterSource(filterID: "peter-lowe", version: "v1", checksumSHA256: "b", data: rule("b.*"))
        let service = JSONArrayCompositionService()

        let first = try service.compose([easyList, peterLowe], group: .ads)
        let second = try service.compose([easyList, peterLowe], group: .ads)

        #expect(first.data == second.data)
    }

    @Test("throws invalidSource naming the offending filterID when a source isn't a JSON array")
    func throwsOnInvalidSource() {
        let bad = FilterSource(filterID: "corrupt", version: "v1", checksumSHA256: "a", data: Data("not json".utf8))
        let service = JSONArrayCompositionService()

        #expect(throws: CompositionServiceError.invalidSource(filterID: "corrupt")) {
            _ = try service.compose([bad], group: .ads)
        }
    }
}
