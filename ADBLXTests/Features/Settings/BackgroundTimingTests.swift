#if DEBUG
import Testing
import Foundation
@testable import ADBLX

/// The timing spike's measuring code. The simulator only checks that it measures the right
/// things; the numbers that decide the design come from a phone, inside a real background task.
@Suite("Background timing spike")
struct BackgroundTimingTests {
    private let manifestURL = URL(string: "https://example.com/manifest.json")!
    private let easylistURL = URL(string: "https://example.com/filters/ads/easylist.txt")!
    private let privacyURL = URL(string: "https://example.com/filters/privacy/easyprivacy.txt")!
    private let context = TimingContext(
        trigger: "test", appState: "background", lowPowerMode: true,
        thermalState: "nominal", network: "cellular", device: "iPhone14,7"
    )

    @Test("a download run times the manifest and each list, with their sizes")
    func downloadRunTimesEachStep() async throws {
        let easylist = Data(repeating: 0x61, count: 3_000)
        let privacy = Data(repeating: 0x62, count: 1_000)
        let session = try mockSession(lists: [(easylistURL, easylist, 200), (privacyURL, privacy, 200)])

        let run = await DownloadTimer(session: session, manifestURL: manifestURL).run(context: context)

        #expect(run.kind == .download)
        #expect(run.steps.map(\.name) == ["manifest", "easylist", "easyprivacy"])
        #expect(run.steps.dropFirst().map(\.bytes) == [3_000, 1_000])
        #expect(run.steps.allSatisfy { $0.error == nil && $0.seconds >= 0 })
        #expect(run.context == context)
        #expect(!run.expired)
    }

    @Test("a list that fails is recorded and the run goes on")
    func failedListIsRecorded() async throws {
        let session = try mockSession(lists: [(easylistURL, Data(), 404), (privacyURL, Data(repeating: 0x62, count: 10), 200)])

        let run = await DownloadTimer(session: session, manifestURL: manifestURL).run(context: context)

        #expect(run.steps.map(\.name) == ["manifest", "easylist", "easyprivacy"])
        #expect(run.steps[1].error != nil)
        #expect(run.steps[2].error == nil)
    }

    @Test("a cancelled run stops between lists and says it expired")
    func cancelledRunStops() async throws {
        let session = try mockSession(lists: [(easylistURL, Data(repeating: 0x61, count: 10), 200), (privacyURL, Data(), 200)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await DownloadTimer(session: session, manifestURL: manifestURL).run(context: context)
        }

        let run = await task.value

        #expect(run.expired)
        #expect(run.steps.count < 3)
    }

    @Test("a compile run times each group into a scratch store")
    func compileRunTimesEachGroup() async throws {
        let rules = Data("||ads.example.com^\n||tracker.example.net^\n".utf8)

        let run = await CompileTimer(sources: [(.ads, "easylist", rules), (.privacy, "easyprivacy", rules)]).run(context: context)

        #expect(run.kind == .compile)
        #expect(run.steps.map(\.name) == ["ads", "privacy"])
        #expect(run.steps.allSatisfy { $0.error == nil })
        #expect(run.steps.allSatisfy { ($0.rules ?? 0) > 0 })
    }

    @Test("the log keeps the newest runs, across launches")
    func logKeepsNewestRuns() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("timing-\(UUID().uuidString).json")
        let log = TimingLog(fileURL: file)
        for index in 0..<(TimingLog.limit + 3) {
            await log.append(TimingRun(kind: .download, startedAt: Date(timeIntervalSince1970: Double(index)), context: context, steps: []))
        }

        let reopened = await TimingLog(fileURL: file).runs()

        #expect(reopened.count == TimingLog.limit)
        #expect(reopened.first?.startedAt == Date(timeIntervalSince1970: Double(TimingLog.limit + 2)))
    }

    @Test("the summary names the conditions the run was measured under")
    func summaryNamesConditions() {
        let run = TimingRun(kind: .download, startedAt: Date(timeIntervalSince1970: 0), context: context, steps: [
            TimingStep(name: "manifest", seconds: 0.4),
            TimingStep(name: "easylist", seconds: 6.25, bytes: 2_060_000)
        ])

        let summary = run.summary

        #expect(summary.contains("download 6.65 s"))
        #expect(summary.contains("background"))
        #expect(summary.contains("cellular"))
        #expect(summary.contains("Low Power"))
        #expect(summary.contains("easylist 6.25 s 2.06 MB"))
    }

    private func mockSession(lists: [(URL, Data, Int)]) throws -> MockHTTPSession {
        let entries = lists.map { url, data, _ in
            FilterManifest.Entry(
                id: url.deletingPathExtension().lastPathComponent, name: url.lastPathComponent,
                group: url.pathComponents.contains("ads") ? .ads : .privacy, sourceURL: url,
                version: "1", checksumSHA256: Checksum.sha256Hex(of: data), ruleCount: 1,
                enabledByDefault: true, premium: false
            )
        }
        let manifest = try JSONEncoder().encode(FilterManifest(manifestVersion: SignedManifests.version, entries: entries))
        var responses: [URL: Result<(Data, URLResponse), Error>] = [
            manifestURL: .success((manifest, HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        ]
        for (url, data, status) in lists {
            responses[url] = .success((data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!))
        }
        return MockHTTPSession(responses: responses)
    }
}
#endif
