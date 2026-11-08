import Foundation
import os
import ADBLXShared

public actor DNSUpstreamForwarder {
    private var config: UpstreamResolverConfig
    private var ipv4Socket: (any DNSUpstreamSocketProtocol)?
    private var ipv6Socket: (any DNSUpstreamSocketProtocol)?
    private var fallbackSocket: (any DNSUpstreamSocketProtocol)?
    
    private var pendingTransactions: [UInt16: PendingQuery] = [:]
    private var nextTxID: UInt16 = 1
    private var packetWriter: (@Sendable (Data, IPVersion) -> Void)?
    
    private let socketFactory: @Sendable (String, UInt16, Bool) throws -> any DNSUpstreamSocketProtocol
    private let clock: DNSClock
    private let tcpTransport: DNSUpstreamTCPTransport?
    private let counters: DNSTunnelCounters?
    
    /// What each network has shown about the upstreams, by network key (see `resetSockets`).
    private var scoreboards: [String: UpstreamScoreboard] = [:]
    private var networkKey = ""
    private static let maxRememberedNetworks = 8
    
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
        
        fallbackSocket?.close()
        fallbackSocket = nil
        
        DNSForwarderMetrics.logTunnelShutdown(activeQueriesCount: activeCount)
    }
    
    public func reconfigure(newConfig: UpstreamResolverConfig) throws {
        stop()
        self.config = newConfig
        try initializeSockets()
    }
    
    private func initializeSockets() throws {
        ipv4Socket = try makeSocket(config.ipv4Address, isIPv6: false)
        if let v6Address = config.ipv6Address { ipv6Socket = try makeSocket(v6Address, isIPv6: true) }
        if let fallbackAddress = config.fallbackIPv4Address { fallbackSocket = try makeSocket(fallbackAddress, isIPv6: false) }
    }
    
    private func makeSocket(_ host: String, isIPv6: Bool) throws -> any DNSUpstreamSocketProtocol {
        let socket = try socketFactory(host, config.port, isIPv6)
        socket.setResponseHandler { [weak self] data, senderIP, senderPort in
            Task { [weak self] in
                await self?.handleUpstreamResponse(data: data, senderIP: senderIP, senderPort: senderPort, isIPv6: isIPv6)
            }
        }
        return socket
    }
    
    /// Replaces every upstream socket (after a network change, when the old ones may be bound to
    /// a path that is gone) and sends each query still waiting again, to the same upstreams, on
    /// the new sockets. `networkKey` names the network now in use, so queries from here on are
    /// ordered by what was learned on it.
    public func resetSockets(networkKey: String? = nil) throws {
        ipv4Socket?.close(); ipv4Socket = nil
        ipv6Socket?.close(); ipv6Socket = nil
        fallbackSocket?.close(); fallbackSocket = nil
        try initializeSockets()
        counters?.increment(\.socketResets)
        if let networkKey { switchNetwork(to: networkKey) }
        for (upstreamTxID, pending) in pendingTransactions {
            for upstream in pending.asked {
                Task { [weak self] in
                    guard let self else { return }
                    if await !self.transmit(upstreamTxID, to: upstream) { await self.askNext(upstreamTxID) }
                }
            }
        }
    }
    
    // MARK: - Choosing upstreams
    
    /// The upstreams that exist, in the default order: IPv6, the IPv4 primary, the IPv4 fallback.
    private var availableUpstreams: [UpstreamID] {
        var list: [UpstreamID] = []
        if ipv6Socket != nil { list.append(.ipv6) }
        if ipv4Socket != nil { list.append(.primaryIPv4) }
        if fallbackSocket != nil { list.append(.fallbackIPv4) }
        return list
    }
    
    /// The order a new query asks the upstreams in, from what this network has shown.
    private func orderedUpstreams() -> [UpstreamID] {
        (scoreboards[networkKey] ?? UpstreamScoreboard()).ordered(availableUpstreams)
    }
    
    /// Names the network in use without touching the sockets (the first path update).
    public func useNetwork(_ key: String) {
        switchNetwork(to: key)
    }

    private func switchNetwork(to key: String) {
        networkKey = key
        // A handful of networks is plenty; forgetting them all only costs relearning.
        if scoreboards[key] == nil, scoreboards.count >= Self.maxRememberedNetworks { scoreboards.removeAll() }
    }
    
    private func record(_ upstream: UpstreamID, success: Bool, network: String) {
        scoreboards[network, default: UpstreamScoreboard()].record(upstream, success: success)
    }
    
    private func address(of upstream: UpstreamID) -> String? {
        switch upstream {
        case .ipv6: return config.ipv6Address
        case .primaryIPv4: return config.ipv4Address
        case .fallbackIPv4: return config.fallbackIPv4Address
        }
    }
    
    private func socket(for upstream: UpstreamID) -> (any DNSUpstreamSocketProtocol)? {
        switch upstream {
        case .ipv6: return ipv6Socket
        case .primaryIPv4: return ipv4Socket
        case .fallbackIPv4: return fallbackSocket
        }
    }
    
    // MARK: - Asking upstreams
    
    /// Sends query `upstreamTxID` to `upstream`. A failed send counts against the upstream and
    /// stops the query waiting on it. True if the send went out.
    private func transmit(_ upstreamTxID: UInt16, to upstream: UpstreamID) async -> Bool {
        guard let pending = pendingTransactions[upstreamTxID] else { return false }
        var payload = pending.clientQuery
        payload.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base[0] = UInt8((upstreamTxID >> 8) & 0xFF)
            base[1] = UInt8(upstreamTxID & 0xFF)
        }
        do {
            guard let socket = socket(for: upstream) else { throw DNSUpstreamSocketError.unavailable }
            try await socket.send(payload: payload)
            return true
        } catch {
            counters?.increment(\.upstreamSendErrors)
            record(upstream, success: false, network: pending.network)
            pendingTransactions[upstreamTxID]?.asked.removeAll { $0 == upstream }
            return false
        }
    }
    
    /// Asks the next upstream not asked yet, moving straight past any whose send fails. With
    /// nothing left to ask and nothing still waited on, the query fails (a SERVFAIL) at once.
    /// True if a send went out.
    @discardableResult
    private func askNext(_ upstreamTxID: UInt16) async -> Bool {
        while var pending = pendingTransactions[upstreamTxID], !pending.remaining.isEmpty {
            let upstream = pending.remaining.removeFirst()
            if pending.timesAsked > 0 { counters?.increment(\.upstreamRetries) }
            pending.timesAsked += 1
            pending.asked.append(upstream)
            pendingTransactions[upstreamTxID] = pending
            if await transmit(upstreamTxID, to: upstream) { return true }
        }
        if let pending = pendingTransactions[upstreamTxID], pending.asked.isEmpty {
            pendingTransactions.removeValue(forKey: upstreamTxID)
            pending.timeoutTask?.cancel()
            fail(pending)
        }
        return false
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
        
        // Counted only: the OS resolver resends a query it got no answer to.
        if pendingTransactions.values.contains(where: {
            $0.exchangeContinuation == nil && $0.clientTxID == query.transactionID
                && $0.clientSrcPort == query.srcPort && $0.ipVersion == query.ipVersion
        }) {
            counters?.increment(\.duplicateClientQueries)
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
        
        // 3. Choose the upstreams. A client is never left waiting: none at all is a SERVFAIL.
        let upstreams = orderedUpstreams()
        guard !upstreams.isEmpty else {
            emitServfail(for: pending)
            return .socketUnavailable("No upstream socket available")
        }
        pending.remaining = upstreams
        pending.network = networkKey
        
        // 4. Record the query and start its timers BEFORE sending, so a fast answer finds it.
        pending.timeoutTask = scheduleTimers(upstreamTxID: upstreamTxID, start: pending.requestTimestamp, hedge: upstreams.count > 1)
        pendingTransactions[upstreamTxID] = pending
        DNSForwarderMetrics.logForwardedUpstream(upstreamTxID: upstreamTxID)
        
        // 5. Ask the preferred upstream (or the next, if its send fails).
        if await askNext(upstreamTxID) { return .forwarded(upstreamTxID: upstreamTxID) }
        return .socketUnavailable("No upstream accepted the query")
    }
    
    // MARK: - Exchange (a bare DNS message in, the answer out; used for TCP clients)
    
    /// Asks the upstreams over UDP the same way as `forward`, following a truncated answer to TCP.
    /// Nil if there is no answer (timeout, every send failed, no usable TCP fallback): the caller
    /// turns that into a SERVFAIL.
    public func exchange(dnsPayload: Data) async -> Data? {
        let upstreams = orderedUpstreams()
        guard dnsPayload.count >= 12,
              pendingTransactions.count < config.maxInFlightQueries,
              !upstreams.isEmpty else { return nil }
        let upstreamTxID = allocateNextUpstreamTxID()
        let clientTxID = UInt16(dnsPayload[dnsPayload.startIndex]) << 8 | UInt16(dnsPayload[dnsPayload.startIndex + 1])
        
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            var pending = PendingQuery(
                upstreamTxID: upstreamTxID, clientTxID: clientTxID, ipVersion: .v4,
                clientSrcIPv4: 0, clientDstIPv4: 0, clientSrcIPv6: (0, 0), clientDstIPv6: (0, 0),
                clientSrcPort: 0, clientDstPort: 0,
                requestTimestamp: clock.now, timeoutTask: nil,
                clientQuery: dnsPayload, exchangeContinuation: continuation
            )
            pending.remaining = upstreams
            pending.network = networkKey
            pending.timeoutTask = scheduleTimers(upstreamTxID: upstreamTxID, start: pending.requestTimestamp, hedge: upstreams.count > 1)
            pendingTransactions[upstreamTxID] = pending
            Task { [weak self] in await self?.askNext(upstreamTxID) }
        }
    }
    
    // MARK: - Handling Upstream Response
    
    public func handleUpstreamResponse(data: Data, senderIP: String, senderPort: UInt16, isIPv6: Bool) {
        guard data.count >= 12 else { return }
        
        // Validate source endpoint (protect against rogue/unrelated UDP packets)
        let allowedHosts: [String] = isIPv6
            ? [config.ipv6Address].compactMap { $0 }
            : [config.ipv4Address] + [config.fallbackIPv4Address].compactMap { $0 }
        if !senderIP.isEmpty, !allowedHosts.isEmpty, !allowedHosts.contains(senderIP) {
            counters?.increment(\.answersFromUnexpectedSender)
            return
        }
        if senderPort != 0 && senderPort != config.port {
            counters?.increment(\.answersFromUnexpectedSender)
            return
        }
        
        let upstreamTxID = (UInt16(data[0]) << 8) | UInt16(data[1])
        let responder: UpstreamID
        let source: (answered: WritableKeyPath<DNSTunnelCountersSnapshot, UInt64>, late: WritableKeyPath<DNSTunnelCountersSnapshot, UInt64>)
        if isIPv6 {
            responder = .ipv6
            source = (\.answersFromIPv6, \.lateAnswersFromIPv6)
        } else if let fallback = config.fallbackIPv4Address, senderIP == fallback {
            responder = .fallbackIPv4
            source = (\.answersFromFallbackIPv4, \.lateAnswersFromFallbackIPv4)
        } else {
            responder = .primaryIPv4
            source = (\.answersFromPrimaryIPv4, \.lateAnswersFromPrimaryIPv4)
        }
        guard let pending = pendingTransactions[upstreamTxID], let position = pending.asked.firstIndex(of: responder) else {
            // Already answered by another upstream, timed out, or an id we never sent this one.
            counters?.increment(source.late)
            return
        }
        pendingTransactions.removeValue(forKey: upstreamTxID)
        counters?.increment(source.answered)
        
        pending.timeoutTask?.cancel()
        
        // The winner scores; an upstream asked before it, which had the head start, lost.
        record(responder, success: true, network: pending.network)
        for loser in pending.asked[..<position] { record(loser, success: false, network: pending.network) }
        
        let latencyMs = (clock.now - pending.requestTimestamp) * 1000.0
        DNSForwarderMetrics.logResponseCorrelated(upstreamTxID: upstreamTxID, clientTxID: pending.clientTxID, latencyMs: latencyMs)
        
        // The upstream cut its own answer short: get the whole one over TCP rather than hand the
        // client a truncated answer it would retry over a connection we'd otherwise not answer.
        if DNSMessage.isTruncated(data) {
            counters?.increment(\.truncatedUpstreamAnswers)
            Task { [weak self] in await self?.completeTruncated(pending, from: responder) }
            return
        }
        deliver(data, for: pending)
    }
    
    /// Fetches the whole answer over TCP from the upstream that sent the truncated one: its path
    /// just worked, where another family's may not (IPv4 is lost on some 4G networks).
    private func completeTruncated(_ pending: PendingQuery, from upstream: UpstreamID) async {
        guard let transport = tcpTransport, let host = address(of: upstream) else { return fail(pending) }
        do {
            let full = try await transport.exchange(query: pending.clientQuery, host: host, port: config.port)
            guard full.count >= 12 else {
                counters?.increment(\.upstreamTCPFailed)
                return fail(pending)
            }
            counters?.increment(\.upstreamTCPSucceeded)
            deliver(full, for: pending)
        } catch {
            counters?.increment(\.upstreamTCPFailed)
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
            counters?.increment(\.truncatedToClient)
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
    
    /// One task per query: at the hedge delay it asks the next upstream (if the query is still
    /// waiting and there is one), and at `timeoutSeconds` from `start` it gives up.
    private func scheduleTimers(upstreamTxID: UInt16, start: TimeInterval, hedge: Bool) -> Task<Void, Never> {
        let timeout = config.timeoutSeconds
        let hedgeDelay = hedge ? config.hedgeDelaySeconds.flatMap { $0 < timeout ? $0 : nil } : nil
        let clock = self.clock
        return Task { [weak self] in
            if let hedgeDelay {
                do { try await clock.sleep(seconds: hedgeDelay) } catch { return }
                guard let self, await self.hedge(upstreamTxID: upstreamTxID) else { return }
            }
            let left = start + timeout - clock.now
            if left > 0 {
                guard !Task.isCancelled else { return }
                do { try await clock.sleep(seconds: left) } catch { return }
            }
            await self?.handleTimeout(upstreamTxID: upstreamTxID)
        }
    }
    
    /// The hedge delay passed without an answer: ask the next upstream as well. False once the
    /// query is finished.
    private func hedge(upstreamTxID: UInt16) async -> Bool {
        guard pendingTransactions[upstreamTxID] != nil else { return false }
        await askNext(upstreamTxID)
        return pendingTransactions[upstreamTxID] != nil
    }
    
    private func handleTimeout(upstreamTxID: UInt16) {
        guard let pending = pendingTransactions.removeValue(forKey: upstreamTxID) else { return }
        DNSForwarderMetrics.logQueryTimeout(upstreamTxID: upstreamTxID, clientTxID: pending.clientTxID)
        counters?.increment(\.upstreamTimeouts)
        for upstream in pending.asked { record(upstream, success: false, network: pending.network) }
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
            
            let srcIP = pending.clientDstIPv6
            let dstIP = pending.clientSrcIPv6
            let srcBytes = IPv6Bytes.make(srcIP), dstBytes = IPv6Bytes.make(dstIP)
            for i in 0..<16 {
                base[8 + i] = srcBytes[i]
                base[24 + i] = dstBytes[i]
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
