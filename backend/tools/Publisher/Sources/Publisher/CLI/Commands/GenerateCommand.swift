import ArgumentParser
import Foundation

struct GenerateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Convenience command: validate, then generate-docs, then publish."
    )

    @Option(name: .customLong("publish-base-url"), help: "Deployment base URL, e.g. https://cdn.adblx.com")
    var publishBaseURL: String

    @Option(name: .customLong("manifest-version"), help: "UTC time of this publish, YYYY-MM-DDTHH:MM:SSZ. Required when the manifest changes.")
    var manifestVersion: String?

    func run() throws {
        try ValidateCommand.parse([]).run()
        print("")
        try GenerateDocsCommand.parse([]).run()
        print("")
        var publish = try PublishCommand.parse(
            ["--publish-base-url", publishBaseURL] + (manifestVersion.map { ["--manifest-version", $0] } ?? [])
        )
        try publish.run()
    }
}
