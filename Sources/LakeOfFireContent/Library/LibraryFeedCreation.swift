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

/// A rendered destination is an identity, not an optional lookup result. A
/// retired explicit category must never become a request for a new category.
public enum LibraryFeedCreationDestination: Equatable, Sendable {
    case category(id: UUID, createdAt: Date)
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
            destination = .category(id: category.id, createdAt: category.createdAt)
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
        let libraryIdentity: (id: UUID, createdAt: Date)?
        switch destination {
        case .category(let id, let createdAt):
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: id),
                  category.createdAt == createdAt,
                  !category.isDeleted, category.isUserEditable else { return nil }
            libraryIdentity = nil
        case .newUserCategory:
            let library = try await LibraryConfiguration.getConsolidatedOrCreate(
                realmConfiguration: realmConfiguration,
                storageAdmission: storageAdmission
            )
            libraryIdentity = (library.id, library.createdAt)
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
            let category: FeedCategory
            let changedLibrary: LibraryConfiguration?
            switch destination {
            case .category(let id, let createdAt):
                guard let liveCategory = realm.object(ofType: FeedCategory.self, forPrimaryKey: id),
                      liveCategory.createdAt == createdAt,
                      !liveCategory.isDeleted, liveCategory.isUserEditable else { return nil }
                category = liveCategory
                changedLibrary = nil
            case .newUserCategory:
                guard let libraryIdentity,
                      let library = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryIdentity.id),
                      library.createdAt == libraryIdentity.createdAt, !library.isDeleted else { return nil }
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
            return LibraryFeedCreationResult(feed: feed, category: category)
        }
    }
}
