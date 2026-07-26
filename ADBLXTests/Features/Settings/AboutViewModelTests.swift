// ADBLXTests/Features/Settings/AboutViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("AboutViewModel")
struct AboutViewModelTests {
    @Test("versionDisplay formats as 'v{version} (Build {build})'")
    func versionDisplayFormats() {
        let viewModel = AboutViewModel(shortVersion: "4.2.1", buildNumber: "2024.08")

        #expect(viewModel.versionDisplay == "v4.2.1 (Build 2024.08)")
    }

    @Test("versionDisplay falls back to em dash for missing values")
    func versionDisplayFallsBackGracefully() {
        let viewModel = AboutViewModel(shortVersion: nil, buildNumber: nil)

        #expect(viewModel.versionDisplay == "v— (Build —)")
    }
}
