import Foundation

/// The rule count a content-blocker handler logs, read from the `<Group>.sources.json` sidecar
/// beside the rules. Decoding the rules would exceed the extension's memory limit of about
/// 6 MB, so a missing or unreadable sidecar gives "unknown" and never falls back to that.
nonisolated enum CompiledRuleCount {
    private struct Sidecar: Decodable {
        let ruleCount: Int
    }

    static func label(forRulesAt rulesURL: URL) -> String {
        let sidecarURL = rulesURL.deletingPathExtension().appendingPathExtension("sources.json")
        guard let data = try? Data(contentsOf: sidecarURL),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) else {
            return "unknown"
        }
        return String(sidecar.ruleCount)
    }
}
