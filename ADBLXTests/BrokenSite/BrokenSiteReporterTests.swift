// ADBLXTests/BrokenSite/BrokenSiteReporterTests.swift
import XCTest
@testable import ADBLX
import ADBLXShared

final class BrokenSiteReporterTests: XCTestCase {
    private var tempDirectory: URL!
    private var filterStore: FilterStore!
    private var allowlistStore: AllowlistStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        filterStore = FilterStore(overrideBaseURL: tempDirectory)
        allowlistStore = AllowlistStore(store: filterStore)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    // -------------------------------------------------------------
    // Test 1: Strict Domain Sanitization
    // -------------------------------------------------------------
    func testDomainSanitization() throws {
        let reporter = RealBrokenSiteReporter(allowlistStore: allowlistStore)

        // URL with path, query parameters, fragment, and scheme -> eTLD+1
        let sanitized1 = try reporter.sanitizeDomain("https://sub.example.com/some/path?param=secret#header")
        XCTAssertEqual(sanitized1, "example.com")

        // Multi-part ccTLD public suffix (co.uk)
        let sanitized2 = try reporter.sanitizeDomain("https://news.bbc.co.uk:8443/article?id=99#frag")
        XCTAssertEqual(sanitized2, "bbc.co.uk")

        // Multi-part ccTLD public suffix (gov.in)
        let sanitized3 = try reporter.sanitizeDomain("https://portal.service.gov.in/app/login")
        XCTAssertEqual(sanitized3, "service.gov.in")

        // Multi-part hosting platform suffix (github.io)
        let sanitized4 = try reporter.sanitizeDomain("https://docs.github.io/en/get-started")
        XCTAssertEqual(sanitized4, "docs.github.io")

        // Upper-case domain with whitespace
        let sanitized5 = try reporter.sanitizeDomain("   EXAMPLE.ORG   ")
        XCTAssertEqual(sanitized5, "example.org")

        // Disallowed inputs (empty, IP address, localhost)
        XCTAssertThrowsError(try reporter.sanitizeDomain(""))
        XCTAssertThrowsError(try reporter.sanitizeDomain("192.168.1.1"))
        XCTAssertThrowsError(try reporter.sanitizeDomain("localhost"))
    }

    // -------------------------------------------------------------
    // Test 2: Successful Report Submission & Instant Allowlisting
    // -------------------------------------------------------------
    func testSuccessfulReportSubmissionWithAutoAllowlist() async throws {
        let reportEndpoint = URL(string: "https://example.com/api/reports")!

        let mockSession = MockHTTPSession(responses: [
            reportEndpoint: .success((
                Data("{\"status\":\"ok\"}".utf8),
                HTTPURLResponse(url: reportEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            ))
        ])

        let manifestStore = ManifestStore(filterStore: filterStore)
        let sampleManifest = FilterManifest(
            manifestVersion: "2026-08-28",
            entries: [
                FilterManifest.Entry(
                    id: "easylist",
                    name: "EasyList",
                    group: .ads,
                    sourceURL: URL(string: "https://example.com/ads.txt")!,
                    version: "2026.08.28.1",
                    checksumSHA256: "abc",
                    ruleCount: 70000,
                    enabledByDefault: true,
                    premium: false
                )
            ]
        )
        try await manifestStore.save(sampleManifest, etag: "test-etag")

        let reporter = RealBrokenSiteReporter(
            allowlistStore: allowlistStore,
            manifestStore: manifestStore,
            session: mockSession,
            endpoint: reportEndpoint
        )

        let result = try await reporter.submitReport(
            domain: "https://broken-streaming-portal.com/watch?v=123",
            category: .mediaPlaybackFailed,
            notes: "Video player stays black with spinning wheel",
            autoAllowlist: true
        )

        switch result {
        case .success(let reportID, let domain, let allowlisted):
            XCTAssertFalse(reportID.isEmpty)
            XCTAssertEqual(domain, "broken-streaming-portal.com")
            XCTAssertTrue(allowlisted)
        default:
            XCTFail("Expected .success result, got: \(result)")
        }

        // Verify domain was actually added to AllowlistStore
        let allowlistDomains = await allowlistStore.loadDomains()
        XCTAssertTrue(allowlistDomains.contains("broken-streaming-portal.com"))
    }

    // -------------------------------------------------------------
    // Test 3: Network Failure Still Preserves Local Allowlist Recovery
    // -------------------------------------------------------------
    func testNetworkFailurePreservesInstantLocalAllowlist() async throws {
        let reportEndpoint = URL(string: "https://example.com/api/reports")!

        // Simulate 503 Service Unavailable
        let mockSession = MockHTTPSession(responses: [
            reportEndpoint: .success((
                Data("{\"error\":\"service unavailable\"}".utf8),
                HTTPURLResponse(url: reportEndpoint, statusCode: 503, httpVersion: nil, headerFields: nil)!
            ))
        ])

        let reporter = RealBrokenSiteReporter(
            allowlistStore: allowlistStore,
            session: mockSession,
            endpoint: reportEndpoint
        )

        let result = try await reporter.submitReport(
            domain: "https://emergency-banking-app.com/login",
            category: .loginOrFormBroken,
            notes: "2FA submit button unresponsive",
            autoAllowlist: true
        )

        switch result {
        case .allowlistedOnly(let domain, let networkError):
            XCTAssertEqual(domain, "emergency-banking-app.com")
            XCTAssertTrue(networkError.contains("503"))
        default:
            XCTFail("Expected .allowlistedOnly, got: \(result)")
        }

        // Assert local domain allowlist is intact
        let allowlistDomains = await allowlistStore.loadDomains()
        XCTAssertTrue(allowlistDomains.contains("emergency-banking-app.com"))
    }

    // -------------------------------------------------------------
    // Test 4: ViewModel Validation & State Progression
    // -------------------------------------------------------------
    @MainActor
    func testBrokenSiteReportViewModel() async throws {
        let reportEndpoint = URL(string: "https://example.com/api/reports")!
        let mockSession = MockHTTPSession(responses: [
            reportEndpoint: .success((
                Data("{}".utf8),
                HTTPURLResponse(url: reportEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            ))
        ])

        let reporter = RealBrokenSiteReporter(
            allowlistStore: allowlistStore,
            session: mockSession,
            endpoint: reportEndpoint
        )

        let viewModel = BrokenSiteReportViewModel(reporter: reporter, initialDomain: "https://my-test-site.org/index")

        XCTAssertTrue(viewModel.isDomainValid)
        XCTAssertEqual(viewModel.selectedCategory, .pageLayoutBroken)
        XCTAssertTrue(viewModel.autoAllowlist)

        viewModel.selectedCategory = .adsNotBlocked
        viewModel.notesInput = "Sidebar ad continues rendering"

        await viewModel.submit()

        XCTAssertFalse(viewModel.isSubmitting)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.submissionResult)

        if case .success(_, let domain, let allowlisted) = viewModel.submissionResult {
            XCTAssertEqual(domain, "my-test-site.org")
            XCTAssertTrue(allowlisted)
        } else {
            XCTFail("Expected success result in ViewModel")
        }

        // Test Reset
        viewModel.reset()
        XCTAssertEqual(viewModel.domainInput, "")
        XCTAssertNil(viewModel.submissionResult)
    }
}
