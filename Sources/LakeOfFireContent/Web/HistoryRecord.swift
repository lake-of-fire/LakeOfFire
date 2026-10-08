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
                for: contentReference.realmConfiguration, storageAdmission: contentReference.storageAdmission
            )
            try await realm.asyncWritePreservingOwnership {
                try Task.checkCancellation()
                try contentReference.validateStorage()
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
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: contentRef.realmConfiguration, storageAdmission: contentRef.storageAdmission)
            try await realm.asyncWritePreservingOwnership {
                try Task.checkCancellation()
                try contentRef.validateStorage()
                guard let content = realm.object(ofType: contentRef.contentType,
                    forPrimaryKey: contentRef.contentKey) as? any ReaderContentProtocol else { return }
                guard !content.isDeleted else { return }
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
    static func markOpenedRecordsDeleted(
        matching url: URL,
        in realm: Realm,
        at timestamp: Date = Date()
    ) -> Int {
        let openedRecords = Array(openedRecords(matching: url, in: realm))
        for record in openedRecords {
            record.isDeleted = true
            record.refreshChangeMetadata(
                explicitlyModified: true,
                at: timestamp
            )
        }
        return openedRecords.count
    }

    @RealmBackgroundActor
    static func getOpenedRecord(forURL url: URL) async throws -> HistoryRecord? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: ReaderContentLoader.historyRealmConfiguration
        )
        return getOpenedRecord(forURL: url, in: realm)
    }

    @RealmBackgroundActor
    static func getOpenedRecord(forURL url: URL, in realm: Realm) -> HistoryRecord? {
        openedRecords(matching: url, in: realm)
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
    func refreshDemotedStatus(
        bookmarkRealmConfiguration: Realm.Configuration = ReaderContentLoader.bookmarkRealmConfiguration,
        bookmarkStorageAdmission: RealmStorageAdmission? = nil,
        skipPreviouslyDemoted: Bool = true
    ) async throws {
        guard !isInvalidated,
              let reference = ReaderContentLoader.ContentReference(content: self) else { return }
        let actor = RealmBackgroundActor.shared
        let bookmarkAdmission = bookmarkStorageAdmission ?? (actor.realmCacheKey(for: bookmarkRealmConfiguration) == actor.realmCacheKey(for: reference.realmConfiguration)
            ? reference.storageAdmission : actor.captureStorageAdmission(for: bookmarkRealmConfiguration))
        nonisolated func validateAdmission() throws {
            try Task.checkCancellation()
            try reference.validateStorage()
            // An explicit bookmark configuration belongs to this operation;
            // do not replace it with the loader's later global configuration.
            guard bookmarkAdmission.matchesCurrentStorageIdentity({ actor.realmCacheKey(for: bookmarkRealmConfiguration) }) else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
        }
        try validateAdmission()
        let realm = try await actor.cachedRealm(for: reference.realmConfiguration, storageAdmission: reference.storageAdmission)
        if !realm.isFrozen && !realm.isInWriteTransaction { await realm.asyncRefresh() }
        try validateAdmission()
        let needsRefresh: Bool = {
            // A different owner's provisional deletion or visibility value must
            // not suppress this request. Keep the cheap committed no-op path,
            // but carry no frozen object across write admission.
            let committed = realm.freeze()
            guard let record = committed.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey) else {
                // The supplied managed row may belong to an uncommitted
                // creation. Absence is not a no-op receipt: let write admission
                // settle its owner, then resolve the row without recreating it.
                return true
            }
            return !record.isDeleted && (record.isDemoted != false || !skipPreviouslyDemoted)
        }()
        try validateAdmission()
        guard needsRefresh else { return }
        let bookmarkRealm = try await actor.cachedRealm(for: bookmarkRealmConfiguration, storageAdmission: bookmarkAdmission)
        await ReaderContentLoader.contentWriteGateForTesting?(.demotion)
        try await realm.asyncWritePreservingOwnership {
            try validateAdmission()
            let admittedBookmarks: Realm
            if bookmarkRealm == realm {
                // The owning write already contains both models. Its current
                // bookmark state commits or rolls back with this history row.
                admittedBookmarks = realm
            } else {
                if !bookmarkRealm.isFrozen && !bookmarkRealm.isInWriteTransaction { bookmarkRealm.refresh() }
                admittedBookmarks = bookmarkRealm.freeze()
            }
            // Refresh may notify a writer, retire a store, or cancel this task.
            // Resolve the history row only after that synchronous callout.
            try validateAdmission()
            guard let record = realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey),
                  !record.isDeleted, record.isDemoted != false || !skipPreviouslyDemoted else { return }
            let bookmarked = admittedBookmarks.objects(Bookmark.self)
                .filter(NSPredicate(format: "isDeleted == false AND url == %@", record.url.absoluteString)).first != nil
            let demoted = !(record.isReaderModeByDefault || record.isReaderModeAvailable
                || record.rssContainsFullContent || record.isFromClipboard || record.isPhysicalMedia || bookmarked)
            guard demoted != record.isDemoted else { return }
            record.isDemoted = demoted
            record.refreshChangeMetadata(explicitlyModified: true)
            // Metadata providers may withdraw storage admission too. A failed
            // final fence rolls back only this operation's fields and journal.
            try validateAdmission()
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
