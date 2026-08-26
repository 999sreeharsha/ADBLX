import Foundation
import Network

public protocol DNSUpstreamSocketProtocol: AnyObject, Sendable {
    func send(payload: Data) async throws
    func setResponseHandler(_ handler: @escaping @Sendable (Data, String, UInt16) -> Void)
    func close()
}

/// Production reusable BSD UDP socket with DispatchSourceRead for asynchronous zero-overhead response reception
public final class BSDUDPUpstreamSocket: DNSUpstreamSocketProtocol, @unchecked Sendable {
    private var fileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.ADBLX.ADBLX.UpstreamSocketQueue", qos: .userInitiated)
    private var responseHandler: (@Sendable (Data, String, UInt16) -> Void)?
    private let isIPv6: Bool
    private let targetHost: String
    private let targetPort: UInt16
    
    public init(host: String, port: UInt16 = 53, isIPv6: Bool = false) throws {
        self.targetHost = host
        self.targetPort = port
        self.isIPv6 = isIPv6
        
        let fd = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to create socket: \(errno)"])
        }
        
        // Set non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        
        self.fileDescriptor = fd
        setupReadSource()
    }
    
    public func setResponseHandler(_ handler: @escaping @Sendable (Data, String, UInt16) -> Void) {
        queue.async {
            self.responseHandler = handler
        }
    }
    
    public func send(payload: Data) async throws {
        guard fileDescriptor >= 0 else {
            throw NSError(domain: "DNSUpstreamSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Socket is closed"])
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                var sent: Int = 0
                if self.isIPv6 {
                    var sin6 = sockaddr_in6()
                    sin6.sin6_family = sa_family_t(AF_INET6)
                    sin6.sin6_port = self.targetPort.bigEndian
                    _ = self.targetHost.withCString { inet_pton(AF_INET6, $0, &sin6.sin6_addr) }
                    
                    payload.withUnsafeBytes { raw in
                        withUnsafePointer(to: &sin6) { addrPtr in
                            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                sent = sendto(self.fileDescriptor, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                            }
                        }
                    }
                } else {
                    var sin = sockaddr_in()
                    sin.sin_family = sa_family_t(AF_INET)
                    sin.sin_port = self.targetPort.bigEndian
                    _ = self.targetHost.withCString { inet_pton(AF_INET, $0, &sin.sin_addr) }
                    
                    payload.withUnsafeBytes { raw in
                        withUnsafePointer(to: &sin) { addrPtr in
                            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                sent = sendto(self.fileDescriptor, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
                
                if sent >= 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil))
                }
            }
        }
    }
    
    private func setupReadSource() {
        guard fileDescriptor >= 0 else { return }
        
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self, self.fileDescriptor >= 0 else { return }
            
            var buffer = [UInt8](repeating: 0, count: 4096)
            var srcAddr = sockaddr_storage()
            var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            
            let bytesRead = withUnsafeMutablePointer(to: &srcAddr) { saPtr -> Int in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(self.fileDescriptor, &buffer, buffer.count, 0, sa, &addrLen)
                }
            }
            
            if bytesRead > 0 {
                var senderIP = ""
                var senderPort: UInt16 = 0
                if srcAddr.ss_family == sa_family_t(AF_INET) {
                    withUnsafePointer(to: &srcAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                            var addrBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            var inAddr = sin.pointee.sin_addr
                            inet_ntop(AF_INET, &inAddr, &addrBuf, socklen_t(addrBuf.count))
                            senderIP = String(cString: addrBuf)
                            senderPort = UInt16(bigEndian: sin.pointee.sin_port)
                        }
                    }
                } else if srcAddr.ss_family == sa_family_t(AF_INET6) {
                    withUnsafePointer(to: &srcAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                            var addrBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                            var in6Addr = sin6.pointee.sin6_addr
                            inet_ntop(AF_INET6, &in6Addr, &addrBuf, socklen_t(addrBuf.count))
                            senderIP = String(cString: addrBuf)
                            senderPort = UInt16(bigEndian: sin6.pointee.sin6_port)
                        }
                    }
                }
                
                let data = Data(buffer[0..<bytesRead])
                self.responseHandler?(data, senderIP, senderPort)
            }
        }
        
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                Darwin.close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        
        self.readSource = source
        source.resume()
    }
    
    public func close() {
        queue.async {
            self.readSource?.cancel()
            self.readSource = nil
            self.responseHandler = nil
        }
    }
    
    deinit {
        close()
    }
}
