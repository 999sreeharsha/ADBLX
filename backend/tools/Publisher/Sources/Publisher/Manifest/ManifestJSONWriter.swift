import Foundation

/// Hand-built JSON serializer for `Manifest`, mirroring `MarkdownGenerator`'s pure
/// string-building approach rather than `JSONEncoder`.
///
/// `JSONEncoder`'s key ordering is not guaranteed to follow struct declaration order on
/// every toolchain (verified empirically on this Swift 6.3 toolchain: repeated runs of
/// `JSONEncoder().encode(manifest)` with `.prettyPrinted` produced different key orders
/// across 4 of 5 runs). The manifest is a versioned public API
/// (`backend/docs/ManifestSpecification.md`) that must serialize with a fixed, deterministic
/// key order — top-level `manifestVersion`, `entries`; per-entry `id`, `name`, `group`,
/// `sourceURL`, `version`, `checksumSHA256`, `ruleCount`, `enabledByDefault`, `premium` — so
/// this writer constructs the JSON text directly instead of relying on Codable's ordering.
enum ManifestJSONWriter {
    static func write(_ manifest: Manifest) -> Data {
        var lines: [String] = []
        lines.append("{")
        lines.append("  \"manifestVersion\": \(jsonString(manifest.manifestVersion)),")

        if manifest.entries.isEmpty {
            lines.append("  \"entries\": []")
        } else {
            lines.append("  \"entries\": [")
            let entryBlocks = manifest.entries.map { entry in
                entryJSON(entry)
            }
            lines.append(entryBlocks.joined(separator: ",\n"))
            lines.append("  ]")
        }

        lines.append("}")
        let text = lines.joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    private static func entryJSON(_ entry: ManifestEntry) -> String {
        var fieldLines: [String] = []
        fieldLines.append("      \"id\": \(jsonString(entry.id)),")
        fieldLines.append("      \"name\": \(jsonString(entry.name)),")
        fieldLines.append("      \"group\": \(jsonString(entry.group)),")
        fieldLines.append("      \"sourceURL\": \(jsonString(entry.sourceURL)),")
        fieldLines.append("      \"version\": \(jsonString(entry.version)),")
        fieldLines.append("      \"checksumSHA256\": \(jsonString(entry.checksumSHA256)),")
        fieldLines.append("      \"ruleCount\": \(entry.ruleCount),")
        fieldLines.append("      \"enabledByDefault\": \(entry.enabledByDefault),")
        fieldLines.append("      \"premium\": \(entry.premium)")

        var block = "    {\n"
        block += fieldLines.joined(separator: "\n")
        block += "\n    }"
        return block
    }

    /// JSON-escapes a string per RFC 8259: quotes, backslashes, and control characters.
    /// Forward slashes are left unescaped (matching the literal example format in
    /// `backend/docs/ManifestSpecification.md`, which is not `JSONEncoder`'s default
    /// `\/`-escaping behavior).
    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}
