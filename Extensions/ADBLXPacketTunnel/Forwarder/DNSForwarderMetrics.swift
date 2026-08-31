import Foundation
import os

public enum DNSForwarderMetrics {
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX.ADBLXPacketTunnel", category: "DNSForwarder")
    private static let signposter = OSSignposter(subsystem: "com.ADBLX.ADBLX.ADBLXPacketTunnel", category: "DNSForwarder")
    
    public static func logQueryReceived(clientTxID: UInt16) {
        logger.debug("DNS Query Received (ClientTxID: \(clientTxID, privacy: .public))")
    }
    
    public static func logForwardedUpstream(upstreamTxID: UInt16) {
        logger.debug("DNS Query Forwarded Upstream (UpstreamTxID: \(upstreamTxID, privacy: .public))")
    }
    
    public static func logResponseCorrelated(upstreamTxID: UInt16, clientTxID: UInt16, latencyMs: Double) {
        logger.debug("DNS Response Correlated: UpstreamTxID \(upstreamTxID, privacy: .public) -> ClientTxID \(clientTxID, privacy: .public) (\(latencyMs, privacy: .public) ms)")
    }
    
    public static func logQueryTimeout(upstreamTxID: UInt16, clientTxID: UInt16) {
        logger.notice("DNS Query Timed Out: UpstreamTxID \(upstreamTxID, privacy: .public) (ClientTxID: \(clientTxID, privacy: .public))")
    }
    
    public static func logCapacityDropped(clientTxID: UInt16) {
        logger.warning("DNS Query Dropped: In-flight capacity reached (ClientTxID: \(clientTxID, privacy: .public))")
    }
    
    public static func logTunnelShutdown(activeQueriesCount: Int) {
        logger.notice("DNS Forwarder Stopped: Cancelled \(activeQueriesCount, privacy: .public) pending queries")
    }
}
