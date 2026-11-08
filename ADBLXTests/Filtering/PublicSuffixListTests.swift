import Testing
@testable import ADBLX

/// An allowlisted domain covers every site under it, so a registrable domain that is too short
/// turns off blocking for unrelated sites (SEC-10). When the suffix isn't known, the full host
/// is kept: narrower, never wider.
@Suite("PublicSuffixList")
struct PublicSuffixListTests {
    @Test("Known suffixes and ordinary domains give the registrable domain", arguments: [
        ("news.bbc.co.uk", "bbc.co.uk"),
        ("shop.example.co.in", "example.co.in"),
        ("api.v1.example.com", "example.com"),
        ("example.com", "example.com"),
        ("docs.github.io", "docs.github.io"),
        ("shop.example.de", "example.de"),
        ("WWW.Example.COM", "example.com")
    ])
    func knownSuffixes(host: String, expected: String) {
        #expect(PublicSuffixList.extractETLDPlusOne(from: host) == expected)
    }

    // `co.kr` and friends aren't in the curated set: the last two labels would be the suffix
    // itself, allowlisting every site in it.
    @Test("An unknown registry suffix under a country code keeps the full host", arguments: [
        ("shop.example.co.kr", "shop.example.co.kr"),
        ("www.example.co.id", "www.example.co.id"),
        ("m.example.com.cn", "m.example.com.cn"),
        ("tienda.example.com.mx", "tienda.example.com.mx"),
        ("a.example.org.tr", "a.example.org.tr"),
        ("portal.example.gov.ph", "portal.example.gov.ph"),
        ("lib.example.ac.th", "lib.example.ac.th"),
        ("example.or.kr", "example.or.kr")
    ])
    func unknownRegistrySuffixKeepsTheHost(host: String, expected: String) {
        #expect(PublicSuffixList.extractETLDPlusOne(from: host) == expected)
    }

    @Test("Public suffixes are recognised, registrable domains aren't", arguments: [
        ("com", true), ("co.uk", true), ("github.io", true), ("co.kr", true), ("com.mx", true),
        ("example.com", false), ("example.co.uk", false), ("user.github.io", false), ("example.de", false)
    ])
    func publicSuffixes(host: String, expected: Bool) {
        #expect(PublicSuffixList.isPublicSuffix(host) == expected)
    }

    @Test("The result is never a bare registry suffix", arguments: ["x.co.kr", "y.com.mx", "z.ac.th"])
    func neverABareSuffix(host: String) {
        let result = PublicSuffixList.extractETLDPlusOne(from: host)
        #expect(result.split(separator: ".").count >= 3, "\(host) became \(result)")
    }
}
