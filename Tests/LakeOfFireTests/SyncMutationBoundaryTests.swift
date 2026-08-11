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
    }

    private func makeConfiguration(objectTypes: [Object.Type]) -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
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
