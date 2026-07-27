import Foundation

enum MarkdownGenerator {
    /// Fixed by the client's `FilterGroup` domain model — never alphabetical, never
    /// `filters.json` array order.
    private static let groupOrder = ["ads", "privacy", "annoyances", "regional"]
    private static let groupDisplayNames = ["ads": "Ads", "privacy": "Privacy", "annoyances": "Annoyances", "regional": "Regional"]

    static func generateFilterRegistry(from registry: Registry) -> String {
        var lines: [String] = []
        lines.append("# ADBLX Filter Registry (v1)")
        lines.append("")
        lines.append("> **Generated file — do not edit by hand.** Produced by the `Publisher`")
        lines.append("> tool's `generate-docs` command from `backend/registry/filters.json`.")
        lines.append("> Future candidates live in `backend/docs/RegistryRoadmap.md`.")
        lines.append("")
        lines.append("## Registered Filters")
        lines.append("")

        for group in groupOrder {
            let entriesInGroup = registry.filters
                .filter { $0.group == group }
                .sorted { $0.id < $1.id }

            lines.append("### \(groupDisplayNames[group] ?? group)")
            lines.append("")

            if entriesInGroup.isEmpty {
                lines.append("No production filter is registered for v1.")
                lines.append("")
                continue
            }

            lines.append("| Field | Value |")
            lines.append("|---|---|")
            for entry in entriesInGroup {
                lines.append("| Display name | \(entry.name) |")
                lines.append("| Internal ID | `\(entry.id)` |")
                lines.append("| Upstream project | \(entry.upstreamProject) |")
                lines.append("| Upstream download URL | \(entry.upstreamDownloadURL) |")
                lines.append("| License | \(entry.license) |")
                lines.append("| ADBLX FilterGroup | \(groupDisplayNames[group] ?? group) |")
                lines.append("| Default enabled (fresh installation) | \(entry.enabledByDefault ? "✅" : "❌") |")
                lines.append("| Premium | \(entry.premium ? "✅" : "❌") |")
                lines.append("| Notes | \(entry.notes ?? "—") |")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
