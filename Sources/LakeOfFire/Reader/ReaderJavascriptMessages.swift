import Foundation
import SwiftUIWebView
import RealmSwift

public struct NestedDOMSelector {
    public let layer0ShadowRootSelector: String?
    public let layer1FrameSelector: String?
    
    public init?(layer0ShadowRootSelector: String?, layer1FrameSelector: String?) {
        guard layer0ShadowRootSelector != nil || layer1FrameSelector != nil else {
            return nil
        }
        self.layer0ShadowRootSelector = layer0ShadowRootSelector
        self.layer1FrameSelector = layer1FrameSelector
    }
}

public struct ReadabilityParsedMessage {
    public let pageURL: URL?
    public let windowURL: URL?
    public let readerContainerSelector: NestedDOMSelector?
    public let title: String
    public let byline: String
    public let content: String
    public let inputHTML: String
    public let outputHTML: String
    
    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        pageURL = URL(string: body["pageURL"] as! String)
        windowURL = URL(string: body["windowURL"] as! String)
        
        readerContainerSelector = NestedDOMSelector(layer0ShadowRootSelector: body["layer0ShadowRootSelector"] as? String, layer1FrameSelector: body["layer1FrameSelector"] as? String)
        
        title = body["title"] as! String
        byline = body["byline"] as! String
        content = body["content"] as! String
        inputHTML = body["inputHTML"] as! String
        outputHTML = body["outputHTML"] as! String
    }
}

public struct TitleUpdatedMessage {
    public let newTitle: String
    public let url: URL?
    
    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        newTitle = body["newTitle"] as! String
        url = URL(string: body["url"] as! String)
    }
}

public struct YoutubeCaptionsMessage {
    public enum Status: String {
        case idle = "idle"
        case loading = "loading"
        case available = "available"
        case unavailable = "unavailable"
    }
    
//    public let rssURLs: [[String]]
    
    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
//        rssURLs = body["rssURLs"] as! [[String]]
    }
}

public struct RSSURLsMessage {
    public let rssURLs: [[String]]
    
    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        rssURLs = body["rssURLs"] as? [[String]] ?? []
    }
}
