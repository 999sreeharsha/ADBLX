// swiftlint:disable all
import SwiftUI

struct DNSFilteringSpikeView: View {
    @StateObject private var spikeManager = DNSFilteringSpikeManager()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("DNS Filtering Spike (8B-0.1A)")
                .font(.title2)
                .bold()
                .padding(.top)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Status:")
                        .bold()
                    Text(spikeManager.status)
                        .foregroundColor(statusColor)
                }
                
                HStack {
                    Text("Installed:")
                        .bold()
                    Text(spikeManager.isEnabled ? "Yes" : "No")
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            if let error = spikeManager.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding()
            }
            
            HStack(spacing: 20) {
                Button("Install & Start") {
                    spikeManager.errorMessage = nil
                    spikeManager.installAndStart()
                }
                .buttonStyle(.borderedProminent)
                
                Button("Stop") {
                    spikeManager.errorMessage = nil
                    spikeManager.stopTunnel()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            spikeManager.refreshStatus()
        }
    }
    
    private var statusColor: Color {
        switch spikeManager.status {
        case "Connected": return .green
        case "Connecting": return .orange
        case "Disconnected": return .secondary
        case "Invalid": return .red
        default: return .primary
        }
    }
}
