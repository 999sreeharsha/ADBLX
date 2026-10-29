import Testing
import Foundation
@testable import ADBLX

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ event: String) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct GateTestError: Error {}

@Suite("FilterTransactionGate")
struct FilterTransactionGateTests {
    @Test("bodies never interleave: each runs start then end before the next starts")
    func serializes() async {
        let gate = FilterTransactionGate()
        let recorder = EventRecorder()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                group.addTask {
                    await gate.run {
                        recorder.add("start\(index)")
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        recorder.add("end\(index)")
                    }
                }
            }
        }
        let events = recorder.events
        #expect(events.count == 10)
        for pair in stride(from: 0, to: 10, by: 2) {
            #expect(events[pair].hasPrefix("start"))
            #expect(events[pair + 1] == "end" + events[pair].dropFirst(5))
        }
    }

    @Test("a throwing body releases the gate")
    func releasesOnThrow() async {
        let gate = FilterTransactionGate()
        await #expect(throws: GateTestError.self) { try await gate.run { throw GateTestError() } }
        let value = await gate.run { 42 }
        #expect(value == 42)
    }
}
