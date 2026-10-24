import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps

/// The committed incarnation is checked again before an editor is presented.
public struct LibraryFeedCreationResult: Equatable, Sendable {
    public let feedID: UUID
    public let feedCreatedAt: Date
    public let categoryID: UUID
    public let categoryCreatedAt: Date

    @RealmBackgroundActor
    fileprivate init(feed: Feed, category: FeedCategory) {
        feedID = feed.id
        feedCreatedAt = feed.createdAt
        categoryID = category.id
        categoryCreatedAt = category.createdAt
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
        let categoryID: UUID
        let categoryCreatedAt: Date
        do {
            guard let category = realm.resolve(categoryReference),
                  !category.isDeleted, category.isUserEditable,
                  expectedCategoryCreatedAt.map({ $0 == category.createdAt }) ?? true else { return nil }
            categoryID = category.id
            categoryCreatedAt = category.createdAt
        }

        try await beforeWrite?()
        try Task.checkCancellation()
        return try await realm.asyncWritePreservingOwnership { () throws -> LibraryFeedCreationResult? in
            try Task.checkCancellation()
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                  category.createdAt == categoryCreatedAt,
                  !category.isDeleted, category.isUserEditable else { return nil }
            let feed = Feed()
            feed.categoryID = categoryID
            feed.meaningfulContentMinLength = 0
            realm.add(feed)
            feed.refreshChangeMetadata(explicitlyModified: true)
            return LibraryFeedCreationResult(feed: feed, category: category)
        }
    }
}
