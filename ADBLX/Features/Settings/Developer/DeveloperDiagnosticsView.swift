#if DEBUG
import SwiftUI
import UIKit

/// DEBUG-only screen for device testing of entitlement and filter state. Not localized and
/// not shipped: it is compiled out of release builds.
struct DeveloperDiagnosticsView: View {
    @Environment(PlanStateModel.self) private var planStateModel: PlanStateModel?
    @State private var diagnostics: DeveloperDiagnostics?
    @State private var isRecompiling = false
    @State private var recompileSummary: String?
    @State private var tunnel = DNSTunnelDiagnosticsModel(transport: SystemDNSTunnelDiagnosticsTransport())
    @State private var timingRuns: [TimingRun] = []
    @State private var timingStatus: String?

    var body: some View {
        List {
            Section("Plan") {
                row("PlanState", planStateModel.map { describe($0.state) } ?? "no model")
                row("Entitlement", diagnostics?.entitlementCase ?? "…")
                row("validUntil", diagnostics?.validUntil.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "none")
                row("Trial", diagnostics?.trial ?? "…")
            }
            Section {
                Picker("Show as", selection: overrideBinding) {
                    Text(verbatim: "Real plan").tag(DebugPlanOverride?.none)
                    ForEach(DebugPlanOverride.allCases) { option in
                        Text(verbatim: option.label).tag(DebugPlanOverride?.some(option))
                    }
                }
            } header: {
                Text(verbatim: "Override PlanState")
            } footer: {
                Text(verbatim: "Changes what Home and Premium display until the app relaunches. "
                     + "Entitlement and filters still follow the real plan.")
            }
            Section {
                Toggle(isOn: Binding(
                    get: { tunnel.passthrough },
                    set: { on in Task { await tunnel.setPassthrough(on) } }
                )) {
                    Text(verbatim: "Pass-through (empty blocklist)")
                }
                ForEach(tunnel.rows, id: \.label) { row($0.label, $0.value) }
                if let status = tunnel.status {
                    Text(verbatim: status).foregroundStyle(.secondary)
                }
                Button { Task { await tunnel.refresh() } } label: { Text(verbatim: "Refresh counts") }
                Button { Task { await tunnel.reset() } } label: { Text(verbatim: "Reset counts") }
            } header: {
                Text(verbatim: "DNS tunnel")
            } footer: {
                Text(verbatim: "Counts only. Pass-through forwards every query and blocks none, to tell a tunnel "
                     + "fault from a list that blocks too much. It resets when the tunnel restarts.")
            }
            Section("StoreKit") {
                row("Paid product", diagnostics?.paidProductID ?? "none")
                row("Verified", "\(diagnostics?.verifiedCount ?? 0)")
                row("Unverified", diagnostics.map { $0.unverifiedErrors.isEmpty ? "0" : $0.unverifiedErrors.joined(separator: ", ") } ?? "0")
            }
            Section("Compiled rules") {
                ForEach(diagnostics?.groupCounts ?? [], id: \.group) { count in
                    row(count.group.rawValue, "\(count.ruleCount)")
                }
            }
            Section("Filter updates") {
                row("Manifest rejections", diagnostics?.manifestRejections ?? "none")
            }
            Section {
                Button {
                    do {
                        try BackgroundTimingSpike.schedule()
                        timingStatus = "Both requests submitted"
                    } catch {
                        timingStatus = "Submit failed: \(error)"
                    }
                } label: { Text(verbatim: "Schedule both background tasks") }
                Button {
                    timingStatus = "Running download in the foreground…"
                    Task { await BackgroundTimingSpike.runInForeground(.download); await loadTiming(); timingStatus = nil }
                } label: { Text(verbatim: "Download now (foreground, comparison only)") }
                Button {
                    timingStatus = "Running compile in the foreground…"
                    Task { await BackgroundTimingSpike.runInForeground(.compile); await loadTiming(); timingStatus = nil }
                } label: { Text(verbatim: "Compile now (foreground, comparison only)") }
                if let timingStatus {
                    Text(verbatim: timingStatus).foregroundStyle(.secondary)
                }
                ForEach(Array(timingRuns.enumerated()), id: \.offset) { _, run in
                    Text(verbatim: run.summary).font(.caption.monospaced())
                }
                if !timingRuns.isEmpty {
                    Button {
                        UIPasteboard.general.string = timingRuns.map(\.summary).joined(separator: "\n\n")
                    } label: { Text(verbatim: "Copy all runs") }
                    Button(role: .destructive) {
                        Task { await TimingLog.shared.clear(); await loadTiming() }
                    } label: { Text(verbatim: "Clear runs") }
                }
                Button { Task { await loadTiming() } } label: { Text(verbatim: "Refresh runs") }
            } header: {
                Text(verbatim: "Background timing (task 2 spike)")
            } footer: {
                Text(verbatim: "Only runs started by iOS as a background task count. Schedule, send the app to the "
                     + "background, then force a task from the debugger: e -l objc -- (void)[[BGTaskScheduler "
                     + "sharedScheduler] _simulateLaunchForTaskWithIdentifier:@\"com.ADBLX.ADBLX.filter-refresh\"] "
                     + "(or filter-install). Note the carrier with each cellular run.")
            }
            Section("Last reload") {
                if (diagnostics?.reloads ?? []).isEmpty {
                    Text(verbatim: "No reloads this launch").foregroundStyle(.secondary)
                }
                ForEach(diagnostics?.reloads ?? [], id: \.extensionIdentifier) { entry in
                    row(entry.extensionIdentifier.components(separatedBy: ".").last ?? entry.extensionIdentifier, entry.outcome)
                }
            }
            Section {
                Button { Task { await load() } } label: { Text(verbatim: "Refresh") }
                Button {
                    Task { await recompile() }
                } label: {
                    HStack {
                        Text(verbatim: "Recompile all now")
                        if isRecompiling { Spacer(); ProgressView() }
                    }
                }
                .disabled(isRecompiling)
                if let recompileSummary {
                    Text(verbatim: recompileSummary).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Developer")
        .task { await load(); await tunnel.refresh(); await loadTiming() }
    }

    /// Resets to the real plan on relaunch, so a forced state never outlives the session.
    @State private var selectedOverride: DebugPlanOverride?

    private var overrideBinding: Binding<DebugPlanOverride?> {
        Binding(
            get: { selectedOverride },
            set: { option in
                selectedOverride = option
                Task { await planStateModel?.setDebugOverride(option?.state()) }
            }
        )
    }

    private func load() async {
        let service = AppCompositionRoot.makeSubscriptionService()
        diagnostics = await DeveloperDiagnostics.gather(
            service: service,
            trial: AppCompositionRoot.makeTrialSource(),
            store: AppCompositionRoot.makeFilterStore()
        )
        await planStateModel?.refresh()
    }

    private func loadTiming() async {
        timingRuns = await TimingLog.shared.runs()
    }

    private func recompile() async {
        isRecompiling = true
        recompileSummary = nil
        let store = AppCompositionRoot.makeFilterStore()
        recompileSummary = await DeveloperDiagnostics.recompileAll(
            pipeline: AppCompositionRoot.makeFilterPipeline(store: store)
        )
        isRecompiling = false
        await load()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .font(.callout.monospaced())
    }

    private func describe(_ state: PlanState) -> String {
        switch state {
        case .premium(let kind): return "premium(\(kind == .lifetime ? "lifetime" : "subscription"))"
        case .trial(let days, _): return "trial(\(days)d)"
        case .trialExpired: return "trialExpired"
        case .free: return "free"
        }
    }
}
#endif
