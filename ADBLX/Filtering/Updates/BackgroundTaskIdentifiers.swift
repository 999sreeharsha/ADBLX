import Foundation

/// The background task identifiers the app registers. Each must also be in
/// `BGTaskSchedulerPermittedIdentifiers` (project.yml, ADR-0014), or registering it fails.
nonisolated enum BackgroundTaskIdentifiers {
    /// `BGAppRefreshTask`: fetch, verify and download.
    static let refresh = "com.ADBLX.ADBLX.filter-refresh"
    /// `BGProcessingTask`: install what the refresh staged.
    static let install = "com.ADBLX.ADBLX.filter-install"
    static let all = [refresh, install]
}
