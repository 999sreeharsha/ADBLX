// ADBLXTests/DesignSystem/ComponentsTests.swift
import Testing
import SwiftUI
@testable import ADBLX

@Suite("PrimaryButton")
struct PrimaryButtonTests {
    @Test("action closure fires exactly once when invoked")
    func actionFires() {
        var callCount = 0
        let button = PrimaryButton(titleKey: "Reload") { callCount += 1 }
        button.action()
        #expect(callCount == 1)
    }
}
