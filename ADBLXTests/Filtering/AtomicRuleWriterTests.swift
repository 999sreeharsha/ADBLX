// ADBLXTests/Filtering/AtomicRuleWriterTests.swift
import Testing
import Foundation
@testable import ADBLX

private struct FailingFilesystem: AtomicFilesystem {
    enum FailAt {
        case write, fsync, replace
    }

    enum InjectedError: Error {
        case injected
    }

    let failAt: FailAt

    func write(_ data: Data, to url: URL) throws {
        if failAt == .write { throw InjectedError.injected }
        try data.write(to: url, options: .atomic)
    }

    func fsync(atPath path: String) throws {
        if failAt == .fsync { throw InjectedError.injected }
    }

    func replace(_ destination: URL, with tempURL: URL) throws {
        if failAt == .replace { throw InjectedError.injected }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
    }
}

@Suite("AtomicRuleWriter")
struct AtomicRuleWriterTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("writes data to destination via the real filesystem")
    func happyPath() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appendingPathComponent("rules.json")
        let writer = AtomicRuleWriter()
        try writer.write(Data("[]".utf8), to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: destination) == Data("[]".utf8))
    }

    @Test("fsync failure leaves the prior committed file intact and cleans up the temp file")
    func fsyncFailureLeavesOldFileIntact() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appendingPathComponent("rules.json")
        try Data("[\"old\"]".utf8).write(to: destination)

        let writer = AtomicRuleWriter(filesystem: FailingFilesystem(failAt: .fsync))
        #expect(throws: (any Error).self) {
            try writer.write(Data("[\"new\"]".utf8), to: destination)
        }

        #expect(try Data(contentsOf: destination) == Data("[\"old\"]".utf8))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == ["rules.json"])
    }

    @Test("replace failure leaves the prior committed file intact and cleans up the temp file")
    func replaceFailureLeavesOldFileIntact() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appendingPathComponent("rules.json")
        try Data("[\"old\"]".utf8).write(to: destination)

        let writer = AtomicRuleWriter(filesystem: FailingFilesystem(failAt: .replace))
        #expect(throws: (any Error).self) {
            try writer.write(Data("[\"new\"]".utf8), to: destination)
        }

        #expect(try Data(contentsOf: destination) == Data("[\"old\"]".utf8))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == ["rules.json"])
    }
}
