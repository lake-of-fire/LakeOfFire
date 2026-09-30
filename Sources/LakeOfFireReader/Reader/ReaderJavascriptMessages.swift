import Foundation
import SwiftUIWebView
import RealmSwift

internal func readabilityMessageCanRepresentTopLevelDocument(
    pageURL: URL?,
    windowURL: URL?,
    isMainFrame: Bool
) -> Bool {
    if isMainFrame {
        return true
    }
    guard let pageURL, let windowURL else {
        return false
    }
    if pageURL == windowURL {
        return true
    }
    var pageComponents = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
    var windowComponents = URLComponents(url: windowURL, resolvingAgainstBaseURL: false)
    pageComponents?.fragment = nil
    windowComponents?.fragment = nil
    return pageComponents?.url == windowComponents?.url
}

public struct ConsoleLogMessage {
    public let message: String?
    public let arguments: [Any?]?
    public let severity: String

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        self.message = body["arguments"] as? String
        self.arguments = body["arguments"] as? [Any?]
        guard let severity = body["severity"] as? String else { return nil }
        self.severity = severity
    }
}

public struct ReaderContentEbookInitialRestoreResultMessage: Sendable {
    public let initialRestoreResult: ReaderContentEbookInitialRestoreResult?

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        initialRestoreResult = ReaderContentEbookInitialRestoreResult(payload: body["initialRestoreResult"])
    }
}

public extension ReaderOnErrorMessage {
    init?(fromMessage message: WebViewMessage) {
        self.init(body: message.body)
    }
}

public extension ReaderModeUnavailableMessage {
    init?(fromMessage message: WebViewMessage) {
        self.init(body: message.body)
    }
}

public extension ReadabilityParsedMessage {
    init?(fromMessage message: WebViewMessage) {
        self.init(body: message.body)
    }
}

public extension VideoStatusMessage {
    init?(fromMessage message: WebViewMessage) {
        self.init(body: message.body)
    }
}

public extension PageMetadataUpdatedMessage {
    init?(fromMessage message: WebViewMessage) {
        self.init(body: message.body)
    }
}

public struct ImageUpdatedMessage {
    public var newImageURL: URL? = nil
    public var mainDocumentURL: URL?

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        if let raw = body["newImageURL"] as? String, let url = URL(string: raw) {
            newImageURL = url
        }
        if let rawPage = body["mainDocumentURL"] as? String, let pageURL = URL(string: rawPage) {
            mainDocumentURL = pageURL
        }
    }
}

public struct WritingDirectionMessage {
    public var writingDirection: String
    public var mainDocumentURL: URL?

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }

        guard let direction = body["writingDirection"] as? String else { return nil }
        writingDirection = direction
        if let rawPage = body["mainDocumentURL"] as? String, let pageURL = URL(string: rawPage) {
            mainDocumentURL = pageURL
        }
    }
}

//public struct YoutubeCaptionsMessage {
//    public enum Status: String {
//        case idle = "idle"
//        case loading = "loading"
//        case available = "available"
//        case unavailable = "unavailable"
//    }
//
////    public let rssURLs: [[String]]
//
//    public init?(fromMessage message: WebViewMessage) {
//        guard let body = message.body as? [String: Any] else { return nil }
////        rssURLs = body["rssURLs"] as? [[String]] ?? []
//    }
//}

public extension FractionalCompletionMessage {
    init?(fromMessage message: WebViewMessage) {
        self.init(body: message.body)
    }
}

public struct OpenReaderGoToSheetMessage {
    public let source: String?
    public let targetID: String?
    public let preserveHiddenNavigation: Bool
    public let preserveVisibleNavigation: Bool

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        source = body["source"] as? String
        targetID = body["targetID"] as? String
        preserveHiddenNavigation = body["preserveHiddenNavigation"] as? Bool ?? false
        preserveVisibleNavigation = body["preserveVisibleNavigation"] as? Bool ?? false
    }
}

public struct RSSURLsMessage {
    public let rssURLs: [[String]]
    public var windowURL: URL?

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        rssURLs = body["rssURLs"] as? [[String]] ?? []
        if let windowURLRaw = body["windowURL"] as? String {
            windowURL = URL(string: windowURLRaw)
        }
    }
}
