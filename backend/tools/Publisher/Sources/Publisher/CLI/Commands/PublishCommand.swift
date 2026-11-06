import ArgumentParser
import Foundation

struct PublishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Produce backend/public/manifest.json from the registry, metadata, and payloads."
    )

    @Option(name: .customLong("publish-base-url"), help: "Deployment base URL, e.g. https://cdn.adblx.com")
    var publishBaseURL: String

    @Option(name: .customLong("manifest-version"), help: "UTC time of this publish, YYYY-MM-DDTHH:MM:SSZ. Required when the manifest changes; ignored when it doesn't.")
    var manifestVersion: String?

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

        let entries = ManifestBuilder.entries(
            registry: registry, metadataByID: metadataByID, payloadInfoByID: payloadInfoByID,
            publishBaseURL: publishBaseURL
        )
        let committed = (try? Data(contentsOf: PublisherPaths.manifestOutput)).flatMap {
            try? JSONDecoder().decode(Manifest.self, from: $0)
        }
        let version: String
        do {
            version = try ManifestVersion.resolve(entries: entries, requested: manifestVersion, previous: committed)
        } catch let error as ManifestVersionError {
            print("✗ \(error)")
            throw ExitCode(PublisherExitCode.validationFailure.rawValue)
        }
        let manifest = Manifest(manifestVersion: version, entries: entries)

        let data = ManifestJSONWriter.write(manifest)
        try AtomicFileWriter().write(data, to: PublisherPaths.manifestOutput)

        print("✓ Wrote \(PublisherPaths.manifestOutput.path)")
        print("  Not signed yet: run `publisher sign` before deploying.")
        print("")
        print("Done.")
    }
}
