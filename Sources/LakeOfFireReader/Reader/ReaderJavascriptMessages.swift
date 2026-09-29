import CoreFoundation
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

public struct NestedDOMRootSelector {
    public let layer0FrameSelector: String?
    public let layer1ShadowRootSelector: String?
    public let layer2ShadowRootSelector: String?

    public init?(layer0FrameSelector: String?, layer1ShadowRootSelector: String?, layer2ShadowRootSelector: String?) {
        guard layer1ShadowRootSelector != nil || layer0FrameSelector != nil else {
            return nil
        }
        self.layer0FrameSelector = layer0FrameSelector
        self.layer1ShadowRootSelector = layer1ShadowRootSelector
        self.layer2ShadowRootSelector = layer2ShadowRootSelector
    }
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

public struct ReaderContentEbookInitialRestoreResult: Sendable, Equatable {
    public enum TerminalState: String, Sendable, Equatable {
        case satisfied
        case failed
        case noTarget
    }

    public let requestID: String?
    public let requestedLocator: String
    public let terminalState: TerminalState
    public let navigationOk: Bool
    public let restoreSatisfied: Bool
    public let handledFractionalCompletion: Double?
    public let currentFractionalCompletion: Double?
    public let handledCFI: String?
    public let error: String?

    public init?(payload: Any?) {
        guard let payload = payload as? [String: Any],
              let requestedLocator = payload["requestedLocator"] as? String,
              let terminalStateValue = payload["terminalState"] as? String,
              let terminalState = TerminalState(rawValue: terminalStateValue),
              let navigationOk = payload["navigationOk"] as? Bool,
              let restoreSatisfied = payload["restoreSatisfied"] as? Bool else {
            return nil
        }
        requestID = payload["requestID"] as? String
        self.requestedLocator = requestedLocator
        self.terminalState = terminalState
        self.navigationOk = navigationOk
        self.restoreSatisfied = restoreSatisfied
        handledFractionalCompletion = Self.finiteDouble(payload["handledFractionalCompletion"])
        currentFractionalCompletion = Self.finiteDouble(payload["currentFractionalCompletion"])
        handledCFI = payload["handledCFI"] as? String
        error = payload["error"] as? String
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}

public struct ReaderContentEbookInitialRestoreResultMessage: Sendable {
    public let initialRestoreResult: ReaderContentEbookInitialRestoreResult?

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        initialRestoreResult = ReaderContentEbookInitialRestoreResult(payload: body["initialRestoreResult"])
    }
}

public struct ReaderOnErrorMessage {
    public let message: String?
    public let source: URL
    public let lineno: Int?
    public let colno: Int?
    public let error: String?

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        guard let rawURL = body["source"] as? String, let url = URL(string: rawURL) else { return nil }
        self.message = body["message"] as? String
        source = url
        lineno = body["lineno"] as? Int
        colno = body["colno"] as? Int
        error = body["error"] as? String
    }
}

public struct ReaderModeUnavailableMessage {
    public let pageURL: URL?
    public let windowURL: URL?

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        pageURL = URL(string: body["pageURL"] as! String)
        windowURL = URL(string: body["windowURL"] as! String)
    }
}

public struct ReadabilityParsedMessage {
    public let pageURL: URL?
    public let windowURL: URL?
    public let readabilityContainerSelector: String?
    public let readabilityContainerRootSelector: NestedDOMRootSelector?
    public let title: String
    public let byline: String
    public let publishedTime: String?
    public let content: String
    public let inputHTML: String
    public let outputHTML: String

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        pageURL = URL(string: body["pageURL"] as! String)
        windowURL = URL(string: body["windowURL"] as! String)

        readabilityContainerSelector = body["readabilityContainerSelector"] as? String
        readabilityContainerRootSelector = NestedDOMRootSelector(
            layer0FrameSelector: body["layer0FrameSelector"] as? String,
            layer1ShadowRootSelector: body["layer1ShadowRootSelector"] as? String,
            layer2ShadowRootSelector: body["layer2ShadowRootSelector"] as? String)

        title = body["title"] as! String
        byline = body["byline"] as! String
        publishedTime = body["publishedTime"] as? String
        content = body["content"] as! String
        inputHTML = body["inputHTML"] as! String
        outputHTML = body["outputHTML"] as? String ?? ""
    }
}

public struct VideoStatusMessage {
    public struct CaptionsOption {
        public let label: String
        public let languageCode: String
        public let kind: String
        public let isAutoGenerated: Bool
        public let baseURL: URL

