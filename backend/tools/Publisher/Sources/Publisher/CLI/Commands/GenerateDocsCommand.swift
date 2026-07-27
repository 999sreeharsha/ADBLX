import ArgumentParser
import Foundation

struct GenerateDocsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-docs",
        abstract: "Regenerate backend/docs/FilterRegistry.md from backend/registry/filters.json."
    )

    func run() throws {
        print("Loading registry...")
        let registry = try RegistryLoader.load(from: PublisherPaths.registryFile)
        print("✓ Loaded \(registry.filters.count) filters")
        print("")
        print("Generating documentation...")

        let markdown = MarkdownGenerator.generateFilterRegistry(from: registry)
        try AtomicFileWriter().write(Data(markdown.utf8), to: PublisherPaths.filterRegistryDocsOutput)

        print("✓ Wrote \(PublisherPaths.filterRegistryDocsOutput.path)")
    }
}
