import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps

private func libraryFeedCreationPhysicalRowID<T: ObjectKeyIdentifiable>(_ object: T) -> UInt64 {
    object.id
}

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
    public let feedRowID: UInt64
    public let categoryRowID: UInt64
    private var publication: LibraryFeedCreationPublication?

    @RealmBackgroundActor
    fileprivate init(feed: Feed, category: FeedCategory) {
        feedID = feed.id
        feedCreatedAt = feed.createdAt
        categoryID = category.id
        categoryCreatedAt = category.createdAt
        feedRowID = libraryFeedCreationPhysicalRowID(feed)
        categoryRowID = libraryFeedCreationPhysicalRowID(category)
    }

    // Preserve the public value comparison independently of consuming the
    // one-shot physical references used only for optional presentation.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.feedID == rhs.feedID && lhs.feedCreatedAt == rhs.feedCreatedAt
            && lhs.categoryID == rhs.categoryID && lhs.categoryCreatedAt == rhs.categoryCreatedAt
            && lhs.feedRowID == rhs.feedRowID && lhs.categoryRowID == rhs.categoryRowID
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
              libraryFeedCreationPhysicalRowID(category) == categoryRowID,
              !category.isDeleted, category.isUserEditable,
              feed.id == feedID, feed.createdAt == feedCreatedAt, !feed.isDeleted,
              libraryFeedCreationPhysicalRowID(feed) == feedRowID,
              feed.categoryID == categoryID else { return nil }
        return (category, feed)
    }
}

/// A rendered destination is an identity, not an optional lookup result. A
/// retired explicit category must never become a request for a new category.
public enum LibraryFeedCreationDestination: Equatable, Sendable {
    // Captured managed-row identity, including the valid physical key zero.
    case category(id: UUID, createdAt: Date, rowID: UInt64)
    case newUserCategory
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
        let destination: LibraryFeedCreationDestination
        do {
            guard let category = realm.resolve(categoryReference),
                  !category.isDeleted, category.isUserEditable,
                  expectedCategoryCreatedAt.map({ $0 == category.createdAt }) ?? true else { return nil }
            destination = .category(id: category.id, createdAt: category.createdAt,
                                    rowID: libraryFeedCreationPhysicalRowID(category))
        }

        return try await createFeedWithIdentity(
            destination: destination,
            realmConfiguration: realmConfiguration,
            storageAdmission: storageAdmission,
            beforeWrite: beforeWrite
        )
    }

    /// Initializes the complete feed inside its birth transaction. New user
    /// categories, their membership and their first feed are committed together.
    @RealmBackgroundActor
    func createFeedWithIdentity(
        destination: LibraryFeedCreationDestination,
        rssURL: URL? = nil,
        title: String? = nil,
        realmConfiguration: Realm.Configuration,
        storageAdmission: RealmStorageAdmission? = nil,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws -> LibraryFeedCreationResult? {
        try Task.checkCancellation()
        let storageAdmission = storageAdmission
            ?? RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration,
            storageAdmission: storageAdmission
        )
        let libraryIdentity: (id: UUID, createdAt: Date, rowID: UInt64)?
        switch destination {
        case .category(let id, let createdAt, let expectedRowID):
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: id),
                  libraryFeedCreationPhysicalRowID(category) == expectedRowID,
                  category.createdAt == createdAt,
                  !category.isDeleted, category.isUserEditable else { return nil }
            libraryIdentity = nil
        case .newUserCategory:
            let library = try await LibraryConfiguration.getConsolidatedOrCreate(
                realmConfiguration: realmConfiguration,
                storageAdmission: storageAdmission
            )
            libraryIdentity = (library.id, library.createdAt, libraryFeedCreationPhysicalRowID(library))
        }

        try await beforeWrite?()
        try Task.checkCancellation()
        let committed = try await realm.asyncWritePreservingOwnership {
            () throws -> (result: LibraryFeedCreationResult, feed: Feed, category: FeedCategory)? in
            try Task.checkCancellation()
            guard storageAdmission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            let category: FeedCategory
            let changedLibrary: LibraryConfiguration?
            switch destination {
            case .category(let id, let createdAt, let expectedRowID):
                guard let liveCategory = realm.object(ofType: FeedCategory.self, forPrimaryKey: id),
                      libraryFeedCreationPhysicalRowID(liveCategory) == expectedRowID,
                      liveCategory.createdAt == createdAt,
                      !liveCategory.isDeleted, liveCategory.isUserEditable else { return nil }
                category = liveCategory
                changedLibrary = nil
            case .newUserCategory:
                guard let libraryIdentity,
                      let library = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryIdentity.id),
                      library.createdAt == libraryIdentity.createdAt, !library.isDeleted,
                      libraryFeedCreationPhysicalRowID(library) == libraryIdentity.rowID else { return nil }
                category = FeedCategory()
                category.title = "My Library"
                realm.add(category)
                library.categoryIDs.append(category.id)
                changedLibrary = library
            }
            let feed = Feed()
            feed.categoryID = category.id
            feed.meaningfulContentMinLength = 0
            if let rssURL { feed.rssUrl = rssURL }
            if let title { feed.title = title }
            realm.add(feed)
            let timestamp = Date()
            if let changedLibrary {
                category.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                changedLibrary.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            }
            feed.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            return (LibraryFeedCreationResult(feed: feed, category: category), feed, category)
        }
        guard let committed else { return nil }
        return committed.result.withPublicationReferences(
            feed: committed.feed, category: committed.category, storageAdmission: storageAdmission
        )
    }
}
