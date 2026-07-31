import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class SyncMutationBoundaryTests: XCTestCase {
    func testFollowingFeedGroupUsesOneTimestampAndJournalsEveryFeed() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let first = makeFeed(url: "https://example.com/feed.xml")
        let duplicate = makeFeed(url: "https://EXAMPLE.com:443/feed.xml#fragment")
        try realm.write {
            realm.add(first)
            realm.add(duplicate)
        }
        let timestamp = Date(timeIntervalSinceReferenceDate: 50_000)

        try realm.write {
            Feed.setFollowingStatusForFeedGroup(
                containing: first,
                isFollowed: true,
                in: realm,
                now: timestamp
            )
        }

        XCTAssertTrue(first.isFollowed)
        XCTAssertTrue(duplicate.isFollowed)
        XCTAssertEqual(first.modifiedAt, timestamp)
        XCTAssertEqual(duplicate.modifiedAt, timestamp)
        XCTAssertEqual(first.explicitlyModifiedAt, timestamp)
        XCTAssertEqual(duplicate.explicitlyModifiedAt, timestamp)
        XCTAssertEqual(
            pendingMutation(for: first, in: realm)?.changedAt,
            timestamp
        )
        XCTAssertEqual(
            pendingMutation(for: duplicate, in: realm)?.changedAt,
            timestamp
        )
    }

    func testRepeatedFollowingFeedGroupUpdateDoesNotRewriteOrRejournalFeeds() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let first = makeFeed(url: "https://example.com/feed.xml")
        let duplicate = makeFeed(
            url: "https://EXAMPLE.com:443/feed.xml#fragment"
        )
        try realm.write {
            realm.add(first)
            realm.add(duplicate)
            Feed.setFollowingStatusForFeedGroup(
                containing: first,
                isFollowed: true,
                in: realm,
                now: Date(timeIntervalSinceReferenceDate: 54_000)
            )
        }
        let firstGeneration = try XCTUnwrap(
            pendingMutation(for: first, in: realm)?.generation
        )
        let duplicateGeneration = try XCTUnwrap(
            pendingMutation(for: duplicate, in: realm)?.generation
        )

        try realm.write {
            Feed.setFollowingStatusForFeedGroup(
                containing: first,
                isFollowed: true,
                in: realm,
                now: Date(timeIntervalSinceReferenceDate: 55_000)
            )
        }

        XCTAssertEqual(
            first.modifiedAt,
            Date(timeIntervalSinceReferenceDate: 54_000)
        )
        XCTAssertEqual(
            duplicate.modifiedAt,
            Date(timeIntervalSinceReferenceDate: 54_000)
        )
        XCTAssertEqual(
            pendingMutation(for: first, in: realm)?.generation,
            firstGeneration
        )
        XCTAssertEqual(
            pendingMutation(for: duplicate, in: realm)?.generation,
            duplicateGeneration
        )
    }

    func testChangingCategoryBadgePreferenceJournalsOnlyChangedVisibleFeeds() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let categoryID = UUID()
        let changed = makeFeed(url: "https://example.com/changed")
        changed.categoryID = categoryID
        let alreadyMatching = makeFeed(url: "https://example.com/matching")
        alreadyMatching.categoryID = categoryID
        alreadyMatching.showsUnseenBadge = false
        let archived = makeFeed(url: "https://example.com/archived")
        archived.categoryID = categoryID
        archived.isArchived = true
        try realm.write {
            realm.add(changed)
            realm.add(alreadyMatching)
            realm.add(archived)
        }
        let timestamp = Date(timeIntervalSinceReferenceDate: 51_000)

        try realm.write {
            Feed.setShowsUnseenBadge(
                false,
                forCategoryID: categoryID,
                in: realm,
                now: timestamp
            )
        }

        XCTAssertFalse(changed.showsUnseenBadge)
        XCTAssertNotNil(pendingMutation(for: changed, in: realm))
        XCTAssertNil(pendingMutation(for: alreadyMatching, in: realm))
        XCTAssertNil(pendingMutation(for: archived, in: realm))
    }

    func testAddingAndDeletingOPDSCatalogJournalsBothMutations() throws {
        let configuration = makeConfiguration()
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

        XCTAssertEqual(catalog.explicitlyModifiedAt, addedAt)
        XCTAssertEqual(pendingMutation(for: catalog, in: realm)?.changedAt, addedAt)

        let deletedAt = Date(timeIntervalSinceReferenceDate: 53_000)
        try realm.write {
            catalog.softDelete(at: deletedAt)
        }

        XCTAssertTrue(catalog.isDeleted)
        XCTAssertEqual(catalog.modifiedAt, deletedAt)
        XCTAssertEqual(pendingMutation(for: catalog, in: realm)?.changedAt, deletedAt)
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
    func testBulkBookmarkRemovalCreatesDurableTombstones() async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self])
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let first = Bookmark()
        first.url = URL(string: "https://example.com/first")!
        first.updateCompoundKey()
        let second = Bookmark()
        second.url = URL(string: "https://example.com/second")!
        second.updateCompoundKey()
        try await realm.asyncWrite {
            realm.add(first)
            realm.add(second)
        }
        let deletionDate = Date(timeIntervalSinceReferenceDate: 58_000)

        try await Bookmark.removeAll(
            realmConfiguration: configuration,
            at: deletionDate
        )

        XCTAssertTrue(first.isDeleted)
        XCTAssertTrue(second.isDeleted)
        XCTAssertEqual(pendingMutation(for: first, in: realm)?.changedAt, deletionDate)
        XCTAssertEqual(pendingMutation(for: second, in: realm)?.changedAt, deletionDate)
    }

    private func makeConfiguration(
        objectTypes: [Object.Type] = [Feed.self, OPDSCatalog.self]
    ) -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString
        )
        configuration.objectTypes = objectTypes + [BigSyncPendingMutation.self]
        BigSyncMutationTracking.install(
            configurations: [configuration],
            excludedClassNames: []
        )
        return configuration
    }

    private func makeFeed(url: String) -> Feed {
        let feed = Feed()
        feed.title = url
        feed.rssUrl = URL(string: url)!
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
