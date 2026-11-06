// ADBLX/Features/UpdateProgress/UpdateProgressModel.swift
import Observation
import Foundation

enum UpdatePhase: Equatable {
    case idle
    case checking
    case downloading
    case installing
    case complete
    case failed(String)
}

/// Drives the shared Update Progress sheet, presentable from Home or Protection.
/// Sprint 5B: start(coordinator:) replaces the earlier canned local sequence with
/// real UpdateCoordinator.run(onPhaseChange:) calls — the sheet itself is unchanged,
/// only its construction call sites (HomeView/SafariProtectionView) now pass a
/// coordinator through.
@Observable
final class UpdateProgressModel {
    var phase: UpdatePhase = .idle
    private let stateProvider: ContentBlockerStateProviding

    init(stateProvider: ContentBlockerStateProviding = SystemContentBlockerStateProvider()) {
        self.stateProvider = stateProvider
    }

    var progressDescription: String {
        switch phase {
        case .idle: return String(localized: "updateprogress.status.ready")
        case .checking: return String(localized: "updateprogress.status.checking")
        case .downloading: return String(localized: "updateprogress.status.downloading")
        case .installing: return String(localized: "updateprogress.status.installing")
        case .complete: return String(localized: "updateprogress.status.complete")
        case .failed(let message): return message
        }
    }

    func start(coordinator: UpdateCoordinator) async {
        do {
            let result = try await coordinator.run { [weak self] newPhase in
                // `.complete` is decided below, from the reload results.
                if newPhase != .complete { self?.phase = newPhase }
            }
            switch result {
            case .upToDate:
                phase = .complete
            case .updated(_, let reloadResults):
                phase = await PendingReloads.safariMissedRules(reloadResults, stateProvider: stateProvider)
                    ? .failed(String(localized: "updateprogress.status.reloadFailed"))
                    : .complete
            case .rolledBack, .rollbackFailed:
                phase = .failed(String(localized: "updateprogress.status.failed"))
            }
        } catch {
            phase = .failed(String(localized: "updateprogress.status.failed"))
        }
    }
}