        init?(dictionary: [String: Any]) {
            guard
                let label = dictionary["label"] as? String,
                let languageCode = dictionary["languageCode"] as? String,
                let kind = dictionary["kind"] as? String,
                let isAutoGenerated = dictionary["isAutoGenerated"] as? Bool,
                let baseURLString = dictionary["baseURL"] as? String,
                let baseURL = URL(string: baseURLString)
            else {
                print("Failed to decode CaptionsOption:", dictionary)
                return nil
            }

            self.label = label
            self.languageCode = languageCode
            self.kind = kind
            self.isAutoGenerated = isAutoGenerated
            self.baseURL = baseURL
        }
    }

    public let windowURL: URL?
    public let pageURL: URL?
    public let providerVideoID: String?
    public let captionsOptions: [CaptionsOption]

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        pageURL = URL(string: body["pageURL"] as! String)
        windowURL = URL(string: body["windowURL"] as! String)
        providerVideoID = body["providerVideoID"] as? String

        if let captionsArray = body["captionsOptions"] as? [[String: Any]] {
            captionsOptions = captionsArray.compactMap { CaptionsOption(dictionary: $0) }
        } else {
            print("No valid captionsOptions found.")
            captionsOptions = []
        }
    }
}

public struct PageMetadataUpdatedMessage {
    public let title: String
    public let author: String
    public let url: URL?

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any],
              let title = body["title"] as? String,
              let author = body["author"] as? String
        else { return nil }
        self.title = title
        self.author = author
        url = URL(string: body["url"] as! String)
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
////        rssURLs = body["rssURLs"] as! [[String]]
//    }
//}

private enum WebKitScalarDecoder {
    private static let maximumExactJavaScriptInteger = 9_007_199_254_740_991.0

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    static func fraction(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              value >= 0,
              value <= maximumExactJavaScriptInteger else {
            return nil
        }
        return Int(exactly: value)
    }
}

public struct FractionalCompletionMessage: Sendable {
    public var fractionalCompletion: Float
    public var cfi: String
    public var reason: String
    public var mainDocumentURL: URL?
    public var sectionIndex: Int?
    public var currentPageNumber: Int?
    public var totalPages: Int?
    public var hasVisibleJapaneseText: Bool?
    public var visibleSegmentCount: Int?
    public var observedSegmentCount: Int?

    public var representsKnownBlankViewport: Bool {
        visibleSegmentCount == 0
            && (observedSegmentCount ?? 0) > 0
            && currentPageNumber == nil
            && totalPages == nil
    }

    public init?(fromMessage message: WebViewMessage) {
        self.init(body: message.body)
    }

    public init?(body rawBody: Any?) {
        guard let body = rawBody as? [String: Any],
              let completion = WebKitScalarDecoder.fraction(body["fractionalCompletion"]),
              let cfi = body["cfi"] as? String,
              let reason = body["reason"] as? String else { return nil }
        fractionalCompletion = Float(completion)
        self.cfi = cfi
        self.reason = reason
        if let rawHasVisibleJapaneseText = body["hasVisibleJapaneseText"] {
            guard let hasVisibleJapaneseText = WebKitScalarDecoder.boolean(rawHasVisibleJapaneseText) else {
                return nil
            }
            self.hasVisibleJapaneseText = hasVisibleJapaneseText
        }
        if let rawPage = body["mainDocumentURL"] as? String, let pageURL = URL(string: rawPage) {
            mainDocumentURL = pageURL
        }
        guard Self.optionalNonnegativeIntegerIsValid(body, key: "sectionIndex"),
              Self.optionalNonnegativeIntegerIsValid(body, key: "currentPageNumber"),
              Self.optionalNonnegativeIntegerIsValid(body, key: "totalPages"),
              Self.optionalNonnegativeIntegerIsValid(body, key: "visibleSegmentCount"),
              Self.optionalNonnegativeIntegerIsValid(body, key: "observedSegmentCount") else {
            return nil
        }
        sectionIndex = body["sectionIndex"].flatMap { WebKitScalarDecoder.nonnegativeInteger($0) }
        currentPageNumber = body["currentPageNumber"].flatMap {
            WebKitScalarDecoder.nonnegativeInteger($0)
        }
        totalPages = body["totalPages"].flatMap { WebKitScalarDecoder.nonnegativeInteger($0) }
        visibleSegmentCount = body["visibleSegmentCount"].flatMap {
            WebKitScalarDecoder.nonnegativeInteger($0)
        }
        observedSegmentCount = body["observedSegmentCount"].flatMap {
            WebKitScalarDecoder.nonnegativeInteger($0)
        }
    }

    private static func optionalNonnegativeIntegerIsValid(
        _ body: [String: Any],
        key: String
    ) -> Bool {
        guard let value = body[key] else { return true }
        return WebKitScalarDecoder.nonnegativeInteger(value) != nil
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
