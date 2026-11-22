#if DEBUG
import BackgroundTasks
import Foundation
import Network
import UIKit

// Task 2 of docs/superpowers/plans/2026-11-07-background-updates.md: how long the refresh task's
// download and the processing task's compile take on a phone, inside a real background task.
// DEBUG only. It downloads into the download client's scratch folder and compiles into a scratch
// store, so nothing installed changes; the manifest is decoded without verification for the same
// reason (and because no keys were pinned when it was written). Task 6 replaces these handlers with the real ones.

/// The conditions a run was measured under. Each one changes how much CPU and network time iOS
/// gives background work.
nonisolated struct TimingContext: Codable, Equatable, Sendable {
    var trigger: String
    var appState: String
    var lowPowerMode: Bool
    var thermalState: String
    var network: String
    var device: String
}

nonisolated struct TimingStep: Codable, Equatable, Sendable {
    var name: String
    var seconds: Double
    var bytes: Int?
    var rules: Int?
    var error: String?
}

nonisolated struct TimingRun: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case download
        case compile
    }

    var kind: Kind
    var startedAt: Date
    var context: TimingContext
    var steps: [TimingStep]
    /// iOS called the task's expiration handler, or the run was cancelled, before it finished.
    var expired = false

    var totalSeconds: Double { steps.map(\.seconds).reduce(0, +) }

    var summary: String {
        var lines = [
            "\(kind.rawValue) \(Self.seconds(totalSeconds))\(expired ? " EXPIRED" : "")",
            "\(startedAt.formatted(date: .abbreviated, time: .standard)) · \(context.trigger) · \(context.appState)",
            "\(context.device) · \(context.network) · \(context.lowPowerMode ? "Low Power" : "normal power") · thermal \(context.thermalState)"
        ]
        for step in steps {
            var line = "  \(step.name) \(Self.seconds(step.seconds))"
            if let bytes = step.bytes { line += " " + String(format: "%.2f MB", Double(bytes) / 1_000_000) }
            if let rules = step.rules { line += " \(rules) rules" }
            if let error = step.error { line += " error \(error)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }
}

/// The refresh task's work: the manifest, then each list, downloaded and checksummed as the real
/// update does, then discarded.
nonisolated struct DownloadTimer: Sendable {
    let session: HTTPSession
    let manifestURL: URL

    func run(context: TimingContext) async -> TimingRun {
        var run = TimingRun(kind: .download, startedAt: Date(), context: context, steps: [])
        let client = FilterDownloadClient(session: session)
        defer { try? client.cleanupWorkspace() }

        let clock = ContinuousClock()
        var manifest: FilterManifest?
        var manifestStep = TimingStep(name: "manifest", seconds: 0)
        let manifestTime = await clock.measure {
            do {
                let (data, _) = try await session.data(for: URLRequest(url: manifestURL))
                manifestStep.bytes = data.count
                manifest = try JSONDecoder().decode(FilterManifest.self, from: data)
            } catch {
                manifestStep.error = String(describing: type(of: error))
            }
        }
        manifestStep.seconds = manifestTime.seconds
        run.steps.append(manifestStep)

        for entry in manifest?.entries ?? [] {
            if Task.isCancelled {
                run.expired = true
                break
            }
            var step = TimingStep(name: entry.id, seconds: 0)
            let time = await clock.measure {
                do {
                    let downloaded = try await client.download(entry)
                    try Checksum.verify(fileURL: downloaded.tempFileURL, against: downloaded.expectedChecksum)
                    step.bytes = (try? FileManager.default.attributesOfItem(atPath: downloaded.tempFileURL.path)[.size] as? Int) ?? nil
                } catch {
                    step.error = String(describing: error)
                }
            }
            step.seconds = time.seconds
            run.steps.append(step)
        }
        if Task.isCancelled { run.expired = true }
        return run
    }
}

/// The processing task's work: each group compiled from its list into a scratch store, with
/// nothing reloaded.
nonisolated struct CompileTimer: Sendable {
    let sources: [(group: FilterGroup, filterID: String, data: Data)]

    /// The bundled lists, which are the size of a full update.
    static func bundled() -> CompileTimer {
        let lists: [(FilterGroup, String)] = [(.ads, "easylist"), (.privacy, "easyprivacy"), (.annoyances, "fanboy-annoyances")]
        return CompileTimer(sources: lists.compactMap { group, id in
            guard let url = Bundle.main.url(forResource: id, withExtension: "txt"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (group, id, data)
        })
    }

    func run(context: TimingContext) async -> TimingRun {
        var run = TimingRun(kind: .compile, startedAt: Date(), context: context, steps: [])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("timing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = FilterStore(overrideBaseURL: scratch)
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: NativeRuleCompilerAdapter(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: AppCompositionRoot.extensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: AppCompositionRoot.makeReloadCoordinator(),
            gate: FilterTransactionGate()
        )
        let clock = ContinuousClock()
        for source in sources {
            if Task.isCancelled {
                run.expired = true
                break
            }
            var step = TimingStep(name: source.group.rawValue, seconds: 0, bytes: source.data.count)
            let time = await clock.measure {
                do {
                    let composition = GroupComposition(group: source.group, sources: [FilterSource(
                        filterID: source.filterID, version: "timing",
                        checksumSHA256: Checksum.sha256Hex(of: source.data), data: source.data
                    )])
                    step.rules = try await pipeline.install(composition, reloadStrategy: .deferred).compiledRuleCount
                } catch {
                    step.error = String(describing: error)
                }
            }
            step.seconds = time.seconds
            run.steps.append(step)
        }
        return run
    }
}

/// The last `limit` runs, newest first, kept outside the filter directories.
actor TimingLog {
    static let limit = 20
    static let shared = TimingLog(fileURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("background-timing.json"))

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func append(_ run: TimingRun) {
        let all = [run] + runs()
        guard let data = try? JSONEncoder().encode(Array(all.prefix(Self.limit))) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func runs() -> [TimingRun] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([TimingRun].self, from: data)) ?? []
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Registers the two background task identifiers with the timing handlers. Call from
/// `ADBLXApp.init`, before the first scene, as `BGTaskScheduler` requires.
enum BackgroundTimingSpike {
    static let refreshIdentifier = BackgroundTaskIdentifiers.refresh
    static let processingIdentifier = BackgroundTaskIdentifiers.install

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            handle(task, trigger: "BGAppRefreshTask") { context in
                await DownloadTimer(session: AppCompositionRoot.makeHTTPSession(),
                                    manifestURL: AppManifestEndpointProvider().manifestURL).run(context: context)
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            handle(task, trigger: "BGProcessingTask") { context in
                await CompileTimer.bundled().run(context: context)
            }
        }
    }

    /// Submits both requests. To run one at once, pause in the debugger and enter
    /// `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.ADBLX.ADBLX.filter-refresh"]`
    /// (or `filter-install`), then continue.
    static func schedule() throws {
        try BGTaskScheduler.shared.submit(BGAppRefreshTaskRequest(identifier: refreshIdentifier))
        let processing = BGProcessingTaskRequest(identifier: processingIdentifier)
        processing.requiresExternalPower = false
        processing.requiresNetworkConnectivity = false
        try BGTaskScheduler.shared.submit(processing)
    }

    /// The same work in the foreground, for comparison only: foreground numbers overstate what a
    /// background task gets.
    static func runInForeground(_ kind: TimingRun.Kind) async {
        let context = await currentContext(trigger: "foreground button")
        let run: TimingRun
        switch kind {
        case .download:
            run = await DownloadTimer(session: AppCompositionRoot.makeHTTPSession(),
                                      manifestURL: AppManifestEndpointProvider().manifestURL).run(context: context)
        case .compile:
            run = await CompileTimer.bundled().run(context: context)
        }
        await TimingLog.shared.append(run)
    }

    private nonisolated static func handle(
        _ task: BGTask, trigger: String, work: @escaping @Sendable (TimingContext) async -> TimingRun
    ) {
        let box = UncheckedTask(task)
        let job = Task.detached(priority: .background) {
            let context = await currentContext(trigger: trigger)
            await TimingLog.shared.append(await work(context))
            box.task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { job.cancel() }
    }

    nonisolated static func currentContext(trigger: String) async -> TimingContext {
        let appState: String = await MainActor.run {
            switch UIApplication.shared.applicationState {
            case .active: return "foreground"
            case .inactive: return "inactive"
            case .background: return "background"
            @unknown default: return "unknown"
            }
        }
        return TimingContext(
            trigger: trigger, appState: appState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermalName(ProcessInfo.processInfo.thermalState),
            network: await currentNetwork(), device: deviceModel()
        )
    }

    private nonisolated static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Wi-Fi or cellular, from the path the system reports now. The carrier isn't readable, so the
    /// tester notes Jio or Airtel alongside the run.
    private nonisolated static func currentNetwork() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                let name: String
                if path.status != .satisfied { name = "offline" }
                else if path.usesInterfaceType(.wifi) { name = "wifi" }
                else if path.usesInterfaceType(.cellular) { name = "cellular" }
                else { name = "other" }
                continuation.resume(returning: name + (path.isConstrained ? " (Low Data Mode)" : ""))
            }
            monitor.start(queue: DispatchQueue(label: "com.ADBLX.ADBLX.timing-network"))
        }
    }

    private nonisolated static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

private nonisolated final class UncheckedTask: @unchecked Sendable {
    let task: BGTask
    init(_ task: BGTask) { self.task = task }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
#endif
