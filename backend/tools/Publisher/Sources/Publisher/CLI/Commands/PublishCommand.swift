import ArgumentParser
import Foundation

struct PublishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Produce backend/public/manifest.json from the registry, metadata, and payloads."
    )

    @Option(name: .customLong("publish-base-url"), help: "Deployment base URL, e.g. https://cdn.adblx.com")
    var publishBaseURL: String

    func run() throws {
        print("Loading registry...")
        let (registry, report) = try PublisherPipeline.loadAndValidate()
        print("✓ Loaded \(registry.filters.count) filters")
        print("")
        print("Validating...")
        PublisherPipeline.printReport(report)

        guard report.isValid else {
            throw ExitCode(PublisherExitCode.validationFailure.rawValue)
        }

        print("")
        print("Generating manifest...")

        let metadataEntries = try MetadataLoader.loadAll(from: PublisherPaths.metadataDirectory)
        let metadataByID = Dictionary(uniqueKeysWithValues: metadataEntries.map { ($0.metadata.id, $0.metadata) })

        var payloadInfoByID: [String: PayloadInfo] = [:]
        for entry in registry.filters {
            let payloadURL = PublisherPaths.payloadDirectory
                .appendingPathComponent(entry.group)
                .appendingPathComponent("\(entry.id).txt")
            payloadInfoByID[entry.id] = try PayloadReader.read(fileAt: payloadURL)
        }

        let manifest = ManifestBuilder.build(
            registry: registry, metadataByID: metadataByID, payloadInfoByID: payloadInfoByID,
            publishBaseURL: publishBaseURL
        )

        let data = ManifestJSONWriter.write(manifest)
        try AtomicFileWriter().write(data, to: PublisherPaths.manifestOutput)

        print("✓ Wrote \(PublisherPaths.manifestOutput.path)")
        print("  Not signed yet: run `publisher sign` before deploying.")
        print("")
        print("Done.")
    }
}
