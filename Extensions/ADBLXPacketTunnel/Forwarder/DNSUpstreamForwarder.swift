import Foundation
import os
import ADBLXShared

public actor DNSUpstreamForwarder {
    private var config: UpstreamResolverConfig
    private var ipv4Socket: (any DNSUpstreamSocketProtocol)?
    private var ipv6Socket: (any DNSUpstreamSocketProtocol)?
    
    private var pendingTransactions: [UInt16: PendingQuery] = [:]
    private var nextTxID: UInt16 = 1
    private var packetWriter: (@Sendable (Data, IPVersion) -> Void)?
    
    private let socketFactory: @Sendable (String, UInt16, Bool) throws -> any DNSUpstreamSocketProtocol
    private let clock: DNSClock
    private let tcpTransport: DNSUpstreamTCPTransport?
    private let counters: DNSTunnelCounters?
    
    public init(
        config: UpstreamResolverConfig = UpstreamResolverConfig(),
        socketFactory: @escaping @Sendable (String, UInt16, Bool) throws -> any DNSUpstreamSocketProtocol = { host, port, isIPv6 in
            try BSDUDPUpstreamSocket(host: host, port: port, isIPv6: isIPv6)
        },
        clock: DNSClock = SystemDNSClock(),
        tcpTransport: DNSUpstreamTCPTransport? = NWDNSUpstreamTCPTransport(),
        counters: DNSTunnelCounters? = nil
    ) {
        self.config = config
        self.socketFactory = socketFactory
        self.clock = clock
        self.tcpTransport = tcpTransport
        self.counters = counters
    }
    
    public var activeInFlightCount: Int {
        pendingTransactions.count
    }
    
    // MARK: - Lifecycle
    
    public func start(packetWriter: @escaping @Sendable (Data, IPVersion) -> Void) throws {
        self.packetWriter = packetWriter
        try initializeSockets()
    }
    
    /// Where answers go. `start` sets it; this exists so a caller (or test) can set it alone.
    public func setPacketWriter(_ writer: @escaping @Sendable (Data, IPVersion) -> Void) {
        self.packetWriter = writer
    }
    
    public func stop() {
        let activeCount = pendingTransactions.count
        for (_, pending) in pendingTransactions {
            pending.timeoutTask?.cancel()
            pending.exchangeContinuation?.resume(returning: nil)
        }
        pendingTransactions.removeAll()
        
        ipv4Socket?.close()
        ipv4Socket = nil
        
        ipv6Socket?.close()
        ipv6Socket = nil
        
        DNSForwarderMetrics.logTunnelShutdown(activeQueriesCount: activeCount)
    }
    
    public func reconfigure(newConfig: UpstreamResolverConfig) throws {
        stop()
        self.config = newConfig
        try initializeSockets()
    }
    
    private func initializeSockets() throws {
        // IPv4 Socket
        let v4Socket = try socketFactory(config.ipv4Address, config.port, false)
        v4Socket.setResponseHandler { [weak self] data, senderIP, senderPort in
            Task { [weak self] in
                await self?.handleUpstreamResponse(data: data, senderIP: senderIP, senderPort: senderPort, isIPv6: false)
            }
        }
        self.ipv4Socket = v4Socket
        
        // IPv6 Socket
        if let v6Address = config.ipv6Address {
            let v6Socket = try socketFactory(v6Address, config.port, true)
            v6Socket.setResponseHandler { [weak self] data, senderIP, senderPort in
                Task { [weak self] in
                    await self?.handleUpstreamResponse(data: data, senderIP: senderIP, senderPort: senderPort, isIPv6: true)
                }
            }
            self.ipv6Socket = v6Socket
        }
    }
    
    // MARK: - Forwarding Query
    
    public func forward(
        query: ParsedDNSQuery,
        originalPacket: Data
    ) async -> DNSForwarderResult {
        guard query.dnsHeaderOffset + 12 <= originalPacket.count else {
            return .socketUnavailable("Malformed DNS header offset")
        }
        let clientQuery = originalPacket.subdata(in: query.dnsHeaderOffset..<originalPacket.count)
        
        // 1. Check Capacity Limit
        guard pendingTransactions.count < config.maxInFlightQueries else {
            // Synthesize immediate SERVFAIL response to prevent client retry storms
            originalPacket.withUnsafeBytes { raw in
                if let servfail = NXDOMAINResponseBuilder.buildResponse(
                    for: query,
                    originalPacket: raw.bindMemory(to: UInt8.self),
                    rcode: 2 // SERVFAIL
                ) {
                    self.packetWriter?(servfail, query.ipVersion)
                }
            }
            DNSForwarderMetrics.logCapacityDropped(clientTxID: query.transactionID)
            return .capacityExceeded
        }
        
        // 2. Allocate Unique Upstream Transaction ID (Collision-Safe)
        let upstreamTxID = allocateNextUpstreamTxID()
        var pending = PendingQuery(
            upstreamTxID: upstreamTxID,
            clientTxID: query.transactionID,
            ipVersion: query.ipVersion,
            clientSrcIPv4: query.srcIPv4,
            clientDstIPv4: query.dstIPv4,
            clientSrcIPv6: query.srcIPv6,
            clientDstIPv6: query.dstIPv6,
            clientSrcPort: query.srcPort,
            clientDstPort: query.dstPort,
            requestTimestamp: clock.now,
            timeoutTask: nil,
            clientQuery: clientQuery,
            exchangeContinuation: nil
        )
        
        // 3. Select Socket. A client is never left waiting: no socket is a SERVFAIL.
        let targetSocket: (any DNSUpstreamSocketProtocol)?
        switch query.ipVersion {
        case .v4:
            targetSocket = ipv4Socket
        case .v6:
            targetSocket = ipv6Socket ?? ipv4Socket
        }
        guard let socket = targetSocket else {
            emitServfail(for: pending)
            return .socketUnavailable("No socket available for \(query.ipVersion)")
        }
        
        // 4. Rewrite the DNS payload with the upstream transaction ID
        var dnsPayload = clientQuery
        dnsPayload.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base[0] = UInt8((upstreamTxID >> 8) & 0xFF)
            base[1] = UInt8(upstreamTxID & 0xFF)
        }
        
        // 5. Record Pending Transaction & Schedule Timeout BEFORE send to eliminate fast-response race condition
        pending.timeoutTask = scheduleTimeout(upstreamTxID: upstreamTxID)
        pendingTransactions[upstreamTxID] = pending
        DNSForwarderMetrics.logForwardedUpstream(upstreamTxID: upstreamTxID)
        
        // 6. Send via UDP
        do {
            try await socket.send(payload: dnsPayload)
        } catch {
            counters?.increment(\.upstreamSendErrors)
            if let dropped = pendingTransactions.removeValue(forKey: upstreamTxID) {
                dropped.timeoutTask?.cancel()
                emitServfail(for: dropped)
            }
            return .socketUnavailable(error.localizedDescription)
        }
        
        return .forwarded(upstreamTxID: upstreamTxID)
    }
    
    // MARK: - Exchange (a bare DNS message in, the answer out; used for TCP clients)
    
    /// Asks the upstream over UDP, following a truncated answer to TCP. Nil if there is no answer
    /// (timeout, send failure, no usable TCP fallback): the caller turns that into a SERVFAIL.
    public func exchange(dnsPayload: Data) async -> Data? {
        guard dnsPayload.count >= 12,
              pendingTransactions.count < config.maxInFlightQueries,
              let socket = ipv4Socket else { return nil }
        let upstreamTxID = allocateNextUpstreamTxID()
        let clientTxID = UInt16(dnsPayload[dnsPayload.startIndex]) << 8 | UInt16(dnsPayload[dnsPayload.startIndex + 1])
        var upstreamPayload = dnsPayload
        upstreamPayload.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base[0] = UInt8((upstreamTxID >> 8) & 0xFF)
            base[1] = UInt8(upstreamTxID & 0xFF)
        }
        
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            var pending = PendingQuery(
                upstreamTxID: upstreamTxID, clientTxID: clientTxID, ipVersion: .v4,
                clientSrcIPv4: 0, clientDstIPv4: 0, clientSrcIPv6: (0, 0), clientDstIPv6: (0, 0),
                clientSrcPort: 0, clientDstPort: 0,
                requestTimestamp: clock.now, timeoutTask: nil,
                clientQuery: dnsPayload, exchangeContinuation: continuation
            )
            pending.timeoutTask = scheduleTimeout(upstreamTxID: upstreamTxID)
            pendingTransactions[upstreamTxID] = pending
            let payload = upstreamPayload
            Task { [weak self] in
                do {
                    try await socket.send(payload: payload)
                } catch {
                    await self?.failPending(upstreamTxID: upstreamTxID)
                }
            }
        }
    }
    
    private func failPending(upstreamTxID: UInt16) {
        guard let pending = pendingTransactions.removeValue(forKey: upstreamTxID) else { return }
        counters?.increment(\.upstreamSendErrors)
        pending.timeoutTask?.cancel()
        fail(pending)
    }
    
    // MARK: - Handling Upstream Response
    
    public func handleUpstreamResponse(data: Data, senderIP: String, senderPort: UInt16, isIPv6: Bool) {
        guard data.count >= 12 else { return }
        
        // Validate source endpoint (protect against rogue/unrelated UDP packets)
        let expectedHost = isIPv6 ? config.ipv6Address : config.ipv4Address
        if let exp = expectedHost, !senderIP.isEmpty && senderIP != exp {
            return
        }
        if senderPort != 0 && senderPort != config.port {
            return
        }
        
        let upstreamTxID = (UInt16(data[0]) << 8) | UInt16(data[1])
        guard let pending = pendingTransactions.removeValue(forKey: upstreamTxID) else {
            // Already timed out or unrecognized ID
            return
        }
        
        pending.timeoutTask?.cancel()
        
        let latencyMs = (clock.now - pending.requestTimestamp) * 1000.0
        DNSForwarderMetrics.logResponseCorrelated(upstreamTxID: upstreamTxID, clientTxID: pending.clientTxID, latencyMs: latencyMs)
        
        // The upstream cut its own answer short: get the whole one over TCP rather than hand the
        // client a truncated answer it would retry over a connection we'd otherwise not answer.
        if DNSMessage.isTruncated(data) {
            counters?.increment(\.truncatedUpstreamAnswers)
            Task { [weak self] in await self?.completeTruncated(pending) }
            return
        }
        deliver(data, for: pending)
    }
    
    private func completeTruncated(_ pending: PendingQuery) async {
        guard let transport = tcpTransport else { return fail(pending) }
        do {
            let full = try await transport.exchange(query: pending.clientQuery, host: config.ipv4Address, port: config.port)
            guard full.count >= 12 else { return fail(pending) }
            deliver(full, for: pending)
        } catch {
            fail(pending)
        }
    }
    
    /// Hands `response` to whoever asked: a waiting `exchange`, or the client as a UDP packet
    /// (cut to what its UDP limit allows, with TC set, so it comes back over TCP).
    private func deliver(_ response: Data, for pending: PendingQuery) {
        var answer = response
        answer.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base[0] = UInt8((pending.clientTxID >> 8) & 0xFF)
            base[1] = UInt8(pending.clientTxID & 0xFF)
        }
        if let continuation = pending.exchangeContinuation {
            continuation.resume(returning: answer)
            return
        }
        if answer.count > DNSMessage.clientUDPLimit(of: pending.clientQuery) {
            answer = DNSMessage.truncated(answer)
        }
        writeClientPacket(pending, dnsPayload: answer)
    }
    
    /// No answer is coming. A waiting `exchange` gets nil; a client gets a SERVFAIL.
    private func fail(_ pending: PendingQuery) {
        if let continuation = pending.exchangeContinuation {
            continuation.resume(returning: nil)
        } else {
            emitServfail(for: pending)
        }
    }
    
    private func emitServfail(for pending: PendingQuery) {
        guard let servfail = DNSMessage.errorResponse(for: pending.clientQuery, rcode: 2) else { return }
        counters?.increment(\.servfailsSent)
        writeClientPacket(pending, dnsPayload: servfail)
    }
    
    private func writeClientPacket(_ pending: PendingQuery, dnsPayload: Data) {
        let packet: Data
        switch pending.ipVersion {
        case .v4: packet = buildIPv4ResponsePacket(pending: pending, dnsPayload: dnsPayload)
        case .v6: packet = buildIPv6ResponsePacket(pending: pending, dnsPayload: dnsPayload)
        }
        packetWriter?(packet, pending.ipVersion)
    }
    
    // MARK: - Timeout
    
    private func scheduleTimeout(upstreamTxID: UInt16) -> Task<Void, Never> {
        let seconds = config.timeoutSeconds
        let clock = self.clock
        return Task { [weak self] in
            do { try await clock.sleep(seconds: seconds) } catch { return }
            await self?.handleTimeout(upstreamTxID: upstreamTxID)
        }
    }
    
    private func handleTimeout(upstreamTxID: UInt16) {
        guard let pending = pendingTransactions.removeValue(forKey: upstreamTxID) else { return }
        DNSForwarderMetrics.logQueryTimeout(upstreamTxID: upstreamTxID, clientTxID: pending.clientTxID)
        counters?.increment(\.upstreamTimeouts)
        fail(pending)
    }
    
    private func allocateNextUpstreamTxID() -> UInt16 {
        for _ in 0..<65535 {
            let candidate = nextTxID
            nextTxID &+= 1
            if nextTxID == 0 { nextTxID = 1 }
            if pendingTransactions[candidate] == nil {
                return candidate
            }
        }
        return nextTxID
    }
    
    // MARK: - Packet Synthesis
    
    private func buildIPv4ResponsePacket(pending: PendingQuery, dnsPayload: Data) -> Data {
        let udpLen = 8 + dnsPayload.count
        let totalLen = 20 + udpLen
        
        var packet = Data(count: totalLen)
        packet.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            // IPv4 Header
            base[0] = 0x45
            base[1] = 0x00
            base[2] = UInt8((totalLen >> 8) & 0xFF)
            base[3] = UInt8(totalLen & 0xFF)
            base[4] = 0x00
            base[5] = 0x00
            base[6] = 0x40 // DF
            base[7] = 0x00
            base[8] = 64
            base[9] = 17 // UDP
            base[10] = 0
            base[11] = 0
            
            // Swapped IPs
            let srcIP = pending.clientDstIPv4
            let dstIP = pending.clientSrcIPv4
            base[12] = UInt8((srcIP >> 24) & 0xFF)
            base[13] = UInt8((srcIP >> 16) & 0xFF)
            base[14] = UInt8((srcIP >> 8) & 0xFF)
            base[15] = UInt8(srcIP & 0xFF)
            base[16] = UInt8((dstIP >> 24) & 0xFF)
            base[17] = UInt8((dstIP >> 16) & 0xFF)
            base[18] = UInt8((dstIP >> 8) & 0xFF)
            base[19] = UInt8(dstIP & 0xFF)
            
            let ipCheck = InternetChecksum.computeIPv4HeaderChecksum(headerBuffer: UnsafeBufferPointer(start: base, count: 20))
            base[10] = UInt8((ipCheck >> 8) & 0xFF)
            base[11] = UInt8(ipCheck & 0xFF)
            
            // UDP Header
            let srcPort = pending.clientDstPort
            let dstPort = pending.clientSrcPort
            base[20] = UInt8((srcPort >> 8) & 0xFF)
            base[21] = UInt8(srcPort & 0xFF)
            base[22] = UInt8((dstPort >> 8) & 0xFF)
            base[23] = UInt8(dstPort & 0xFF)
            base[24] = UInt8((udpLen >> 8) & 0xFF)
            base[25] = UInt8(udpLen & 0xFF)
            base[26] = 0
            base[27] = 0
            
            // Copy DNS Payload
            dnsPayload.withUnsafeBytes { (dnsRaw: UnsafeRawBufferPointer) in
                for i in 0..<dnsPayload.count {
                    base[28 + i] = dnsRaw[i]
                }
            }
            
            let udpCheck = InternetChecksum.computeUDPChecksumIPv4(
                srcIP: srcIP,
                dstIP: dstIP,
                udpPacket: UnsafeBufferPointer(start: base + 20, count: udpLen)
            )
            base[26] = UInt8((udpCheck >> 8) & 0xFF)
            base[27] = UInt8(udpCheck & 0xFF)
        }
        
        return packet
    }
    
    private func buildIPv6ResponsePacket(pending: PendingQuery, dnsPayload: Data) -> Data {
        let udpLen = 8 + dnsPayload.count
        let totalLen = 40 + udpLen
        
        var packet = Data(count: totalLen)
        packet.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            // IPv6 Header
            base[0] = 0x60
            base[1] = 0x00
            base[2] = 0x00
            base[3] = 0x00
            base[4] = UInt8((udpLen >> 8) & 0xFF)
            base[5] = UInt8(udpLen & 0xFF)
            base[6] = 17 // UDP
            base[7] = 64
            
            var srcIP = pending.clientDstIPv6
            var dstIP = pending.clientSrcIPv6
            withUnsafePointer(to: &srcIP) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: 16) { rawSrc in
                    for i in 0..<16 { base[8 + i] = rawSrc[i] }
                }
            }
            withUnsafePointer(to: &dstIP) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: 16) { rawDst in
                    for i in 0..<16 { base[24 + i] = rawDst[i] }
                }
            }
            
            // UDP Header
            let srcPort = pending.clientDstPort
            let dstPort = pending.clientSrcPort
            base[40] = UInt8((srcPort >> 8) & 0xFF)
            base[41] = UInt8(srcPort & 0xFF)
            base[42] = UInt8((dstPort >> 8) & 0xFF)
            base[43] = UInt8(dstPort & 0xFF)
            base[44] = UInt8((udpLen >> 8) & 0xFF)
            base[45] = UInt8(udpLen & 0xFF)
            base[46] = 0
            base[47] = 0
            
            // Copy DNS Payload
            dnsPayload.withUnsafeBytes { (dnsRaw: UnsafeRawBufferPointer) in
                for i in 0..<dnsPayload.count {
                    base[48 + i] = dnsRaw[i]
                }
            }
            
            let udpCheck = InternetChecksum.computeUDPChecksumIPv6(
                srcIP: srcIP,
                dstIP: dstIP,
                udpPacket: UnsafeBufferPointer(start: base + 40, count: udpLen)
            )
            base[46] = UInt8((udpCheck >> 8) & 0xFF)
            base[47] = UInt8(udpCheck & 0xFF)
        }
        
        return packet
    }
}
