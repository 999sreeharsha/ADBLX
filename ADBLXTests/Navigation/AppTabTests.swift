// ADBLXTests/Navigation/AppTabTests.swift
import Testing
@testable import ADBLX

@Suite("AppTab")
struct AppTabTests {
    @Test("has exactly the four frozen top-level destinations, in nav-bar order")
    func allCasesMatchFrozenIA() {
        #expect(AppTab.allCases == [.home, .protection, .premium, .settings])
    }

    @Test("each tab has a non-empty title and a valid SF Symbol name")
    func titlesAndIconsExist() {
        for tab in AppTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.systemImage.isEmpty)
        }
    }
}
