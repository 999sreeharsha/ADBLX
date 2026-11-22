import Foundation
import Testing
@testable import ADBLX

/// Safari's settings show an extension's display name, and without one they showed the target
/// name ("ADBLXAdsBlocker"). Every extension is named "<brand> <role>", with the brand from the
/// `BRAND_NAME` build setting (project.yml), so changing the brand renames them all.
@Suite("Extension display names")
struct ExtensionDisplayNameTests {
    /// Bundle name (the target name) to the role Safari should show after the brand.
    private static let roles: [String: String] = [
        "ADBLXAdsBlocker": "Ads",
        "ADBLXPrivacyBlocker": "Privacy",
        "ADBLXAnnoyancesBlocker": "Annoyances",
        "ADBLXRegionalBlocker": "Regional",
        "ADBLXSafariWebExtension": "YouTube",
        "ADBLXPacketTunnel": "DNS Protection",
    ]

    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func embeddedExtensions() throws -> [String: [String: Any]] {
        let plugIns = try #require(Bundle.main.builtInPlugInsURL)
        var infos: [String: [String: Any]] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
        where url.pathExtension == "appex" {
            infos[url.deletingPathExtension().lastPathComponent] = Bundle(url: url)?.infoDictionary ?? [:]
        }
        return infos
    }

    @Test("every embedded extension is named '<brand> <role>', with one brand for all")
    func everyExtensionHasABrandedName() throws {
        let infos = try embeddedExtensions()
        #expect(Set(infos.keys) == Set(Self.roles.keys), "an extension was added or removed; give it a role here")
        var brands = Set<String>()
        for (bundle, role) in Self.roles {
            let name = try #require(infos[bundle]?["CFBundleDisplayName"] as? String, "\(bundle) has no display name")
            #expect(name.hasSuffix(" \(role)"), "\(bundle) is named \(name)")
            brands.insert(String(name.dropLast(role.count + 1)))
        }
        #expect(brands.count == 1, "extensions use different brands: \(brands)")
        let brand = try #require(brands.first)
        #expect(!brand.isEmpty && !brand.contains("$("), "BRAND_NAME didn't expand: \(brand)")
    }

    @Test("the web extension's manifest uses the same name as its bundle")
    func webExtensionManifestName() throws {
        let infos = try embeddedExtensions()
        let displayName = try #require(infos["ADBLXSafariWebExtension"]?["CFBundleDisplayName"] as? String)
        let manifestURL = Self.repoRoot.appendingPathComponent("Extensions/ADBLXSafariWebExtension/Resources/manifest.json")
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        #expect(manifest["name"] as? String == displayName)
    }
}
