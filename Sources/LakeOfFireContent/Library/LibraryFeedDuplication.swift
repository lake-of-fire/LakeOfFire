import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps

/// Committed row identities, rather than one-shot references, cross to the UI.
public struct LibraryFeedDuplicationResult: Equatable, Sendable {
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
    func duplicateFeedWithIdentity(
        _ feedReference: ThreadSafeReference<Feed>,
        inCategory categoryReference: ThreadSafeReference<FeedCategory>,
        overwriteExisting: Bool,
        realmConfiguration: Realm.Configuration = ReaderContentLoader.feedEntryRealmConfiguration,
        storageAdmission: RealmStorageAdmission? = nil,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws -> LibraryFeedDuplicationResult? {
        try Task.checkCancellation()
        let storageAdmission = storageAdmission
            ?? RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration,
            storageAdmission: storageAdmission
        )
        let categoryID: UUID
        let categoryCreatedAt: Date
        let feedID: UUID
        let feedCreatedAt: Date
        let sourceRSSURL: URL
        let existingID: UUID?
        let existingCreatedAt: Date?
        // Each reference is consumed once on the destination Realm's actor.
        // Only value identities survive the suspension before write admission.
        do {
            guard let category = realm.resolve(categoryReference),
                  !category.isDeleted, category.isUserEditable,
                  let feed = realm.resolve(feedReference), !feed.isDeleted else { return nil }
            categoryID = category.id
            categoryCreatedAt = category.createdAt
            feedID = feed.id
            feedCreatedAt = feed.createdAt
            sourceRSSURL = feed.rssUrl
            let existing = overwriteExisting
                ? category.getFeeds()?.first(where: { $0.rssUrl == sourceRSSURL && $0.id != feedID })
                : nil
            existingID = existing?.id
            existingCreatedAt = existing?.createdAt
        }

        try await beforeWrite?()
        try Task.checkCancellation()
        return try await realm.asyncWritePreservingOwnership { () throws -> LibraryFeedDuplicationResult? in
            try Task.checkCancellation()
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                  category.createdAt == categoryCreatedAt,
                  !category.isDeleted, category.isUserEditable,
                  let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID),
                  feed.createdAt == feedCreatedAt, !feed.isDeleted,
                  feed.rssUrl == sourceRSSURL else { return nil }

            let existing: Feed?
            if let existingID {
                guard let existingCreatedAt,
                      let current = realm.object(ofType: Feed.self, forPrimaryKey: existingID),
                      current.createdAt == existingCreatedAt,
                      !current.isDeleted, current.categoryID == categoryID,
                      current.directoryID == nil, current.rssUrl == sourceRSSURL else { return nil }
                existing = current
            } else {
                existing = nil
            }
            // Keep the existing Feed copy contract; only its admission and
            // destination identity change here.
            let value = try JSONDecoder().decode(Feed.self, from: JSONEncoder().encode(feed))
            value.id = existing?.id ?? UUID()
            value.isDeleted = false
            value.isArchived = false
            value.categoryID = categoryID
            if let existing {
                value.createdAt = existing.createdAt
                value.modifiedAt = existing.modifiedAt
                value.explicitlyModifiedAt = existing.explicitlyModifiedAt
                guard !duplicatedFeedFieldsMatch(value, existing) else {
                    return LibraryFeedDuplicationResult(feed: existing, category: category)
                }
            }
            let now = Date()
            let duplicatedFeed = realm.create(Feed.self, value: value, update: .modified)
            duplicatedFeed.refreshChangeMetadata(explicitlyModified: true, at: now)
            return LibraryFeedDuplicationResult(feed: duplicatedFeed, category: category)
        }
    }
}

/// Compare the values the existing Codable-copy path would write, without
/// refreshing metadata or advancing a journal generation for an unchanged copy.
@RealmBackgroundActor
private func duplicatedFeedFieldsMatch(_ lhs: Feed, _ rhs: Feed) -> Bool {
    lhs.id == rhs.id
        && lhs.title == rhs.title
        && lhs.categoryID == rhs.categoryID
        && lhs.directoryID == rhs.directoryID
        && lhs.ordinal == rhs.ordinal
        && lhs.markdownDescription == rhs.markdownDescription
        && lhs.rssUrl == rhs.rssUrl
        && lhs.iconUrl == rhs.iconUrl
        && lhs.isReaderModeByDefault == rhs.isReaderModeByDefault
        && lhs.rssContainsFullContent == rhs.rssContainsFullContent
        && lhs.injectEntryImageIntoHeader == rhs.injectEntryImageIntoHeader
        && lhs.displayPublicationDate == rhs.displayPublicationDate
        && lhs.meaningfulContentMinLength == rhs.meaningfulContentMinLength
        && lhs.extractImageFromContent == rhs.extractImageFromContent
        && lhs.deleteOrphans == rhs.deleteOrphans
        && lhs.entryContentKindRawValue == rhs.entryContentKindRawValue
        && lhs.isArchived == rhs.isArchived
        && lhs.lastViewedAt == rhs.lastViewedAt
        && lhs.lastSeenFeedEntriesAt == rhs.lastSeenFeedEntriesAt
        && lhs.lastRefreshedEntriesAt == rhs.lastRefreshedEntriesAt
        && lhs.lastFetchedETag == rhs.lastFetchedETag
        && lhs.lastFetchedModifiedAt == rhs.lastFetchedModifiedAt
        && lhs.showsUnseenBadge == rhs.showsUnseenBadge
        && lhs.isFollowed == rhs.isFollowed
        && lhs.followingOrdinal == rhs.followingOrdinal
        && lhs.isDeleted == rhs.isDeleted
}
