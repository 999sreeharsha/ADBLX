import XCTest
@testable import ADBLXShared

final class ABPLexerTests: XCTestCase {
    func testLexEmptyAndWhitespaceLines() {
        XCTAssertEqual(ABPLexer.lex(line: ""), .empty)
        XCTAssertEqual(ABPLexer.lex(line: "   \t\r\n"), .empty)
    }
    
    func testLexCommentsAndHeaders() {
        XCTAssertEqual(ABPLexer.lex(line: "! Title: EasyList"), .comment("! Title: EasyList"))
        XCTAssertEqual(ABPLexer.lex(line: "[Adblock Plus 2.0]"), .comment("[Adblock Plus 2.0]"))
        XCTAssertEqual(ABPLexer.lex(line: "# Host file comment"), .comment("# Host file comment"))
    }
    
    func testLexStandardNetworkBlockRules() {
        let line1 = ABPLexer.lex(line: "||doubleclick.net^")
        XCTAssertEqual(line1, .network(isException: false, rawPattern: "||doubleclick.net^", rawOptions: []))
        
        let line2 = ABPLexer.lex(line: "||ads.example.com^$third-party,script")
        XCTAssertEqual(line2, .network(isException: false, rawPattern: "||ads.example.com^", rawOptions: ["third-party", "script"]))
        
        let line3 = ABPLexer.lex(line: "/banner_*/$image,~third-party")
        XCTAssertEqual(line3, .network(isException: false, rawPattern: "/banner_*/", rawOptions: ["image", "~third-party"]))
    }
    
    func testLexNetworkExceptions() {
        let line1 = ABPLexer.lex(line: "@@||example.com^")
        XCTAssertEqual(line1, .network(isException: true, rawPattern: "||example.com^", rawOptions: []))
        
        let line2 = ABPLexer.lex(line: "@@||news.com^$document,domain=news.com")
        XCTAssertEqual(line2, .network(isException: true, rawPattern: "||news.com^", rawOptions: ["document", "domain=news.com"]))
    }
    
    func testLexStandardCosmeticRules() {
        let line1 = ABPLexer.lex(line: "##.ad-banner")
        XCTAssertEqual(line1, .cosmetic(isException: false, isProcedural: false, isScriptlet: false, rawDomains: "", rawBody: ".ad-banner"))
        
        let line2 = ABPLexer.lex(line: "example.com##.sponsor")
        XCTAssertEqual(line2, .cosmetic(isException: false, isProcedural: false, isScriptlet: false, rawDomains: "example.com", rawBody: ".sponsor"))
        
        let line3 = ABPLexer.lex(line: "foo.com,bar.com##div[id^=\"ad-\"]")
        XCTAssertEqual(line3, .cosmetic(isException: false, isProcedural: false, isScriptlet: false, rawDomains: "foo.com,bar.com", rawBody: "div[id^=\"ad-\"]"))
    }
    
    func testLexCosmeticExceptions() {
        let line = ABPLexer.lex(line: "example.com#@#.ad-banner")
        XCTAssertEqual(line, .cosmetic(isException: true, isProcedural: false, isScriptlet: false, rawDomains: "example.com", rawBody: ".ad-banner"))
    }
    
    func testLexScriptletsAndProceduralCosmeticRules() {
        let line1 = ABPLexer.lex(line: "example.com##+js(set, foo, true)")
        XCTAssertEqual(line1, .cosmetic(isException: false, isProcedural: false, isScriptlet: true, rawDomains: "example.com", rawBody: "+js(set, foo, true)"))
        
        let line2 = ABPLexer.lex(line: "example.com#?#div:has(> .ad)")
        XCTAssertEqual(line2, .cosmetic(isException: false, isProcedural: true, isScriptlet: false, rawDomains: "example.com", rawBody: "div:has(> .ad)"))
    }
}
