// swiftlint:disable all
import SwiftUI
import NetworkExtension
import os
import Combine

@MainActor
final class DNSFilteringSpikeManager: ObservableObject {
    @Published var status: String = "Unknown"
    @Published var isEnabled: Bool = false
    @Published var errorMessage: String? = nil
    
    private var manager: NETunnelProviderManager?
    private let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "DNSFilteringSpike")
    
    init() {
        refreshStatus()
        
        // Listen to VPN status changes
        NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateStatus()
        }
    }
    
    func refreshStatus() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.errorMessage = "Failed to load preferences: \(error.localizedDescription)"
                return
            }
            self.manager = managers?.first
            self.updateStatus()
        }
    }
    
    func installAndStart() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.errorMessage = "Load error: \(error.localizedDescription)"
                return
            }
            
            let targetManager = managers?.first ?? NETunnelProviderManager()
            
            let protocolConfiguration = NETunnelProviderProtocol()
            protocolConfiguration.providerBundleIdentifier = "com.ADBLX.ADBLX.PacketTunnel"
            protocolConfiguration.serverAddress = "ADBLX DNS Shield (Spike)"
            
            targetManager.protocolConfiguration = protocolConfiguration
            targetManager.localizedDescription = "ADBLX DNS Shield (Spike)"
            targetManager.isEnabled = true
            
            targetManager.saveToPreferences { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.errorMessage = "Save error: \(error.localizedDescription)"
                    return
                }
                
                targetManager.loadFromPreferences { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        self.errorMessage = "Reload error: \(error.localizedDescription)"
                        return
                    }
                    
                    self.manager = targetManager
                    
                    do {
                        try targetManager.connection.startVPNTunnel()
                        self.updateStatus()
                    } catch {
                        self.errorMessage = "Start error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    func stopTunnel() {
        manager?.connection.stopVPNTunnel()
        updateStatus()
    }
    
    private func updateStatus() {
        if let manager = manager {
            switch manager.connection.status {
            case .invalid: status = "Invalid"
            case .disconnected: status = "Disconnected"
            case .connecting: status = "Connecting"
            case .connected: status = "Connected"
            case .reasserting: status = "Reasserting"
            case .disconnecting: status = "Disconnecting"
            @unknown default: status = "Unknown State"
            }
            isEnabled = manager.isEnabled
        } else {
            status = "Not Installed"
            isEnabled = false
        }
    }
}
