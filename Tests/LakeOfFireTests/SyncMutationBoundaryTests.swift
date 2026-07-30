import BigSyncKit
import RealmSwift
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

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString
        )
        configuration.objectTypes = [
            Feed.self,
            OPDSCatalog.self,
            BigSyncPendingMutation.self,
        ]
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
