import Foundation

/// The launch-time update: runs the coordinator when the throttle allows.
enum AutomaticUpdate {
    /// A rejected manifest advances the throttle like a success. Otherwise a bad publish or a
    /// missing signature would make every launch on every phone fetch the manifest again for
    /// as long as it lasted (ManifestTrust.md, "When verification fails"). Other failures stay
    /// retryable on the next launch.
    static func runIfDue(coordinator: UpdateCoordinator, throttle: UpdateThrottle, now: Date = Date()) async {
        guard await throttle.shouldRun(now: now) else { return }
        do {
            let result = try await coordinator.run()
            switch result {
            case .upToDate, .updated:
                try await throttle.recordSuccess(at: now)
            case .rolledBack, .rollbackFailed:
                break
            }
        } catch is ManifestRejection {
            try? await throttle.recordSuccess(at: now)
        } catch {
            // Failed launches remain retryable on the next launch.
        }
    }
}
