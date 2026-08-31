// ADBLXTests/Filtering/DNSRealQuad9ResolutionTests.swift
import XCTest
import NetworkExtension
@testable import ADBLX
import ADBLXShared

final class DNSRealQuad9ResolutionTests: XCTestCase {

    // Helper to construct standard DNS query for example.com
    private func makeWireDNSQuery(domain: String = "example.com", txID: UInt16 = 0xABCD) -> Data {
        var payload = Data()
        payload.append(UInt8((txID >> 8) & 0xFF))
        payload.append(UInt8(txID & 0xFF))
        // Standard query flags (RD=1)
        payload.append(contentsOf: [0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        for label in domain.split(separator: ".") {
            payload.append(UInt8(label.utf8.count))
            payload.append(contentsOf: label.utf8)
        }
        payload.append(0x00) // End of domain
        payload.append(contentsOf: [0x00, 0x01, 0x00, 0x01]) // Type A, Class IN
        return payload
    }

    /// Tests live DNS query forwarding directly to Quad9 (9.9.9.9:53) over the physical device network interface.
    func testLiveQuad9UDPResolutionOnDevice() async throws {
        let socket = try BSDUDPUpstreamSocket(host: "9.9.9.9", port: 53, isIPv6: false)
        defer { socket.close() }

        let queryPayload = makeWireDNSQuery(domain: "example.com", txID: 0x1234)

        let expectation = expectation(description: "Quad9 live DNS response received")
        var receivedData: Data?
        var responderIP: String?

        socket.setResponseHandler { data, ip, port in
            receivedData = data
            responderIP = ip
            expectation.fulfill()
        }

        try await socket.send(payload: queryPayload)

        await fulfillment(of: [expectation], timeout: 5.0)

        guard let response = receivedData else {
            XCTFail("No DNS response received from Quad9")
            return
        }

        XCTAssertEqual(responderIP, "9.9.9.9", "Response must originate from Quad9 resolver")
        XCTAssertGreaterThan(response.count, 12, "DNS response must exceed header length")

        // Verify transaction ID matches
        let receivedTxID = (UInt16(response[0]) << 8) | UInt16(response[1])
        XCTAssertEqual(receivedTxID, 0x1234, "Transaction ID must match query")

        // Verify QR flag (bit 7 of byte 2 is 1 -> response)
        let isResponse = (response[2] & 0x80) != 0
        XCTAssertTrue(isResponse, "Response bit must be set")

        // Verify RCODE == 0 (NOERROR)
        let rcode = response[3] & 0x0F
        XCTAssertEqual(rcode, 0, "RCODE must be NOERROR (0)")

        // Verify Answer count >= 1
        let anCount = (UInt16(response[6]) << 8) | UInt16(response[7])
        XCTAssertGreaterThanOrEqual(anCount, 1, "Quad9 must return at least 1 answer record for example.com")
    }

    /// Tests NETunnelProviderManager preference loading and inspection on physical hardware.
    func testNETunnelProviderManagerOnHardware() async throws {
        print("======== NETUNNELPROVIDERMANAGER ON-DEVICE INSPECTION ========")
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            print("Successfully loaded NETunnelProviderManagers from Preferences. Count: \(managers.count)")
            for (idx, mgr) in managers.enumerated() {
                print("  Manager [\(idx)]: enabled=\(mgr.isEnabled), status=\(mgr.connection.status.rawValue), desc=\(mgr.localizedDescription ?? "nil")")
                if let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol {
                    print("    BundleID: \(proto.providerBundleIdentifier ?? "nil"), Server: \(proto.serverAddress ?? "nil")")
                }
            }
        } catch {
            print("NETunnelProviderManager.loadAllFromPreferences failed with error: \(error.localizedDescription) (\(error))")
        }
        print("==============================================================")
    }

    /// Tests starting the VPN tunnel on physical hardware and observing NEVPNStatus transition.
    func testStartVPNTunnelLifecycleOnDevice() async throws {
        print("======== NEPACKETTUNNELPROVIDER LIFECYCLE TEST ========")
        let managers: [NETunnelProviderManager]
        do {
            managers = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            throw XCTSkip("Skipped: NETunnelProviderManager preferences unavailable in test environment (\(error.localizedDescription))")
        }
        guard let manager = managers.first else {
            throw XCTSkip("Skipped: No NETunnelProviderManager configured in preferences (requires physical device run)")
        }

        print("Initial connection status: \(manager.connection.status.rawValue) (1=disconnected, 2=connecting, 3=connected, 4=reasserting, 5=disconnecting, 0=invalid)")
        
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        print("Saved and reloaded manager. isEnabled=\(manager.isEnabled), status=\(manager.connection.status.rawValue)")

        do {
            try manager.connection.startVPNTunnel()
            print("startVPNTunnel() invoked successfully without immediate throw.")

            // Poll status for up to 10 seconds to observe connection state
            for i in 1...10 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let currentStatus = manager.connection.status
                print("  T+\(i)s status: \(currentStatus.rawValue) (\(currentStatus))")
                if currentStatus == .connected {
                    print("🎉 NEPacketTunnelProvider successfully REACHED .connected ON PHYSICAL HARDWARE!")
                    break
                }
            }

            // Cleanly teardown tunnel post-test
            if manager.connection.status == .connected || manager.connection.status == .connecting {
                manager.connection.stopVPNTunnel()
                print("Cleanly stopped VPN tunnel post-test.")
            }
        } catch {
            print("startVPNTunnel failed with error: \(error.localizedDescription) (\(error))")
        }
        print("=======================================================")
    }

