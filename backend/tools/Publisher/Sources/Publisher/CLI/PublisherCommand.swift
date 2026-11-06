import ArgumentParser
import Foundation

enum PublisherPaths {
    static let registryFile = URL(fileURLWithPath: "backend/registry/filters.json")
    static let metadataDirectory = URL(fileURLWithPath: "backend/metadata")
    static let payloadDirectory = URL(fileURLWithPath: "backend/public/filters")
    static let manifestOutput = URL(fileURLWithPath: "backend/public/manifest.json")
    static let manifestSignatureOutput = URL(fileURLWithPath: "backend/public/manifest.json.sig")
    /// Every command runs from the repository root (the paths above are relative to it).
    static let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    static let filterRegistryDocsOutput = URL(fileURLWithPath: "backend/docs/FilterRegistry.md")
}

enum PublisherExitCode: Int32 {
    case success = 0
    case validationFailure = 1
    case fatalError = 2
}

struct PublisherCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publisher",
        abstract: "Registry to manifest publisher for ADBLX's filter distribution backend.",
        subcommands: [
            ValidateCommand.self, GenerateDocsCommand.self, PublishCommand.self, GenerateCommand.self,
            KeygenCommand.self, SignCommand.self, VerifyCommand.self
        ]
    )
}

/// Shared helpers used by every subcommand to avoid duplicating the load/validate sequence.
enum PublisherPipeline {
    static func loadAndValidate() throws -> (registry: Registry, report: ValidationReport) {
        let registry = try RegistryLoader.load(from: PublisherPaths.registryFile)
        let report = try Validator.validate(
            registry: registry,
            metadataDirectory: PublisherPaths.metadataDirectory,
            payloadDirectory: PublisherPaths.payloadDirectory
        )
        return (registry, report)
    }

    static func printReport(_ report: ValidationReport) {
        if report.isValid {
            print("✓ Validation passed")
            return
        }
        print("Validation failed (\(report.errors.count) errors)")
        print("")
        for error in report.errors {
            print("- \(describe(error))")
        }
    }

    private static func describe(_ error: ValidationError) -> String {
        switch error {
        case .emptyRegistry:
            return "Registry is empty (zero registered filters)"
        case .invalidGroup(let id, let found):
            return "Invalid group \"\(found)\" for filter \"\(id)\" (expected: ads|privacy|annoyances|regional)"
        case .duplicateRegistryID(let id):
            return "Duplicate registry id \"\(id)\""
        case .missingMetadata(let id):
            return "Missing backend/metadata/\(id).json"
        case .metadataIDMismatch(let filename, let declaredID):
            return "Metadata file \(filename) declares id \"\(declaredID)\", which doesn't match its filename"
        case .orphanedMetadata(let id):
            return "Metadata file for \"\(id)\" does not correspond to any registered filter"
        case .duplicateMetadata(let id):
            return "Duplicate metadata files for id \"\(id)\""
        case .missingPayload(let id, let expectedPath):
            return "Missing payload for \"\(id)\" (expected at \(expectedPath))"
        }
    }
}
