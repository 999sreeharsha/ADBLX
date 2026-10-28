import NetworkExtension
import os
import ADBLXShared

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.ADBLX.ADBLX.ADBLXPacketTunnel", category: "Provider")
    private let signposter = OSSignposter(subsystem: "com.ADBLX.ADBLX.ADBLXPacketTunnel", category: "Provider")
    
    private var generationLoader: DNSGenerationLoader?
    private var lookupEngine: DNSLookupEngine?
    private var forwarder: DNSUpstreamForwarder?
    
    // Aggregate diagnostic counters (zero private browsing history retained)
    private var totalIngressQueries: UInt64 = 0
    private var totalBlockedQueries: UInt64 = 0
    private var totalForwardedQueries: UInt64 = 0
    private var totalResponsesEgress: UInt64 = 0
    
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let startSignpost = signposter.beginInterval("TunnelStart")
        logger.notice("Starting production Layer 2 DNS Protection tunnel")
        
        // 1. Parse Provider Configuration
        let pConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let rawOption = pConfig["resolverOption"] as? String ?? UpstreamResolverOption.quad9Default.rawValue
        let resolverOption = UpstreamResolverOption(rawValue: rawOption) ?? .quad9Default
        let customIPv4 = pConfig["ipv4Address"] as? String ?? "9.9.9.9"
        let customIPv6 = pConfig["ipv6Address"] as? String
        
        let upstreamIPv4 = (resolverOption == .quad9Default) ? "9.9.9.9" : customIPv4
        let upstreamIPv6 = (resolverOption == .quad9Default) ? "2620:fe::fe" : customIPv6
        
        // 2. Configure Scoped DNS Routing & Route Exclusions (Loop Prevention)
        let fakeDNSServer = "198.51.100.1"
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        
        let dnsSettings = NEDNSSettings(servers: [fakeDNSServer])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        
        // IPv4 Settings: Scoped fake DNS route + explicit upstream excluded route
        let ipv4Settings = NEIPv4Settings(addresses: ["192.0.2.2"], subnetMasks: ["255.255.255.255"])
        ipv4Settings.includedRoutes = [
            NEIPv4Route(destinationAddress: fakeDNSServer, subnetMask: "255.255.255.255")
        ]
        var excludedV4Routes = [
            NEIPv4Route(destinationAddress: upstreamIPv4, subnetMask: "255.255.255.255")
        ]
        if upstreamIPv4 != "9.9.9.9" {
            excludedV4Routes.append(NEIPv4Route(destinationAddress: "9.9.9.9", subnetMask: "255.255.255.255"))
        }
        ipv4Settings.excludedRoutes = excludedV4Routes
        settings.ipv4Settings = ipv4Settings
        
        // IPv6 Settings: Exclude upstream IPv6
        if let v6 = upstreamIPv6 {
            let ipv6Settings = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [128])
            ipv6Settings.excludedRoutes = [
                NEIPv6Route(destinationAddress: v6, networkPrefixLength: 128)
            ]
            settings.ipv6Settings = ipv6Settings
        }
        
        // 3. Initialize Runtime Engine & Generation Loader
        let loader = DNSGenerationLoader()
        self.generationLoader = loader
        
        let initialSnapshot: DNSLookupSnapshot
        if let loaded = try? loader.loadActiveGeneration() {
            initialSnapshot = loaded
            logger.notice("Loaded active DNS generation \(loaded.generation, privacy: .public)")
        } else {
            initialSnapshot = DNSLookupSnapshot.makeEmptySnapshot()
            logger.notice("Initialized with empty DNS snapshot")
        }
        
        let engine = DNSLookupEngine(initialSnapshot: initialSnapshot)
        self.lookupEngine = engine
        
        // 4. Initialize Async Upstream Forwarder
        let forwarderConfig = UpstreamResolverConfig(
            ipv4Address: upstreamIPv4,
            ipv6Address: upstreamIPv6,
            port: 53,
            timeoutSeconds: 5.0,
            maxInFlightQueries: 512
        )
        let fwd = DNSUpstreamForwarder(config: forwarderConfig)
        self.forwarder = fwd
        
        Task {
            do {
                try await fwd.start { [weak self] (responsePacket: Data, ipVersion: IPVersion) in
                    guard let self = self else { return }
                    self.totalResponsesEgress &+= 1
                    let protocolNumber: NSNumber = (ipVersion == .v6) ? NSNumber(value: AF_INET6) : NSNumber(value: AF_INET)
                    self.packetFlow.writePackets([responsePacket], withProtocols: [protocolNumber])
                }
            } catch {
                self.logger.error("Failed to start DNSUpstreamForwarder: \(error.localizedDescription, privacy: .public)")
                self.signposter.endInterval("TunnelStart", startSignpost)
                completionHandler(error)
                return
            }
            
            // 5. Apply Tunnel Network Settings
            self.setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self = self else { return }
                self.signposter.endInterval("TunnelStart", startSignpost)
                
                if let error = error {
                    self.logger.error("Failed to apply tunnel settings: \(error.localizedDescription, privacy: .public)")
                    completionHandler(error)
                    return
                }
                
                self.logger.notice("Tunnel network settings applied successfully. Starting packetFlow read loop.")
                completionHandler(nil)
                self.readPackets()
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let stopSignpost = signposter.beginInterval("TunnelStop")
        logger.notice("Stopping DNS Protection tunnel, reason: \(String(describing: reason), privacy: .public)")
        
        Task {
            await self.forwarder?.stop()
            self.forwarder = nil
            self.lookupEngine = nil
            self.generationLoader = nil
            
            self.signposter.endInterval("TunnelStop", stopSignpost)
            completionHandler()
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        checkForGenerationUpdate()
        completionHandler?(nil)
    }
    
    // MARK: - Packet Processing Loop
    
    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            
            for (index, packetData) in packets.enumerated() {
                self.totalIngressQueries &+= 1
                let proto = protocols[index]
                
                packetData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let buffer = raw.bindMemory(to: UInt8.self)
                    guard let query = DNSPacketParser.parse(packet: buffer) else {
                        return
                    }
                    
                    // Periodically check for generation update
                    if (self.totalIngressQueries % 100) == 0 {
                        self.checkForGenerationUpdate()
                    }
                    
                    // Check DNS Lookup Engine
                    guard let engine = self.lookupEngine else { return }
                    let decision = query.reversedDomain.withUnsafeBufferPointer { engine.lookup(reversedBytes: $0) }
                    
                    switch decision {
                    case .block:
                        self.totalBlockedQueries &+= 1
                        if let response = NXDOMAINResponseBuilder.buildResponse(
                            for: query,
                            originalPacket: buffer,
                            rcode: 3 // NXDOMAIN
                        ) {
                            self.totalResponsesEgress &+= 1
                            self.packetFlow.writePackets([response], withProtocols: [proto])
                        }
                        
                    case .allow:
                        self.totalForwardedQueries &+= 1
                        Task {
                            guard let forwarder = self.forwarder else { return }
                            _ = await forwarder.forward(query: query, originalPacket: packetData)
                        }
                    }
                }
            }
            
            self.readPackets()
        }
    }
    
    private func checkForGenerationUpdate() {
        guard let loader = generationLoader,
              let engine = lookupEngine else { return }
        loader.reloadIfUpdated(engine: engine)
    }
}
