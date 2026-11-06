import NetworkExtension
import os
import ADBLXShared

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.ADBLX.ADBLX.ADBLXPacketTunnel", category: "Provider")
    private let signposter = OSSignposter(subsystem: "com.ADBLX.ADBLX.ADBLXPacketTunnel", category: "Provider")
    
    private var generationLoader: DNSGenerationLoader?
    private var lookupEngine: DNSLookupEngine?
    private var forwarder: DNSUpstreamForwarder?
    private var tcpServer: DNSTCPServer?
    private var payloadResolver: DNSPayloadResolver?
    
    // Aggregate diagnostic counters (zero private browsing history retained)
    private var totalIngressQueries: UInt64 = 0
    private var totalBlockedQueries: UInt64 = 0
    private var totalForwardedQueries: UInt64 = 0
    private var totalResponsesEgress: UInt64 = 0
    
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let startSignpost = signposter.beginInterval("TunnelStart")
        logger.notice("Starting production Layer 2 DNS Protection tunnel")

        // Backstop for entitlement loss while the app wasn't running: refuse to start once
        // the published validUntil has passed (single read + date comparison).
        if TunnelEntitlementGuard.check() == .deniedExpired {
            logger.notice("Tunnel start refused: premium entitlement window has passed")
            signposter.endInterval("TunnelStart", startSignpost)
            completionHandler(NSError(
                domain: "com.ADBLX.ADBLX.PacketTunnel",
                code: -403,
                userInfo: [NSLocalizedDescriptionKey: "DNS Protection requires an active ADBLX Premium plan."]
            ))
            return
        }
        
        // 1. Parse Provider Configuration
        let pConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let rawOption = pConfig["resolverOption"] as? String ?? UpstreamResolverOption.quad9Default.rawValue
        let resolverOption = UpstreamResolverOption(rawValue: rawOption) ?? .quad9Default
        let customIPv4 = pConfig["ipv4Address"] as? String ?? "9.9.9.9"
        let customIPv6 = pConfig["ipv6Address"] as? String
        
        let upstreamIPv4 = (resolverOption == .quad9Default) ? "9.9.9.9" : customIPv4
        let upstreamIPv6 = (resolverOption == .quad9Default) ? "2620:fe::fe" : customIPv6
        
        // 2. Scoped DNS routing and route exclusions (loop prevention); see TunnelNetworkSettingsFactory.
        let settings = TunnelNetworkSettingsFactory.make(upstreamIPv4: upstreamIPv4, upstreamIPv6: upstreamIPv6)

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
            timeoutSeconds: 2.0,
            maxInFlightQueries: 512
        )
        let fwd = DNSUpstreamForwarder(config: forwarderConfig)
        self.forwarder = fwd
        // TCP clients (the retry after a truncated UDP answer) are answered by a small TCP server
        // on the fake DNS address, resolving through the same engine and forwarder as UDP.
        self.tcpServer = DNSTCPServer(
            serverIP: Self.ipv4Value(TunnelNetworkSettingsFactory.fakeDNSServer),
            clock: SystemDNSClock()
        )
        self.payloadResolver = DNSPayloadResolver(engine: engine, forwarder: fwd)
        
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
                
                switch TunnelPacketClassifier.classify(packetData) {
                case .tcp(let segment):
                    self.handleTCP(segment)
                case .unparsable:
                    break
                case .udpQuery(let query):
                    self.handleUDP(query, packetData: packetData, proto: proto)
                }
            }
            
            self.readPackets()
        }
    }
    
    private func handleUDP(_ query: ParsedDNSQuery, packetData: Data, proto: NSNumber) {
        // Periodically check for generation update
        if (totalIngressQueries % 100) == 0 {
            checkForGenerationUpdate()
        }
        
        // Check DNS Lookup Engine
        guard let engine = lookupEngine else { return }
        let decision = query.reversedDomain.withUnsafeBufferPointer { engine.lookup(reversedBytes: $0) }
        
        switch decision {
        case .block:
            totalBlockedQueries &+= 1
            let response = packetData.withUnsafeBytes {
                NXDOMAINResponseBuilder.buildResponse(
                    for: query,
                    originalPacket: $0.bindMemory(to: UInt8.self),
                    rcode: 3 // NXDOMAIN
                )
            }
            if let response {
                totalResponsesEgress &+= 1
                packetFlow.writePackets([response], withProtocols: [proto])
            }
            
        case .allow:
            totalForwardedQueries &+= 1
            Task {
                guard let forwarder = self.forwarder else { return }
                _ = await forwarder.forward(query: query, originalPacket: packetData)
            }
        }
    }
    
    private func handleTCP(_ segment: ParsedTCPSegment) {
        guard let server = tcpServer, let resolver = payloadResolver else { return }
        let output = server.receive(segment)
        writeIPv4(output.packets)
        for pending in output.queries {
            Task { [weak self] in
                // An unreadable question closes the connection, as a resolver would.
                let answer = await resolver.resolve(pending.message)
                guard let self, let server = self.tcpServer else { return }
                if let answer {
                    self.writeIPv4(server.respond(to: pending.key, with: answer))
                }
            }
        }
    }
    
    private func writeIPv4(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        totalResponsesEgress &+= UInt64(packets.count)
        packetFlow.writePackets(packets, withProtocols: packets.map { _ in NSNumber(value: AF_INET) })
    }
    
    private static func ipv4Value(_ address: String) -> UInt32 {
        address.split(separator: ".").reduce(UInt32(0)) { ($0 << 8) | (UInt32($1) ?? 0) }
    }
    
    private func checkForGenerationUpdate() {
        guard let loader = generationLoader,
              let engine = lookupEngine else { return }
        loader.reloadIfUpdated(engine: engine)
    }
}
