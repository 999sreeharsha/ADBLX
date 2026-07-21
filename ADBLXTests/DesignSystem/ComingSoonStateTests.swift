// ADBLXTests/DesignSystem/ComingSoonStateTests.swift
import Testing
@testable import ADBLX

@Suite("ComingSoonState")
struct ComingSoonStateTests {
    @Test("stores the title and message passed to it")
    func storesContent() {
        let state = ComingSoonState(title: "DNS Protection", message: "Available with Premium.")
        #expect(state.title == "DNS Protection")
        #expect(state.message == "Available with Premium.")
    }
}
