import Foundation
import os
import ADBLXShared

public enum DNSLookupVerdict: Equatable {
    case allow
    case block
}

public final class DNSLookupEngine {
    private let snapshotLock: OSAllocatedUnfairLock<DNSLookupSnapshot>
    
    public init(initialSnapshot: DNSLookupSnapshot = .makeEmptySnapshot()) {
        self.snapshotLock = OSAllocatedUnfairLock(initialState: initialSnapshot)
    }
    
    public var activeGeneration: UInt64 {
        snapshotLock.withLock { $0.generation }
    }
    
    public var activeSnapshot: DNSLookupSnapshot {
        snapshotLock.withLock { $0 }
    }
    
    /// Atomically replaces the active lookup snapshot.
    public func swapSnapshot(_ newSnapshot: DNSLookupSnapshot) {
        snapshotLock.withLock { snapshot in
            snapshot = newSnapshot
        }
    }
    
    // MARK: - Hot Path Lookup (Zero Heap Allocations on Wire Bytes)
    
    /// Evaluates a domain query using reversed-label suffix walk.
    ///
    /// - Parameter reversedBytes: Contiguous UTF-8 buffer of the label-reversed domain (e.g. `net.doubleclick.ad`).
    /// - Returns: `DNSLookupVerdict.allow` or `DNSLookupVerdict.block`.
    public func lookup(reversedBytes: UnsafeBufferPointer<UInt8>) -> DNSLookupVerdict {
        // Obtain immutable snapshot reference without long-held locks or heap allocations
        let snapshot = snapshotLock.withLock { $0 }
        
        guard reversedBytes.count > 0, let baseAddress = reversedBytes.baseAddress else {
            return .allow
        }
        
        // 1. Step 1: Check Allowlist Overlay FIRST (Allowlist short-circuits blocklist)
        var checkLen = 0
        while checkLen <= reversedBytes.count {
            if checkLen == reversedBytes.count || reversedBytes[checkLen] == 46 /* '.' */ {
                let prefixBuf = UnsafeBufferPointer(start: baseAddress, count: checkLen)
                if snapshot.allowlist.contains(target: prefixBuf) {
                    return .allow
                }
            }
            checkLen += 1
        }
        
        // 2. Step 2: Check C2 Blocklist
        checkLen = 0
        while checkLen <= reversedBytes.count {
            if checkLen == reversedBytes.count || reversedBytes[checkLen] == 46 /* '.' */ {
                let prefixBuf = UnsafeBufferPointer(start: baseAddress, count: checkLen)
                if snapshot.blocklist.contains(target: prefixBuf) {
                    return .block
                }
            }
            checkLen += 1
        }
        
        // 3. Step 3: Default Allow (Pass-Through)
        return .allow
    }
    
    /// Helper for string queries (reverses labels into stack/heap buffer and delegates to pointer lookup).
    public func lookup(domain: String) -> DNSLookupVerdict {
        let parts = domain.split(separator: ".")
        let reversedSuffix = parts.reversed().joined(separator: ".")
        let utf8Bytes = Array(reversedSuffix.utf8)
        
        return utf8Bytes.withUnsafeBufferPointer { ptr in
            lookup(reversedBytes: ptr)
        }
    }
}
