import Foundation

enum MetadataLoaderError: Error, Equatable {
    case directoryNotReadable(path: String)
    case malformedJSON(filename: String, message: String)
}

enum MetadataLoader {
    /// Returns one entry per `.json` file in `directoryURL`, paired with its filename.
    /// Deliberately does not deduplicate or cross-check filename vs. declared `id` —
    /// that's `Validator`'s job, which needs both pieces of information to report
    /// `metadataIDMismatch`/`duplicateMetadata` precisely.
    static func loadAll(from directoryURL: URL) throws -> [(filename: String, metadata: FilterMetadata)] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil
            )
        } catch {
            throw MetadataLoaderError.directoryNotReadable(path: directoryURL.path)
        }

        var results: [(filename: String, metadata: FilterMetadata)] = []
        for fileURL in contents where fileURL.pathExtension == "json" {
            let data = try Data(contentsOf: fileURL)
            do {
                let metadata = try JSONDecoder().decode(FilterMetadata.self, from: data)
                results.append((filename: fileURL.lastPathComponent, metadata: metadata))
            } catch {
                throw MetadataLoaderError.malformedJSON(
                    filename: fileURL.lastPathComponent, message: "\(error)"
                )
            }
        }
        return results
    }
}
