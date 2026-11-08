import Foundation
import Testing
@testable import ADBLX

/// A compiler change that ships without a `currentCompilerVersion` bump never reaches existing
/// installs: their rules stay from the old compiler until a list update happens to recompile
/// them. This fails when the compiler's sources change and the stored fingerprint doesn't.
@Suite("Compiler source fingerprint")
struct CompilerSourceFingerprintTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Everything that can change compiled output. Folders are read whole, so a new file in one
    /// is covered without editing this list.
    private static let sourceFolders = [
        "Packages/ADBLXShared/Sources/ADBLXShared/Compiler",
        "ADBLX/Filtering/Compilation"
    ]
    private static let sourceFiles = ["ADBLX/Filtering/Deployment/RulePartitioner.swift"]

    private func compilerSourcePaths() throws -> [String] {
        var paths = Self.sourceFiles
        for folder in Self.sourceFolders {
            let names = try FileManager.default.contentsOfDirectory(atPath: Self.repoRoot.appendingPathComponent(folder).path)
            paths += names.filter { $0.hasSuffix(".swift") }.map { "\(folder)/\($0)" }
        }
        return paths.sorted()
    }

    @Test("The compiler's sources match the fingerprint stored with the current compiler version")
    func sourcesMatchTheFingerprint() throws {
        var hashed = Data()
        for path in try compilerSourcePaths() {
            hashed += Data(path.utf8) + Data([0])
            hashed += try Data(contentsOf: Self.repoRoot.appendingPathComponent(path)) + Data([0])
        }
        let actual = Checksum.sha256Hex(of: hashed)

        #expect(CompiledSources.compilerFingerprint.version == CompiledSources.currentCompilerVersion, """
            compilerFingerprint.version must equal currentCompilerVersion; update both together.
            """)
        #expect(CompiledSources.compilerFingerprint.sha256 == actual, """
            The compiler's sources changed. If the change can alter compiled rules, bump \
            CompiledSources.currentCompilerVersion. Then set compilerFingerprint to \
            (version: <the current version>, sha256: "\(actual)").
            """)
    }

    @Test("The fingerprint covers the files that build the rules")
    func coversTheCompiler() throws {
        let paths = try compilerSourcePaths()
        for file in ["SafariRuleGenerator.swift", "NativeABPRuleCompiler.swift", "RuleCompiler.swift",
                     "CompositionService.swift", "SafariAllowlistCompiler.swift", "RulePartitioner.swift"] {
            #expect(paths.contains { $0.hasSuffix("/\(file)") }, "\(file) isn't fingerprinted")
        }
    }
}
