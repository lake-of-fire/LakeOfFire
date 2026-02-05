import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireCore
import LakeOfFireAdblock

public class HistoryRecord: Bookmark {
    @Persisted public var lastVisitedAt = Date()
    
    @Persisted public var isDemoted: Bool?
    
    @Persisted public var bookmarkID: String?
    
    public override func configureBookmark(_ bookmark: Bookmark) {
        super.configureBookmark(bookmark)
    }
    
    public override var deleteActionTitle: String {
        "Remove History…"
    }
    
    public override var deletionConfirmationTitle: String {
        return "Deletion Confirmation"
    }
    
    public override var deletionConfirmationMessage: String {
        return "Are you sure you want to delete from history?"
    }
    
    public override var deletionConfirmationActionTitle: String {
        return "Delete"
    }
}

public extension HistoryRecord {
    @RealmBackgroundActor
    func refreshDemotedStatus(skipPreviouslyDemoted: Bool = true) async throws {
        guard isDemoted != false || !skipPreviouslyDemoted else {
            return
        }
        guard let realm else {
            print("Cannot refresh demoted status: no realm")
            return
        }
        let demoted = try await { @RealmBackgroundActor in
            if isGoogleSearchURL(url) {
                return true
            }
            if isReaderModeByDefault || isReaderModeAvailable {
                return false
            }
            if rssContainsFullContent {
                return false
            }
            if isFromClipboard || isPhysicalMedia {
                return false
            }
            
            if let bookmark = Bookmark.get(forURL: url, realm: realm), !bookmark.isDeleted {
                return false
            }
            
            return true
        }()
        if demoted != isDemoted {
            try await realm.asyncWrite {
                isDemoted = demoted
                refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}

fileprivate func hostIsGoogleRegistrableDomain(_ host: String) -> Bool {
    let labels = host.lowercased().split(separator: ".").map(String.init)
    guard labels.count >= 2 else { return false }
    let last = labels[labels.count - 1]
    let secondLast = labels[labels.count - 2]
    
    // Case 1: *.google.<tld>  (e.g., google.com, www.google.de, news.google.dev)
    if secondLast == "google" { return true }
    
    // Case 2: *.google.<sld>.<cc> (e.g., google.co.uk, www.google.com.au)
    if labels.count >= 3 {
        let thirdLast = labels[labels.count - 3]
        let sld = secondLast
        let cc = last
        let allowedSLDs: Set<String> = [
            "com", // e.g., google.com.au, google.com.br, google.com.mx, google.com.tr
            "co"   // e.g., google.co.uk, google.co.jp, google.co.kr, google.co.za
        ]
        if thirdLast == "google",
           allowedSLDs.contains(sld),
           cc.count == 2, cc.allSatisfy({ $0.isLetter }) {
            return true
        }
    }
    
    return false
}

fileprivate func isGoogleSearchURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    // Host must contain a "google" label (e.g., google.com, www.google.co.jp, news.google.de)
    guard hostIsGoogleRegistrableDomain(host) else { return false }
    
    let path = url.path.lowercased()
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let queryItems = comps?.queryItems ?? []
    let q = queryItems.first(where: { $0.name == "q" })?.value
    
    // Common search entry points:
    // - /search?q=...
    // - /webhp?q=... (or with fragment #q=...)
    // - /url?q=... (redirector) or /url?url=...
    // - Root with fragment #q=... (older patterns)
    if path == "/search" || path == "/webhp" || path == "/url" || path.isEmpty || path == "/" {
        if let q, !q.isEmpty { return true }
    }
    
    // Fallback: query in fragment (#q=...)
    if let fragment = url.fragment?.lowercased(), fragment.contains("q=") {
        return true
    }
    
    return false
}

//public extension HistoryRecord {
//  /// A way to compare `Bool`s.
//  ///
//  /// Note: `false` is "less than" `true`.
//  enum Comparable: CaseIterable, Swift.Comparable {
//    case `false`, `true`
//  }
//
//  /// Make a `Bool` `Comparable`, with `false` being "less than" `true`.
//  var comparable: Comparable { .init(booleanLiteral: self) }
//}

//public struct OptionalHistoryRecordBookmarkComparator: SortComparator {
//    public var order: SortOrder = .forward
//
//    public func compare(_ lhs: HistoryRecord?, _ rhs: HistoryRecord?) -> ComparisonResult {
//        let result: ComparisonResult
//        switch (lhs?.bookmark, rhs?.bookmark) {
//        case (nil, nil): result = .orderedSame
//        case (.some, nil): result = .orderedDescending
//        case (nil, .some): result = .orderedAscending
//        case let (lhs?, rhs?):
//            result = lhs.createdAt.compare(rhs.createdAt)
//        }
//        return order == .forward ? result : result.reversed
//    }
//
//    public init(order: SortOrder = .forward) {
//        self.order = order
//    }
//}
//
//fileprivate extension ComparisonResult {
//    var reversed: ComparisonResult {
//        switch self {
//        case .orderedAscending: return .orderedDescending
//        case .orderedSame: return .orderedSame
//        case .orderedDescending: return .orderedAscending
//        }
//    }
//}
