// ADBLX/Features/Settings/AboutViewModel.swift
import Foundation

/// Sources real app version/build from Bundle.main — About previously showed a
/// static "Version 1.0" string with no backend/bundle wiring at all (Sprint 5B
/// design doc). Takes shortVersion/buildNumber as init parameters (rather than
/// reading Bundle.main internally) so this is testable without depending on the
/// test target's own bundle metadata.
struct AboutViewModel {
    private let shortVersion: String?
    private let buildNumber: String?

    init(shortVersion: String?, buildNumber: String?) {
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
    }

    init(bundle: Bundle = .main) {
        self.init(
            shortVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            buildNumber: bundle.infoDictionary?["CFBundleVersion"] as? String
        )
    }

    var versionDisplay: String {
        "v\(shortVersion ?? "—") (Build \(buildNumber ?? "—"))"
    }
}
