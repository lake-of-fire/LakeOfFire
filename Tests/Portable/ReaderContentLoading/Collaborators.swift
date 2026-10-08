import Foundation
import LakeOfFireCore

// Portable transport/model leaves. ReaderContent.swift is compiled whole and
// unchanged. No Realm, provider, history persistence or WebKit is implemented.
@MainActor public protocol ReaderContentProtocol: AnyObject, Sendable {
    var url: URL { get set }
    var title: String { get set }
    var locationBarTitle: String? { get }
    var isTitlePrefixOfContent: Bool { get }
    var createdAt: Date { get }
    var needsClipboardIndicator: Bool { get }
}
@MainActor public final class HistoryRecord: ReaderContentProtocol {
    public var url = URL(string: "about:blank")!
    public var title = ""
    public var locationBarTitle: String? { title }
    public var isTitlePrefixOfContent = false
    public var createdAt = Date()
    public var needsClipboardIndicator = false
    public init() {}
    public func updateCompoundKey() {}
}
@MainActor public enum ContentLoadProbe {
    public static var resolve: ((URL) async throws -> (any ReaderContentProtocol)?)?
}
@MainActor public enum ReaderContentLoader {
    public static func getContent(forURL url: URL, countsAsHistoryVisit: Bool, source: String) async throws -> (any ReaderContentProtocol)? {
        precondition(countsAsHistoryVisit && source == "ReaderContent.load")
        guard let resolver = ContentLoadProbe.resolve else { fatalError("No fixture resolver") }
        return try await resolver(url)
    }
    public static var unsavedHome: any ReaderContentProtocol { HistoryRecord() }
    public static func getContentURL(fromLoaderURL url: URL) -> URL? { nil }
    public static func resolvedSnippetLocationBarTitle(title: String, createdAt: Date,
        needsClipboardIndicator: Bool, isTitlePrefixOfContent: Bool) -> String { fatalError("Snippet display is not exercised") }
    public static func updateSnippetTitle(contentURL: URL, title: String) async throws -> Bool { fatalError("No storage writer in this fixture") }
    public struct ContentReference {
        public init?(content: any ReaderContentProtocol) { fatalError("No Realm reference in this fixture") }
        public func resolveOnMainActor() async throws -> (any ReaderContentProtocol)? { fatalError("No Realm resolver in this fixture") }
    }
}
// Tested fixtures are ordinary absolute HTTP(S) URLs, not reader/snippet/EPUB
// aliases. This leaf makes no assertion about the production alias contract.
public extension URL {
    func matchesReaderURL(_ other: URL?) -> Bool { self == other }
    var isSnippetURL: Bool { scheme == "snippet" }
}
public extension String {
    func truncate(_ count: Int, trailing: String) -> String { String(prefix(count)) + (self.count > count ? trailing : "") }
}
