import CoreFoundation
import Foundation

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
              let navigationOk = ReaderPositionPayloadValue.boolean(payload["navigationOk"]),
              let restoreSatisfied = ReaderPositionPayloadValue.boolean(payload["restoreSatisfied"]) else {
            return nil
        }
        // A failed/no-target result cannot carry a success acknowledgement.
        // The saved request itself remains owned/correlated by the consumer.
        guard restoreSatisfied == (terminalState == .satisfied),
              !restoreSatisfied || (navigationOk && (payload["error"] == nil || payload["error"] is NSNull)) else {
            return nil
        }
        requestID = payload["requestID"] as? String
        self.requestedLocator = requestedLocator
        self.terminalState = terminalState
        self.navigationOk = navigationOk
        self.restoreSatisfied = restoreSatisfied
        handledFractionalCompletion = ReaderPositionPayloadValue.fraction(payload["handledFractionalCompletion"])
        currentFractionalCompletion = ReaderPositionPayloadValue.fraction(payload["currentFractionalCompletion"])
        handledCFI = payload["handledCFI"] as? String
        error = payload["error"] as? String
    }

}

/// Hotfix payload bounds adapted to main's existing message shape. Validation
/// here does not authorize a write or replace document/article lifetime fences.
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

    public init?(body rawBody: Any?) {
        guard let body = rawBody as? [String: Any],
              let completion = ReaderPositionPayloadValue.fraction(body["fractionalCompletion"]),
              let cfi = body["cfi"] as? String,
              cfi.utf8.count <= Self.maximumCFIUTF8Bytes,
              let reason = body["reason"] as? String,
              reason.utf8.count <= Self.maximumReasonUTF8Bytes else { return nil }
        fractionalCompletion = Float(completion)
        self.cfi = cfi
        self.reason = reason
        hasVisibleJapaneseText = ReaderPositionPayloadValue.boolean(body["hasVisibleJapaneseText"])
        if let rawPageValue = body["mainDocumentURL"] {
            guard let rawPage = rawPageValue as? String,
                  rawPage.utf8.count <= Self.maximumURLUTF8Bytes,
                  let pageURL = URL(string: rawPage) else { return nil }
            mainDocumentURL = pageURL
        }
        if let rawDocumentStartedAt = body["documentStartedAtMs"] {
            guard let timestamp = ReaderPositionPayloadValue.number(rawDocumentStartedAt) else { return nil }
            documentStartedAtMilliseconds = timestamp
        }
        sectionIndex = ReaderPositionPayloadValue.integer(body["sectionIndex"])
        currentPageNumber = ReaderPositionPayloadValue.integer(body["currentPageNumber"])
        totalPages = ReaderPositionPayloadValue.integer(body["totalPages"])
        visibleSegmentCount = ReaderPositionPayloadValue.integer(body["visibleSegmentCount"])
        observedSegmentCount = ReaderPositionPayloadValue.integer(body["observedSegmentCount"])
    }
}

// JSON/WebKit numbers and booleans both arrive as NSNumber. Swift's `is Bool`
// bridging also accepts numeric 0 and 1, so compare the CF runtime type instead.
private enum ReaderPositionPayloadValue {
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    static func fraction(_ value: Any?) -> Double? {
        guard let result = number(value), (0...1).contains(result) else { return nil }
        return result
    }

    static func integer(_ value: Any?) -> Int? {
        guard boolean(value) == nil else { return nil }
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        guard let value = number(value) else { return nil }
        // Preserve main/hotfix's truncation semantics, without trapping for
        // non-finite or out-of-range floating-point values.
        return Int(exactly: value.rounded(.towardZero))
    }
}
