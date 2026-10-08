import CoreFoundation
import Foundation
import CoreGraphics
import WebKit
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
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
        case skipped
    }

    public let requestID: String?
    public let terminalState: TerminalState
    public let requestedLocator: String?
    public let resolvedLocator: String?
    public let requestedFraction: Double?
    public let currentFraction: Double?
    public let fractionDelta: Double?
    public let handledCFI: String?
    public let handledFractionalCompletion: Double?
    public let currentSectionIndex: Int?
    public let navigationOk: Bool?
    public let restoreSatisfied: Bool
    public let error: String?

    public init?(payload: Any?) {
        guard let payload = payload as? [String: Any] else { return nil }
        guard let terminalStateRaw = payload["terminalState"] as? String,
              let terminalState = TerminalState(rawValue: terminalStateRaw) else {
            return nil
        }

        self.requestID = payload["requestID"] as? String
        self.terminalState = terminalState
        self.requestedLocator = payload["requestedLocator"] as? String
        self.resolvedLocator = payload["resolvedLocator"] as? String
        self.requestedFraction = Self.doubleValue(payload["requestedFraction"])
        self.currentFraction = Self.doubleValue(payload["currentFraction"])
        self.fractionDelta = Self.doubleValue(payload["fractionDelta"])
        self.handledCFI = payload["handledCFI"] as? String
        self.handledFractionalCompletion = Self.doubleValue(payload["handledFractionalCompletion"])
        self.currentSectionIndex = Self.intValue(payload["currentSectionIndex"])
        self.navigationOk = payload["navigationOk"] as? Bool
        self.restoreSatisfied = (payload["restoreSatisfied"] as? Bool) ?? (terminalState == .satisfied)
        self.error = payload["error"] as? String
    }

    public var logDescription: String {
        [
            "requestID=\(requestID ?? "nil")",
            "terminalState=\(terminalState.rawValue)",
            "requestedLocator=\(requestedLocator ?? "nil")",
            "resolvedLocator=\(resolvedLocator ?? "nil")",
            "requestedFraction=\(requestedFraction.map { String($0) } ?? "nil")",
            "currentFraction=\(currentFraction.map { String($0) } ?? "nil")",
            "fractionDelta=\(fractionDelta.map { String($0) } ?? "nil")",
            "currentSectionIndex=\(currentSectionIndex.map { String($0) } ?? "nil")",
            "navigationOk=\(navigationOk.map { String($0) } ?? "nil")",
            "restoreSatisfied=\(restoreSatisfied)",
            "error=\(error ?? "nil")"
        ].joined(separator: " ")
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

public struct ReaderContentEbookInitialRestoreResultMessage: Sendable {
    public let initialRestoreResult: ReaderContentEbookInitialRestoreResult?

    public init?(fromMessage message: WebViewMessage) {
        guard let body = message.body as? [String: Any] else { return nil }
        self.initialRestoreResult = ReaderContentEbookInitialRestoreResult(
            payload: body["initialRestoreResult"]
        )
    }
}

public struct NativeLookupHitTargetsMessage {
    public struct RectPayload: Equatable {
        public let left: CGFloat
        public let top: CGFloat
        public let width: CGFloat
        public let height: CGFloat

        public var rect: CGRect {
            CGRect(x: left, y: top, width: width, height: height)
        }

        init?(payload: [String: Any], scale: CGFloat) {
            guard let left = Self.number(payload["left"]),
                  let top = Self.number(payload["top"]),
                  let width = Self.number(payload["width"]),
                  let height = Self.number(payload["height"]),
                  left.isFinite,
                  top.isFinite,
                  width.isFinite,
                  height.isFinite,
                  width > 0,
                  height > 0 else {
                return nil
            }
            self.left = left * scale
            self.top = top * scale
            self.width = width * scale
            self.height = height * scale
        }

        static func number(_ value: Any?) -> CGFloat? {
            switch value {
            case let value as CGFloat:
                return value
            case let value as Double:
                return CGFloat(value)
            case let value as Float:
                return CGFloat(value)
            case let value as Int:
                return CGFloat(value)
            case let value as NSNumber:
                return CGFloat(value.doubleValue)
            case let value as String:
                guard let doubleValue = Double(value) else { return nil }
                return CGFloat(doubleValue)
            default:
                return nil
            }
        }
    }

    public struct Target {
        public let elementID: String
        public let rectPayloads: [RectPayload]
        public let rawRectPayloads: [[String: Any]]
        public let lookupPayload: [String: Any]?

        public var rects: [CGRect] {
            rectPayloads.map(\.rect)
        }

        public var surface: Any {
            (lookupPayload?["surface"] ?? lookupPayload?["selectedSurface"]) as Any
        }
    }

    public let targets: [Target]
    public let rawTargetCount: Int
    public let scale: CGFloat
    public let nativeLookupFrameKey: String?
    public let nativeLookupDocumentURL: String?
    public let viewportWidth: Any?
    public let viewportHeight: Any?
    public let viewportLeft: Any?
    public let viewportTop: Any?
    public let visualViewportScale: Any?

    public init?(fromMessage message: WebViewMessage) {
        self.init(body: message.body)
    }

    public init?(body: Any) {
        guard let payload = body as? [String: Any],
              let rawTargets = payload["targets"] as? [[String: Any]] else {
            return nil
        }
        let scale = Self.coordinateScale(from: payload)
        self.rawTargetCount = rawTargets.count
        self.scale = scale
        self.nativeLookupFrameKey = (payload["nativeLookupFrameKey"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        self.nativeLookupDocumentURL = (payload["nativeLookupDocumentURL"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        self.viewportWidth = payload["viewportWidth"]
        self.viewportHeight = payload["viewportHeight"]
        self.viewportLeft = payload["viewportLeft"]
        self.viewportTop = payload["viewportTop"]
        self.visualViewportScale = payload["visualViewportScale"]
        self.targets = rawTargets.compactMap { target -> Target? in
            guard let elementID = target["elementId"] as? String, !elementID.isEmpty else { return nil }
            let rawRects = target["rects"] as? [[String: Any]] ?? []
            let rectPayloads = rawRects.compactMap { RectPayload(payload: $0, scale: scale) }
            guard !rectPayloads.isEmpty else { return nil }
            return Target(
                elementID: elementID,
                rectPayloads: rectPayloads,
                rawRectPayloads: rawRects,
                lookupPayload: target["lookupPayload"] as? [String: Any]
            )
        }
    }

    public func webViewTargets(
        frameInfo: WKFrameInfo,
        coordinateOriginInWindow: CGPoint?
    ) -> [WebViewNativeLookupHitTarget] {
        targets.map { target in
            WebViewNativeLookupHitTarget(
                elementID: target.elementID,
                rects: target.rects,
                coordinateOriginInWindow: coordinateOriginInWindow,
                lookupPayload: target.lookupPayload,
                frameInfo: frameInfo,
                documentURL: nativeLookupDocumentURL.flatMap(URL.init(string:)),
                nativeLookupFrameKey: nativeLookupFrameKey
            )
        }
    }

    public var viewportOrigin: CGPoint {
        CGPoint(
            x: (Self.number(viewportLeft) ?? 0) * scale,
            y: (Self.number(viewportTop) ?? 0) * scale
        )
    }

    private static func coordinateScale(from payload: [String: Any]) -> CGFloat {
        guard let scale = number(payload["visualViewportScale"]),
              scale.isFinite,
              scale > 0 else {
            return 1
        }
        return scale
    }

    private static func number(_ value: Any?) -> CGFloat? {
        RectPayload.number(value)
    }
}

public struct ReaderOnErrorMessage {
    public let message: String?
    public let source: URL
    public let lineno: Int?
    public let colno: Int?
    public let error: String?
    public let documentStartedAtMilliseconds: Double?

    public init?(fromMessage message: WebViewMessage) {
        self.init(body: message.body)
    }

    public init?(body rawBody: Any?) {
        guard let body = rawBody as? [String: Any] else { return nil }
        guard let rawURL = body["source"] as? String, let url = URL(string: rawURL) else { return nil }
        self.message = body["message"] as? String
        source = url
        lineno = body["lineno"] as? Int
        colno = body["colno"] as? Int
        error = body["error"] as? String
        let rawDocumentStartedAtMilliseconds =
            (body["documentStartedAtMs"] as? NSNumber)?.doubleValue
            ?? body["documentStartedAtMs"] as? Double
        if let rawDocumentStartedAtMilliseconds,
           rawDocumentStartedAtMilliseconds.isFinite {
            documentStartedAtMilliseconds = rawDocumentStartedAtMilliseconds
        } else {
            documentStartedAtMilliseconds = nil
        }
    }
}

public struct ReaderModeUnavailableMessage {
    public let pageURL: URL?
    public let windowURL: URL?
    
    public init?(fromMessage message: WebViewMessage) {
        self.init(body: message.body)
    }

    init?(body rawBody: Any?) {
        guard let body = rawBody as? [String: Any],
              let pageURLString = body["pageURL"] as? String,
              let windowURLString = body["windowURL"] as? String else { return nil }
        pageURL = URL(string: pageURLString)
        windowURL = URL(string: windowURLString)
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
        self.init(body: message.body)
    }

    init?(body rawBody: Any?) {
        guard let body = rawBody as? [String: Any],
              let pageURLString = body["pageURL"] as? String,
              let windowURLString = body["windowURL"] as? String,
              let title = body["title"] as? String,
              let byline = body["byline"] as? String,
              let content = body["content"] as? String,
              let inputHTML = body["inputHTML"] as? String else { return nil }
        pageURL = URL(string: pageURLString)
        windowURL = URL(string: windowURLString)
        
        readabilityContainerSelector = body["readabilityContainerSelector"] as? String
        readabilityContainerRootSelector = NestedDOMRootSelector(
            layer0FrameSelector: body["layer0FrameSelector"] as? String,
            layer1ShadowRootSelector: body["layer1ShadowRootSelector"] as? String,
            layer2ShadowRootSelector: body["layer2ShadowRootSelector"] as? String)
        
        self.title = title
        self.byline = byline
        publishedTime = body["publishedTime"] as? String
        self.content = content
        self.inputHTML = inputHTML
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
        self.init(body: message.body)
    }

    init?(body rawBody: Any?) {
        guard let body = rawBody as? [String: Any],
              let pageURLString = body["pageURL"] as? String,
              let windowURLString = body["windowURL"] as? String else { return nil }
        pageURL = URL(string: pageURLString)
        windowURL = URL(string: windowURLString)
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
        self.init(body: message.body)
    }

    init?(body rawBody: Any?) {
        guard let body = rawBody as? [String: Any],
              let title = body["title"] as? String,
              let author = body["author"] as? String,
              let urlString = body["url"] as? String
        else { return nil }
        self.title = title
        self.author = author
        url = URL(string: urlString)
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

public struct FractionalCompletionMessage: Sendable {
    public static let maximumCFIUTF8Bytes = 64 * 1_024
    public static let maximumReasonUTF8Bytes = 512
    public static let maximumURLUTF8Bytes = 16_384

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
    public var documentStartedAtMilliseconds: Double?

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
              let completion = body["fractionalCompletion"] as? Double,
              completion.isFinite,
              (0...1).contains(completion),
              let cfi = body["cfi"] as? String,
              cfi.utf8.count <= Self.maximumCFIUTF8Bytes,
              let reason = body["reason"] as? String,
              reason.utf8.count <= Self.maximumReasonUTF8Bytes else { return nil }
        fractionalCompletion = Float(completion)
        self.cfi = cfi
        self.reason = reason
        hasVisibleJapaneseText = body["hasVisibleJapaneseText"] as? Bool
        if let rawPageValue = body["mainDocumentURL"] {
            guard let rawPage = rawPageValue as? String,
                  rawPage.utf8.count <= Self.maximumURLUTF8Bytes,
                  let pageURL = URL(string: rawPage) else {
                return nil
            }
            mainDocumentURL = pageURL
        }
        if let rawDocumentStartedAt = body["documentStartedAtMs"] {
            guard !Self.isBoolean(rawDocumentStartedAt),
                  let documentStartedAt = rawDocumentStartedAt as? Double,
                  documentStartedAt.isFinite else {
                return nil
            }
            documentStartedAtMilliseconds = documentStartedAt
        }
        sectionIndex = Self.safeInteger(body["sectionIndex"])
        currentPageNumber = Self.safeInteger(body["currentPageNumber"])
        totalPages = Self.safeInteger(body["totalPages"])
        visibleSegmentCount = Self.safeInteger(body["visibleSegmentCount"])
        observedSegmentCount = Self.safeInteger(body["observedSegmentCount"])
    }

    private static func safeInteger(_ value: Any?) -> Int? {
        guard !isBoolean(value) else { return nil }
        if let value = value as? Int {
            return value
        }
        if let value = value as? String {
            return Int(value)
        }
        let doubleValue: Double?
        if let value = value as? Double {
            doubleValue = value
        } else if let value = value as? NSNumber {
            doubleValue = value.doubleValue
        } else {
            doubleValue = nil
        }
        guard let doubleValue, doubleValue.isFinite else { return nil }
        return Int(exactly: doubleValue.rounded(.towardZero))
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
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
