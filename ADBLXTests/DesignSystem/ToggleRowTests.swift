// ADBLXTests/DesignSystem/ToggleRowTests.swift
import Testing
import SwiftUI
@testable import ADBLX

@Suite("ToggleRow")
struct ToggleRowTests {
    @Test("binding reflects the value passed in and toggling flips it")
    func bindingRoundTrips() {
        var value = false
        let binding = Binding(get: { value }, set: { value = $0 })
        _ = ToggleRow(titleKey: "Ads", subtitleKey: "Blocks display and video ads", isOn: binding)

        binding.wrappedValue.toggle()

        #expect(value == true)
    }
}
