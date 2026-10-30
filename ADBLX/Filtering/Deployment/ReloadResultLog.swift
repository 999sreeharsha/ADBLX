import Foundation

/// Last reload result per content-blocker extension, for the DEBUG developer section and
/// FR-06 diagnostics. Stores only identifiers, ok/failed and an error domain#code or enum
/// case name — never localized error text.
nonisolated final class ReloadResultLog: @unchecked Sendable {
    static let shared = ReloadResultLog()

    struct Entry: Equatable, Sendable {
        let extensionIdentifier: String
        let outcome: String
        let at: Date
    }

    private let lock = NSLock()
    private var byExtension: [String: Entry] = [:]
    private var order: [String] = []

    func record(extensionIdentifier: String, success: Bool, error: Error?) {
        let entry = Entry(
            extensionIdentifier: extensionIdentifier,
            outcome: success ? "ok" : "failed \(Self.name(of: error))",
            at: Date()
        )
        lock.lock()
        if byExtension[extensionIdentifier] == nil { order.append(extensionIdentifier) }
        byExtension[extensionIdentifier] = entry
        lock.unlock()
    }

    func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { byExtension[$0] }
    }

    private static func name(of error: Error?) -> String {
        guard let error else { return "unknown" }
        if let reloadError = error as? ReloadCoordinator.ReloadError {
            switch reloadError {
            case .timedOut: return "timedOut"
            case .underlying(let inner): return name(of: inner)
            }
        }
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }
}
