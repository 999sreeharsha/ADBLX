// ADBLX/Features/Home/HomeViewModel.swift
import Observation

@Observable
final class HomeViewModel {
    private let service: HomeService

    var status: HomeStatus?
    var isLoading = false

    init(service: HomeService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        status = await service.fetchStatus()
        isLoading = false
    }

    /// Closes the cold-launch race between ContentBlockerBootstrap's detached
    /// install Task and this view's first load (ABORT review finding, Sprint 5A
    /// plan Task 6 Step 9): if the first load lands before bootstrap's write,
    /// isProtectionEnabled is false with 0 rules — genuinely indistinguishable
    /// from a real empty state at the type level, so this retries a bounded
    /// number of times with a short delay rather than leaving the user stuck on
    /// a stale "not enabled" reading after a normal fresh-install launch.
    func loadWithBootstrapRetry(maxAttempts: Int = 3, retryDelay: Duration = .milliseconds(500)) async {
        for attempt in 1...maxAttempts {
            await load()
            if status?.isProtectionEnabled == true { return }
            if attempt < maxAttempts {
                try? await Task.sleep(for: retryDelay)
            }
        }
    }
}
