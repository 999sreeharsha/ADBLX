import Foundation
import os

final class DNSBenchmarkSpike {
    private let logger = Logger(subsystem: "com.ADBLX.ADBLX.ADBLXPacketTunnel.Benchmark", category: "GateC")
    
    enum Candidate {
        case setHeap                   // Candidate A
        case compactHeap               // Candidate B
        case compactMmapCopiedIndex    // Candidate C1
        case compactMmapDirectIndex    // Candidate C2
    }
    
    // Loaded structures
    private var baselineSet: Set<String>?
    private var compactData: Data?
    private var copiedOffsets: [UInt32]?
    private var domainCount: UInt32 = 0
    
    // MARK: - Memory Measurement
    
    private func getPeakResidentMemoryMB() -> Double {
        var rusageInfo = rusage()
        getrusage(RUSAGE_SELF, &rusageInfo)
        // ru_maxrss is bytes on Darwin
        return Double(rusageInfo.ru_maxrss) / 1048576.0
    }
    
    private func getResidentMemoryMB() -> Double {
        var info = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size)/4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / 1048576.0
        }
        return 0
    }
    
    // MARK: - Main Runner
    
    func runBenchmark(candidate: Candidate) {
        logger.notice("==================================================")
        logger.notice("--- Starting Benchmark for \(String(describing: candidate), privacy: .public) ---")
        logger.notice("Baseline Resident Memory = \(String(format: "%.2f", self.getResidentMemoryMB()), privacy: .public) MB")
        
        // 1. Load Phase
        let loadStart = mach_absolute_time()
        do {
            try load(candidate: candidate)
        } catch {
            logger.error("Failed to load artifact: \(error.localizedDescription, privacy: .public)")
            return
        }
        let loadEnd = mach_absolute_time()
        
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        let loadNanos = Double(loadEnd - loadStart) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
        let loadSeconds = loadNanos / 1_000_000_000.0
        
        logger.notice("Load/Startup time: \(String(format: "%.3f", loadSeconds), privacy: .public) seconds")
        logger.notice("Peak Construction/Load Memory = \(String(format: "%.2f", self.getPeakResidentMemoryMB()), privacy: .public) MB")
        logger.notice("Post-load Resident Memory = \(String(format: "%.2f", self.getResidentMemoryMB()), privacy: .public) MB")
        
        // 2. Prepare Unified Workload
        let queries = getExpandedWorkload()
        let randomizedQueries = queries.shuffled() // random ordering
        
        // 3. Warmup Phase (not timed)
        for query in randomizedQueries {
            _ = lookup(domain: query, candidate: candidate)
        }
        
        logger.notice("After Warmup Resident Memory = \(String(format: "%.2f", self.getResidentMemoryMB()), privacy: .public) MB")
        
        // 4. Timed Realistic Workload
        let iterations = 1000
        var ticks = [UInt64](repeating: 0, count: randomizedQueries.count * iterations)
        var tickIndex = 0
        
        for _ in 0..<iterations {
            for query in randomizedQueries {
                let startTick = mach_absolute_time()
                _ = lookup(domain: query, candidate: candidate)
                let endTick = mach_absolute_time()
                
                ticks[tickIndex] = endTick - startTick
                tickIndex += 1
            }
        }
        
        // 5. Results Calculation
        let multiplier = Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1000.0 // convert to microseconds
        var latencies = ticks.map { Double($0) * multiplier }
        latencies.sort()
        
        let median = latencies[latencies.count / 2]
        let p95 = latencies[Int(Double(latencies.count) * 0.95)]
        let p99 = latencies[Int(Double(latencies.count) * 0.99)]
        
        logger.notice("Latency (µs): Median=\(String(format: "%.2f", median), privacy: .public), p95=\(String(format: "%.2f", p95), privacy: .public), p99=\(String(format: "%.2f", p99), privacy: .public)")
        logger.notice("Sustained Resident Memory = \(String(format: "%.2f", self.getResidentMemoryMB()), privacy: .public) MB")
        logger.notice("--- Benchmark Complete ---")
        logger.notice("==================================================")
    }
    
    // MARK: - Loading
    
    private func load(candidate: Candidate) throws {
        guard let url = Bundle.main.url(forResource: "dns_artifact", withExtension: "bin") else {
            throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Artifact not found"])
        }
        
        switch candidate {
        case .setHeap:
            let data = try Data(contentsOf: url)
            baselineSet = parseSet(from: data)
            
        case .compactHeap:
            let data = try Data(contentsOf: url) // Pure heap load
            compactData = data
            parseIndex(from: data, copy: true)
            
        case .compactMmapCopiedIndex:
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            compactData = data
            parseIndex(from: data, copy: true)
            
        case .compactMmapDirectIndex:
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            compactData = data
            parseIndex(from: data, copy: false) // No copied arrays!
        }
    }
    
    private func parseSet(from data: Data) -> Set<String> {
        var set = Set<String>()
        var offset = 12
        let count = data[8..<12].withUnsafeBytes { $0.load(as: UInt32.self) }
        offset += Int(count) * 4
        
        var currentString = ""
        while offset < data.count {
            let byte = data[offset]
            if byte == 0 {
                let parts = currentString.split(separator: ".")
                let original = parts.reversed().joined(separator: ".")
                set.insert(original)
                currentString = ""
            } else {
                currentString.append(Character(UnicodeScalar(byte)))
            }
            offset += 1
        }
        return set
    }
    
    private func parseIndex(from data: Data, copy: Bool) {
        domainCount = data[8..<12].withUnsafeBytes { $0.load(as: UInt32.self) }
        
        if copy {
            let offsetsSize = Int(domainCount) * 4
            let offsetsData = data.subdata(in: 12..<(12 + offsetsSize))
            copiedOffsets = offsetsData.withUnsafeBytes { ptr in
                Array(ptr.bindMemory(to: UInt32.self))
            }
        }
    }
    
    // MARK: - Workload
    
    private func getExpandedWorkload() -> [String] {
        return [
            // Exact hits
            "doubleclick.net", "ad.doubleclick.net", "analytics.google.com",
            "pagead2.googlesyndication.com", "graph.facebook.com", "metrics.apple.com",
            "telemetry.apple.com", "securemetrics.apple.com", "api.segment.io",
            // Parent-domain hits (suffix matches)
            "sub.sub.doubleclick.net", "deep.tracking.analytics.google.com",
            // Allowed domains
            "google.com", "www.google.com", "apple.com", "github.com",
            "example.com", "wikipedia.org", "news.ycombinator.com",
            // Near misses
            "doubleclick.net.example.com", "my-analytics.google.com", "google.com.br",
            // Extreme hostnames
            "long-cdn-tracking-hostname.production.us-east-1.amazonaws.com",
            "a.com", "t.co", "x.com"
        ]
    }
    
    // MARK: - Unified Lookup Path
    
    private func lookup(domain: String, candidate: Candidate) -> Bool {
        switch candidate {
        case .setHeap:
            // Baseline String operations
            let parts = domain.split(separator: ".")
            for i in 0..<parts.count {
                let suffix = parts[i...].joined(separator: ".")
                if baselineSet?.contains(suffix) == true {
                    return true
                }
            }
            return false
            
        case .compactHeap, .compactMmapCopiedIndex, .compactMmapDirectIndex:
            // Zero-allocation suffix extraction for the binary search representations
            let parts = domain.split(separator: ".")
            let reversedSuffix = parts.reversed().joined(separator: ".")
            let searchBytes = Array(reversedSuffix.utf8)
            
            var checkLen = 0
            while checkLen <= searchBytes.count {
                if checkLen == searchBytes.count || searchBytes[checkLen] == 46 /* '.' */ {
                    // searchBytes[0..<checkLen] is a reversed suffix
                    let match = searchBytes.withUnsafeBufferPointer { ptr -> Bool in
                        let prefixBuf = UnsafeBufferPointer(start: ptr.baseAddress, count: checkLen)
                        return binarySearch(target: prefixBuf, candidate: candidate)
                    }
                    if match { return true }
                }
                checkLen += 1
            }
            return false
        }
    }
    
    private func binarySearch(target: UnsafeBufferPointer<UInt8>, candidate: Candidate) -> Bool {
        guard let data = compactData, domainCount > 0 else { return false }
        
        let offsetsStart = 12
        let blobStart = offsetsStart + Int(domainCount) * 4
        
        return data.withUnsafeBytes { rawPtr -> Bool in
            let base = rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            var low = 0
            var high = Int(domainCount) - 1
            
            while low <= high {
                let mid = low + (high - low) / 2
                
                let offset: UInt32
                if candidate == .compactMmapDirectIndex {
                    // C2: Direct pointer read from mapped memory, no array lookup
                    let offsetPtr = rawPtr.baseAddress!.advanced(by: offsetsStart + mid * 4).assumingMemoryBound(to: UInt32.self)
                    offset = offsetPtr.pointee
                } else {
                    // B, C1: Read from copied array
                    guard let copiedOffsets = copiedOffsets else { return false }
                    offset = copiedOffsets[mid]
                }
                
                let startIdx = blobStart + Int(offset)
                
                // Zero-allocation memory comparison
                var curr = startIdx
                var i = 0
                var isLess = false
                var isGreater = false
                
                while i < target.count && curr < data.count && base[curr] != 0 {
                    let sb = target[i]
                    let mb = base[curr]
                    if sb < mb { isLess = true; break }
                    if sb > mb { isGreater = true; break }
                    i += 1
                    curr += 1
                }
                
                if isLess {
                    high = mid - 1
                } else if isGreater {
                    low = mid + 1
                } else {
                    let targetEnded = (i == target.count)
                    let midEnded = (curr >= data.count || base[curr] == 0)
                    
                    if targetEnded && midEnded {
                        return true
                    } else if targetEnded {
                        high = mid - 1
                    } else {
                        low = mid + 1
                    }
                }
            }
            return false
        }
    }
}
