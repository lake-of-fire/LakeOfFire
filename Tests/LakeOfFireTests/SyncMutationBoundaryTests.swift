import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class SyncMutationBoundaryTests: XCTestCase {
    func testFollowingFeedGroupJournalsOnlyChangedFeeds() throws {
        let configuration = makeConfiguration(objectTypes: [Feed.self])
        let realm = try Realm(configuration: configuration)
        let first = makeFeed(url: "https://example.com/feed.xml")
        let duplicate = makeFeed(url: "https://EXAMPLE.com:443/feed.xml#fragment")
        try realm.write {
            realm.add(first)
            realm.add(duplicate)
        }

        let changedAt = Date(timeIntervalSinceReferenceDate: 50_000)
        try realm.write {
            Feed.setFollowingStatusForFeedGroup(
                containing: first,
                isFollowed: true,
                in: realm,
                now: changedAt
            )
        }

        XCTAssertEqual(pendingMutation(for: first, in: realm)?.changedAt, changedAt)
        XCTAssertEqual(pendingMutation(for: duplicate, in: realm)?.changedAt, changedAt)
        let firstGeneration = try XCTUnwrap(pendingMutation(for: first, in: realm)?.generation)

        try realm.write {
            Feed.setFollowingStatusForFeedGroup(
                containing: first,
                isFollowed: true,
                in: realm,
                now: changedAt.addingTimeInterval(60)
            )
        }

        XCTAssertEqual(pendingMutation(for: first, in: realm)?.generation, firstGeneration)
    }

    func testChangingCategoryBadgeJournalsOnlyChangedVisibleFeeds() throws {
        let configuration = makeConfiguration(objectTypes: [Feed.self])
        let realm = try Realm(configuration: configuration)
        let categoryID = UUID()
        let changed = makeFeed(url: "https://example.com/changed")
        changed.categoryID = categoryID
        let unchanged = makeFeed(url: "https://example.com/unchanged")
        unchanged.categoryID = categoryID
        unchanged.showsUnseenBadge = false
        let archived = makeFeed(url: "https://example.com/archived")
        archived.categoryID = categoryID
        archived.isArchived = true
        try realm.write {
            realm.add(changed)
            realm.add(unchanged)
            realm.add(archived)
        }

        try realm.write {
            Feed.setShowsUnseenBadge(false, forCategoryID: categoryID, in: realm)
        }

        XCTAssertNotNil(pendingMutation(for: changed, in: realm))
        XCTAssertNil(pendingMutation(for: unchanged, in: realm))
        XCTAssertNil(pendingMutation(for: archived, in: realm))
    }

    func testAddingAndSoftDeletingOPDSCatalogJournalsBothMutations() throws {
        let configuration = makeConfiguration(objectTypes: [OPDSCatalog.self])
        let realm = try Realm(configuration: configuration)
        let addedAt = Date(timeIntervalSinceReferenceDate: 52_000)
        let catalog: OPDSCatalog = try realm.write {
            OPDSCatalog.add(
                title: "Library",
                url: "https://example.com/opds",
                to: realm,
                at: addedAt
            )
        }

        XCTAssertEqual(pendingMutation(for: catalog, in: realm)?.changedAt, addedAt)

        let deletedAt = Date(timeIntervalSinceReferenceDate: 53_000)
        try realm.write {
            catalog.softDelete(at: deletedAt)
        }

        XCTAssertTrue(catalog.isDeleted)
        XCTAssertEqual(pendingMutation(for: catalog, in: realm)?.changedAt, deletedAt)
        let deletedGeneration = try XCTUnwrap(pendingMutation(for: catalog, in: realm)?.generation)

        try realm.write {
            XCTAssertFalse(catalog.softDelete(at: deletedAt.addingTimeInterval(60)))
        }
        XCTAssertEqual(pendingMutation(for: catalog, in: realm)?.generation, deletedGeneration)
    }

    @RealmBackgroundActor
    func testEbookMetadataJournalsPublicationOnlyUpdateOnce() async throws {
        let configuration = makeConfiguration(objectTypes: [ContentFile.self])
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let file = ContentFile()
        file.url = URL(string: "ebook://ebook/load/test.epub")!
        file.updateCompoundKey()
        try await realm.asyncWrite {
            realm.add(file)
        }
        let publicationDate = Date(timeIntervalSinceReferenceDate: 56_000)
        let mutationDate = Date(timeIntervalSinceReferenceDate: 57_000)

        try await EbookFileManager.applyMetadataUpdates(
            images: [],
            titles: [],
            authors: [],
            publicationDates: [(file, publicationDate)],
            physicalMedia: [],
            at: mutationDate
        )

        XCTAssertEqual(file.publicationDate, publicationDate)
        let firstGeneration = try XCTUnwrap(
            pendingMutation(for: file, in: realm)?.generation
        )
        XCTAssertEqual(pendingMutation(for: file, in: realm)?.changedAt, mutationDate)

        try await EbookFileManager.applyMetadataUpdates(
            images: [],
            titles: [],
            authors: [],
            publicationDates: [(file, publicationDate)],
            physicalMedia: [],
            at: mutationDate.addingTimeInterval(60)
        )

        XCTAssertEqual(
            pendingMutation(for: file, in: realm)?.generation,
            firstGeneration
        )
    }

    @RealmBackgroundActor
    func testRestoreCategoryJournalsCategoryAndConfigurationWithOneTimestamp() async throws {
        let configuration = makeConfiguration(objectTypes: [
            LibraryConfiguration.self,
            FeedCategory.self,
            UserScript.self,
        ])
        let originalConfiguration = LibraryDataManager.realmConfiguration
        LibraryDataManager.realmConfiguration = configuration
        defer { LibraryDataManager.realmConfiguration = originalConfiguration }
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let category = FeedCategory()
        category.isArchived = true
        category.isDeleted = true
        let libraryConfiguration = LibraryConfiguration()
        try await realm.asyncWrite {
            realm.add(category)
            realm.add(libraryConfiguration)
        }
        let changedAt = Date(timeIntervalSinceReferenceDate: 58_000)

        let result = try await LibraryDataManager.shared.restoreCategory(
            categoryID: category.id,
            at: changedAt
        )

        XCTAssertEqual(result.categoryID, category.id)
        XCTAssertEqual(result.configurationID, libraryConfiguration.id)
        XCTAssertTrue(result.categoryChanged)
        XCTAssertTrue(result.configurationChanged)
        XCTAssertFalse(category.isArchived)
        XCTAssertFalse(category.isDeleted)
        XCTAssertEqual(Array(libraryConfiguration.categoryIDs), [category.id])
        XCTAssertEqual(pendingMutation(for: category, in: realm)?.changedAt, changedAt)
        XCTAssertEqual(
            pendingMutation(for: libraryConfiguration, in: realm)?.changedAt,
            changedAt
        )

        let categoryGeneration = try XCTUnwrap(
            pendingMutation(for: category, in: realm)?.generation
        )
        let configurationGeneration = try XCTUnwrap(
            pendingMutation(for: libraryConfiguration, in: realm)?.generation
        )
        let replay = try await LibraryDataManager.shared.restoreCategory(
            categoryID: category.id,
            at: changedAt.addingTimeInterval(60)
        )
        XCTAssertFalse(replay.categoryChanged)
        XCTAssertFalse(replay.configurationChanged)
        XCTAssertEqual(pendingMutation(for: category, in: realm)?.generation, categoryGeneration)
        XCTAssertEqual(
            pendingMutation(for: libraryConfiguration, in: realm)?.generation,
            configurationGeneration
        )
    }

    @RealmBackgroundActor
    func testRestoreDeletedCategoryKeepsExistingConfigurationReferenceWithoutRejournalingIt() async throws {
        let configuration = makeConfiguration(objectTypes: [
            LibraryConfiguration.self,
            FeedCategory.self,
            UserScript.self,
        ])
        let originalConfiguration = LibraryDataManager.realmConfiguration
        LibraryDataManager.realmConfiguration = configuration
        defer { LibraryDataManager.realmConfiguration = originalConfiguration }
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let category = FeedCategory()
        category.isDeleted = true
        let libraryConfiguration = LibraryConfiguration()
        libraryConfiguration.categoryIDs.append(category.id)
        try await realm.asyncWrite {
            realm.add(category)
            realm.add(libraryConfiguration)
        }
        let changedAt = Date(timeIntervalSinceReferenceDate: 59_000)

        let result = try await LibraryDataManager.shared.restoreCategory(
            categoryID: category.id,
            at: changedAt
        )

        XCTAssertTrue(result.categoryChanged)
        XCTAssertFalse(result.configurationChanged)
        XCTAssertFalse(category.isDeleted)
        XCTAssertEqual(Array(libraryConfiguration.categoryIDs), [category.id])
        XCTAssertEqual(pendingMutation(for: category, in: realm)?.changedAt, changedAt)
        XCTAssertNil(pendingMutation(for: libraryConfiguration, in: realm))
    }

    @RealmBackgroundActor
    func testDuplicateFeedRespectsCreateAndOverwriteCommands() async throws {
        let configuration = makeConfiguration(objectTypes: [
            FeedCategory.self,
            Feed.self,
        ])
        let originalConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        defer { ReaderContentLoader.feedEntryRealmConfiguration = originalConfiguration }
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let sourceCategory = FeedCategory()
        let destinationCategory = FeedCategory()
        let source = makeFeed(url: "https://example.com/feed.xml")
        source.title = "Source"
        source.categoryID = sourceCategory.id
        let existing = makeFeed(url: "https://example.com/feed.xml")
        existing.title = "Existing"
        existing.categoryID = destinationCategory.id
        try await realm.asyncWrite {
            realm.add([sourceCategory, destinationCategory])
            realm.add([source, existing])
        }

        let overwritten = try await LibraryDataManager.shared.duplicateFeed(
            ThreadSafeReference(to: source),
            inCategory: ThreadSafeReference(to: destinationCategory),
            overwriteExisting: true
        )
        XCTAssertEqual(overwritten.outcome, .overwroteExisting)
        XCTAssertEqual(overwritten.feedID, existing.id)
        XCTAssertEqual(
            realm.object(ofType: Feed.self, forPrimaryKey: existing.id)?.title,
            "Source"
        )
        XCTAssertNotNil(pendingMutation(for: existing, in: realm))

        let created = try await LibraryDataManager.shared.duplicateFeed(
            ThreadSafeReference(to: source),
            inCategory: ThreadSafeReference(to: destinationCategory),
            overwriteExisting: false
        )
        XCTAssertEqual(created.outcome, .createdNew)
        XCTAssertEqual(created.categoryID, destinationCategory.id)
        XCTAssertNotEqual(created.feedID, existing.id)
        XCTAssertEqual(
            realm.object(ofType: Feed.self, forPrimaryKey: created.feedID)?.title,
            "Source"
        )
        let createdFeed = try XCTUnwrap(
            realm.object(ofType: Feed.self, forPrimaryKey: created.feedID)
        )
        XCTAssertNotNil(pendingMutation(for: createdFeed, in: realm))
    }

    private func makeConfiguration(objectTypes: [Object.Type]) -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = objectTypes
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private func makeFeed(url: String) -> Feed {
        let feed = Feed()
        feed.title = url
        feed.rssUrl = URL(string: url)!
        feed.iconUrl = URL(string: "https://example.com/icon.png")!
        return feed
    }

    private func pendingMutation(
        for object: Object,
        in realm: Realm
    ) -> BigSyncPendingMutation? {
        let primaryKey = object.objectSchema.primaryKeyProperty!.name
        let objectIdentifier = String(describing: object[primaryKey]!)
        return realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: object.objectSchema.className + "." + objectIdentifier
        )
    }
}
