import Foundation

public struct SafariContentBlockerRule: Codable, Equatable, Sendable {
    public struct Trigger: Codable, Equatable, Sendable {
        public var urlFilter: String
        public var urlFilterIsCaseSensitive: Bool?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?
        public var resourceType: [String]?
        public var loadType: [String]?
        
        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case resourceType = "resource-type"
            case loadType = "load-type"
        }
        
        public init(
            urlFilter: String = ".*",
            urlFilterIsCaseSensitive: Bool? = nil,
            ifDomain: [String]? = nil,
            unlessDomain: [String]? = nil,
            resourceType: [String]? = nil,
            loadType: [String]? = nil
        ) {
            self.urlFilter = urlFilter
            self.urlFilterIsCaseSensitive = urlFilterIsCaseSensitive
            self.ifDomain = ifDomain
            self.unlessDomain = unlessDomain
            self.resourceType = resourceType
            self.loadType = loadType
        }
    }
    
    public struct Action: Codable, Equatable, Sendable {
        public var type: String
        public var selector: String?
        
        public init(type: String, selector: String? = nil) {
            self.type = type
            self.selector = selector
        }
    }
    
    public var trigger: Trigger
    public var action: Action
    
    public init(trigger: Trigger, action: Action) {
        self.trigger = trigger
        self.action = action
    }
}
