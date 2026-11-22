import Foundation

/// Start-time backstop for the packet tunnel: the app stops the tunnel when entitlement is
/// lost, but it may not be running at the moment of expiry, so the tunnel extension also
/// refuses to start when `entitlement.json` says the plan is free or its `validUntil` has
/// passed. One file read and one date comparison — no work beyond that belongs in the extension.
public enum TunnelEntitlementGuard {
    public enum Verdict: Equatable, Sendable {
        case allowed
        /// Premium, but `validUntil` has passed.
        case deniedExpired
        /// The record says the plan is free (SEC-13).
        case deniedNotEntitled
    }

    /// A missing or unreadable record is `.allowed`: the app already gated the start on live
    /// StoreKit entitlement, and failing closed here would brick a legitimate first start
    /// racing the first publish. A readable record denies when it is free or expired.
    public static func check(
        baseAppGroupURL: URL? = WebExtensionAppGroupPaths.appGroupContainerURL(),
        now: Date = Date()
    ) -> Verdict {
        guard let baseAppGroupURL,
              let url = WebExtensionAppGroupPaths.entitlementFileURL(base: baseAppGroupURL),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(WebExtensionPersistedEntitlement.self, from: data) else {
            return .allowed
        }
        if record.isEntitled(at: now) { return .allowed }
        return record.state == .free ? .deniedNotEntitled : .deniedExpired
    }
}
