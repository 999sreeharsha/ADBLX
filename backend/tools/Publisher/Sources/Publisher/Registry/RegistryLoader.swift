import Foundation

enum RegistryLoaderError: Error, Equatable {
    case fileNotReadable(path: String)
    case malformedJSON(String)
    case unsupportedRegistryVersion(found: Int, supported: Int)
}

enum RegistryLoader {
    static let supportedRegistryVersion = 1

    static func load(from url: URL) throws -> Registry {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RegistryLoaderError.fileNotReadable(path: url.path)
        }

        let registry: Registry
        do {
            registry = try JSONDecoder().decode(Registry.self, from: data)
        } catch {
            throw RegistryLoaderError.malformedJSON("\(error)")
        }

        guard registry.registryVersion == supportedRegistryVersion else {
            throw RegistryLoaderError.unsupportedRegistryVersion(
                found: registry.registryVersion,
                supported: supportedRegistryVersion
            )
        }

        return registry
    }
}
