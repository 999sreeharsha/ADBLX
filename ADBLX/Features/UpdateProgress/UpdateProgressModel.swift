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

/// Drives the shared Update Progress sheet, presentable from Home or Protection
/// (Sprint 4 spec §7). This sprint walks a canned local sequence; a later sprint
/// replaces start()'s body with real UpdateCoordinator callbacks — the sheet
/// itself does not change.
@Observable
final class UpdateProgressModel {
    var phase: UpdatePhase = .idle

    var progressDescription: String {
        switch phase {
        case .idle: return "Ready to update"
        case .checking: return "Checking for updates…"
        case .downloading: return "Downloading filter updates…"
        case .installing: return "Installing filters…"
        case .complete: return "Filters updated"
        case .failed(let message): return message
        }
    }

    func start() async {
        phase = .checking
        try? await Task.sleep(for: .milliseconds(300))
        phase = .downloading
        try? await Task.sleep(for: .milliseconds(300))
        phase = .installing
        try? await Task.sleep(for: .milliseconds(300))
        phase = .complete
    }
}
