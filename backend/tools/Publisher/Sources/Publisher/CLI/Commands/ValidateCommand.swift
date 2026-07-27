import ArgumentParser
import Foundation

struct ValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Verify registry, metadata, and payload consistency. Writes nothing."
    )

    func run() throws {
        print("Loading registry...")
        let (registry, report) = try PublisherPipeline.loadAndValidate()
        print("✓ Loaded \(registry.filters.count) filters")
        print("")
        print("Validating...")
        PublisherPipeline.printReport(report)

        if !report.isValid {
            throw ExitCode(PublisherExitCode.validationFailure.rawValue)
        }
    }
}
