import Foundation

/// Canonical WebKit Safari Content Blocker resource types.
public enum SafariResourceType: String, CaseIterable, Sendable, Codable {
    case document = "document"
    case image = "image"
    case styleSheet = "style-sheet"
    case script = "script"
    case font = "font"
    case raw = "raw"              // Matches XMLHttpRequest, fetch, ping, websocket
    case svgDocument = "svg-document"
    case media = "media"
    case popup = "popup"
    
    /// The finite set of filterable subresource types eligible for set-complement calculations.
    /// Excludes root document and popups to prevent accidental document blocking.
    public static let filterableSubresources: Set<SafariResourceType> = [
        .image,
        .styleSheet,
        .script,
        .font,
        .raw,
        .svgDocument,
        .media
    ]
}
