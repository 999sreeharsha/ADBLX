import Testing
@testable import ADBLX

@Suite("AppGroup")
struct AppGroupTests {
    @Test("identifier matches the entitlement configured in project.yml")
    func identifierMatchesEntitlement() {
        #expect(AppGroup.identifier == "group.com.ADBLX.shared")
    }
}
