import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps

private final class LibraryFeedCreationPublication: Sendable {
    let categoryReference: ThreadSafeReference<FeedCategory>
    let feedReference: ThreadSafeReference<Feed>
    let storageAdmission: RealmStorageAdmission

    init(categoryReference: ThreadSafeReference<FeedCategory>,
         feedReference: ThreadSafeReference<Feed>, storageAdmission: RealmStorageAdmission) {
        self.categoryReference = categoryReference
        self.feedReference = feedReference
        self.storageAdmission = storageAdmission
    }
}

/// The committed incarnation is checked again before an editor is presented.
public struct LibraryFeedCreationResult: Equatable, Sendable {
    public let feedID: UUID
    public let feedCreatedAt: Date
    public let categoryID: UUID
    public let categoryCreatedAt: Date
    private var publication: LibraryFeedCreationPublication?

    @RealmBackgroundActor
    fileprivate init(feed: Feed, category: FeedCategory) {
        feedID = feed.id
        feedCreatedAt = feed.createdAt
        categoryID = category.id
        categoryCreatedAt = category.createdAt
    }

    // Preserve the public value comparison independently of consuming the
    // one-shot physical references used only for optional presentation.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.feedID == rhs.feedID && lhs.feedCreatedAt == rhs.feedCreatedAt
            && lhs.categoryID == rhs.categoryID && lhs.categoryCreatedAt == rhs.categoryCreatedAt
    }

    @RealmBackgroundActor
    fileprivate func withPublicationReferences(
        feed: Feed, category: FeedCategory, storageAdmission: RealmStorageAdmission
    ) -> Self {
        var result = self
        // Commit settlement can suspend. Keep the durable identity even when
        // an original row was removed before optional references are captured.
        guard !category.isInvalidated, !feed.isInvalidated else { return result }
        result.publication = LibraryFeedCreationPublication(
            categoryReference: ThreadSafeReference(to: category),
            feedReference: ThreadSafeReference(to: feed), storageAdmission: storageAdmission
        )
        return result
    }

    /// Resolve once in a refreshed MainActor Realm, outside a write. Copies of
    /// this result share the references; subsequent attempts return nil. A
    /// missing physical row never falls back to its UUID or creation date.
    @MainActor
    public func resolveCommittedRows(in realm: Realm) -> (category: FeedCategory, feed: Feed)? {
        guard let publication, !realm.isInWriteTransaction,
              publication.storageAdmission.matchesCurrentStorageIdentity({
                  RealmBackgroundActor.shared.realmCacheKey(for: realm.configuration)
              }),
              !publication.categoryReference.isInvalidated,
              !publication.feedReference.isInvalidated,
              let category = realm.resolve(publication.categoryReference),
              let feed = realm.resolve(publication.feedReference),
              !category.isInvalidated, !feed.isInvalidated,
              category.id == categoryID, category.createdAt == categoryCreatedAt,
              !category.isDeleted, category.isUserEditable,
              feed.id == feedID, feed.createdAt == feedCreatedAt, !feed.isDeleted,
              feed.categoryID == categoryID else { return nil }
        return (category, feed)
    }
}

public extension LibraryDataManager {
    @RealmBackgroundActor
    func createEmptyFeedWithIdentity(
        inCategory categoryReference: ThreadSafeReference<FeedCategory>,
        realmConfiguration: Realm.Configuration = ReaderContentLoader.feedEntryRealmConfiguration,
        storageAdmission: RealmStorageAdmission? = nil,
        expectedCategoryCreatedAt: Date? = nil,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws -> LibraryFeedCreationResult? {
        try Task.checkCancellation()
        let storageAdmission = storageAdmission
            ?? RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration,
            storageAdmission: storageAdmission
        )
        guard let originalCategory = realm.resolve(categoryReference),
              !originalCategory.isInvalidated, !originalCategory.isDeleted, originalCategory.isUserEditable,
              expectedCategoryCreatedAt.map({ $0 == originalCategory.createdAt }) ?? true else { return nil }
        let categoryID = originalCategory.id
        let categoryCreatedAt = originalCategory.createdAt

        try await beforeWrite?()
        try Task.checkCancellation()
        let committed = try await realm.asyncWritePreservingOwnership {
            () throws -> (result: LibraryFeedCreationResult, feed: Feed)? in
            try Task.checkCancellation()
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            guard !originalCategory.isInvalidated,
                  let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                  originalCategory.isSameObject(as: category),
                  category.createdAt == categoryCreatedAt,
                  !category.isDeleted, category.isUserEditable else { return nil }
            let feed = Feed()
            feed.categoryID = categoryID
            feed.meaningfulContentMinLength = 0
            realm.add(feed)
            feed.refreshChangeMetadata(explicitlyModified: true)
            return (LibraryFeedCreationResult(feed: feed, category: category), feed)
        }
        guard let committed else { return nil }
        return committed.result.withPublicationReferences(
            feed: committed.feed, category: originalCategory, storageAdmission: storageAdmission
        )
    }
}
