import Foundation
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps

public class HistoryRecord: Bookmark {
    @Persisted public var lastVisitedAt = Date()
    
    @Persisted public var isDemoted: Bool?

    @Persisted public var bookmarkID: String?
    
    public override func configureBookmark(_ bookmark: Bookmark) {
        super.configureBookmark(bookmark)
    }
}

extension HistoryRecord: DeletableReaderContent {
    public var deleteActionTitle: String {
        "Remove from History…"
    }

    @MainActor
    public func delete() async throws {
        let historyURL = url
        guard let contentReference = ReaderContentLoader.ContentReference(content: self) else {
            return
        }
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: contentReference.realmConfiguration
            )
            try await realm.asyncWrite {
                HistoryRecord.markOpenedRecordsDeleted(
                    matching: historyURL,
                    in: realm
                )
            }
        }()
    }
}

extension DeletableReaderContent {
    @MainActor
    public func delete() async throws {
        guard let contentRef = ReaderContentLoader.ContentReference(content: self) else { return }
        try await { @RealmBackgroundActor in
            guard let content = try await contentRef.resolveOnBackgroundActor() else { return }
//            await content.realm?.asyncRefresh()
            try await content.realm?.asyncWrite {
                //            for videoStatus in realm.objects(VideoS)
                content.isDeleted = true
                content.refreshChangeMetadata(explicitlyModified: true)
            }
        }()
    }
    
//    @MainActor
//    public func delete() async throws {
//        guard let content = try await ReaderContentLoader.fromMainActor(content: self) as? Self, let realm = content.realm else { return }
//        await realm.asyncRefresh()
//        try await realm.asyncWrite {
//            content.isDeleted = true
//            content.refreshChangeMetadata(explicitlyModified: true)
//        }
//    }
}

public extension HistoryRecord {
    static func canonicalHistoryURL(for url: URL) -> URL {
        ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
    }

    static func historyIdentityURLStrings(for url: URL) -> [String] {
        let canonicalURL = canonicalHistoryURL(for: url)
        var identityURLStrings = [canonicalURL.absoluteString]

        if url.absoluteString != canonicalURL.absoluteString {
            identityURLStrings.append(url.absoluteString)
        }
        if let loaderURL = ReaderContentLoader.readerLoaderURL(for: canonicalURL),
           !identityURLStrings.contains(loaderURL.absoluteString) {
            identityURLStrings.append(loaderURL.absoluteString)
        }

        return identityURLStrings
    }

    static func records(matching url: URL, in realm: Realm) -> Results<HistoryRecord> {
        let predicates = historyIdentityURLStrings(for: url).map {
            NSPredicate(format: "url == %@", $0)
        }
        return realm.objects(HistoryRecord.self)
            .filter(NSCompoundPredicate(orPredicateWithSubpredicates: predicates))
    }

    static func openedRecords(matching url: URL, in realm: Realm) -> Results<HistoryRecord> {
        records(matching: url, in: realm)
            .where { !$0.isDeleted }
    }

    @discardableResult
    static func markOpenedRecordsDeleted(matching url: URL, in realm: Realm) -> Int {
        let openedRecords = Array(openedRecords(matching: url, in: realm))
        for record in openedRecords {
            record.isDeleted = true
            record.refreshChangeMetadata(explicitlyModified: true)
        }
        return openedRecords.count
    }

    @RealmBackgroundActor
    static func getOpenedRecord(forURL url: URL) async throws -> HistoryRecord? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: ReaderContentLoader.historyRealmConfiguration
        )
        return openedRecords(matching: url, in: realm)
            .sorted(by: [
                SortDescriptor(keyPath: "lastVisitedAt", ascending: false),
                SortDescriptor(keyPath: "compoundKey", ascending: true),
            ])
            .first
    }

    static func hasOpenedRecord(for url: URL, in realm: Realm) -> Bool {
        openedRecords(matching: url, in: realm).first != nil
    }

    static func latestLastVisitedAt(for url: URL, in realm: Realm) -> Date? {
        openedRecords(matching: url, in: realm)
            .map(\.lastVisitedAt)
            .max()
    }

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
            if isReaderModeByDefault || isReaderModeAvailable {
                return false
            }
            if rssContainsFullContent {
                return false
            }
            if isFromClipboard || isPhysicalMedia {
                return false
            }
            
            if let bookmark = try await Bookmark.get(forURL: url), !bookmark.isDeleted {
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