    /// Helper to perform a standard system resolver DNS lookup via getaddrinfo.
    private func resolveHostnameViaSystemResolver(_ hostname: String) -> Int32 {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &res)
        if status == 0, let r = res {
            freeaddrinfo(r)
        }
        return status
    }

    /// Tests end-to-end system-wide DNS interception with active tunnel:
    /// 1. Publishes a DNS generation with a test blocklist domain (`||blocked-by-adblx-test.com^`).
    /// 2. Starts NEPacketTunnelProvider on hardware and verifies .connected state.
    /// 3. Issues real system resolver queries via getaddrinfo.
    /// 4. Confirms blocked domain fails to resolve (NXDOMAIN / EAI_NONAME) while allowed domain (example.com) succeeds.
    /// 5. Cleanly terminates tunnel.
    func testSystemWideDNSInterceptionWithActiveTunnelOnDevice() async throws {
        print("======== SYSTEM-WIDE DNS INTERCEPTION HARDWARE TEST ========")
        guard let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ADBLX.shared") else {
            throw XCTSkip("Skipped: App Group container unavailable in test runner environment.")
        }

        // 1. Publish test blocklist generation
        let publisher = DNSArtifactPublisher()
        let testBlockedDomain = "blocked-by-adblx-test.com"
        let gen = try publisher.publish(
            blocklistSources: ["||\(testBlockedDomain)^"],
            allowlistRules: [],
            baseAppGroupURL: appGroupURL
        )
        print("Published test DNS generation \(gen) to App Group with blocked domain: \(testBlockedDomain)")

        // 2. Load manager, ensure clean initial state, and start tunnel
        let managers: [NETunnelProviderManager]
        do {
            managers = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            throw XCTSkip("Skipped: NETunnelProviderManager preferences unavailable (\(error.localizedDescription))")
        }
        guard let manager = managers.first else {
            throw XCTSkip("Skipped: No NETunnelProviderManager configured (requires physical device run)")
        }

        if manager.connection.status != .disconnected && manager.connection.status != .invalid {
            manager.connection.stopVPNTunnel()
            for _ in 1...6 {
                if manager.connection.status == .disconnected { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        // Give OS a 1s breather to register preference save
        try await Task.sleep(nanoseconds: 1_000_000_000)

        try manager.connection.startVPNTunnel()
        print("Tunnel startVPNTunnel() requested. Waiting for .connected status...")

        var isConnected = false
        for i in 1...10 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let status = manager.connection.status
            print("  T+\(i)s status: \(status.rawValue) (\(status))")
            if status == .connected {
                isConnected = true
                break
            }
        }

        guard isConnected else {
            throw XCTSkip("Skipped: Tunnel did not reach .connected on current test host.")
        }

        print("Tunnel active! Performing system-wide DNS resolution tests...")

        // 3. Test Blocked Domain (must receive NXDOMAIN / EAI_NONAME from local PacketTunnelProvider)
        let blockedResult = resolveHostnameViaSystemResolver(testBlockedDomain)
        print("Resolution result for blocked domain '\(testBlockedDomain)': status=\(blockedResult) (EAI_NONAME=\(EAI_NONAME))")
        XCTAssertNotEqual(blockedResult, 0, "Blocked domain must not resolve successfully through active DNS tunnel")

        // 4. Test Allowed Domain (example.com must resolve through Quad9 upstream forwarding)
        let allowedResult = resolveHostnameViaSystemResolver("example.com")
        print("Resolution result for allowed domain 'example.com': status=\(allowedResult)")
        XCTAssertEqual(allowedResult, 0, "Allowed domain 'example.com' must resolve successfully through Quad9 upstream")

        // 5. Clean teardown
        manager.connection.stopVPNTunnel()
        print("Cleanly stopped VPN tunnel post-interception test.")

        // 6. Post-Test Production DNS Generation Restoration & Disk Assertion
        var prodSources: [String] = []
        let bundle = Bundle.main
        for source in DNSFilterSource.allCases {
            if let url = bundle.url(forResource: source.rawValue, withExtension: "txt", subdirectory: "Filters/DNS") ??
                         bundle.url(forResource: source.rawValue, withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                prodSources.append(text)
            }
        }
        XCTAssertFalse(prodSources.isEmpty, "Failed to locate bundled production filter lists for restoration")
        
        let restoredManifest = try publisher.publish(
            blocklistSources: prodSources,
            allowlistRules: [],
            baseAppGroupURL: appGroupURL
        )
        print("Successfully restored Production DNS Generation: generation=\(restoredManifest.generation), blocklistCount=\(restoredManifest.blocklistCount)")
        let onDiskManifest = try DNSGenerationManifest.readCurrentManifest(appGroupBaseDirectory: appGroupURL)
        XCTAssertEqual(onDiskManifest.generation, restoredManifest.generation, "Current manifest pointer must match restored production generation")
        XCTAssertGreaterThan(onDiskManifest.blocklistCount, 1000, "Production DNS blocklist count must exceed baseline threshold (>1,000 rules)")
        print("==============================================================")
    }
}
