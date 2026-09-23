import BigSyncKit
import LakeOfFireContent
import RealmSwift
import RealmSwiftGaps
import XCTest

final class LibraryRegressionTests: XCTestCase {
    @RealmBackgroundActor
    func testDuplicateFeedOverwritesDestinationAndConsumesReferencesOnce() async throws {
        let configuration = makeConfiguration()
        let originalConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        defer { ReaderContentLoader.feedEntryRealmConfiguration = originalConfiguration }
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let realm = try await Realm(configuration: configuration, actor: RealmBackgroundActor.shared)

        let sourceCategory = FeedCategory()
        let destinationCategory = FeedCategory()
        let source = makeFeed(title: "source")
        source.categoryID = sourceCategory.id
        let existing = makeFeed(title: "old destination")
        existing.categoryID = destinationCategory.id
        try await realm.asyncWrite {
            realm.add([sourceCategory, destinationCategory, source, existing])
        }

        let resultID = try await LibraryDataManager.shared.duplicateFeed(
            ThreadSafeReference(to: source),
            inCategory: ThreadSafeReference(to: destinationCategory),
            overwriteExisting: true
        )
        XCTAssertEqual(resultID, existing.id)
        XCTAssertEqual(destinationCategory.getFeeds()?.map(\.id), [existing.id])
        XCTAssertEqual(destinationCategory.getFeeds()?.first?.title, "source")

        let createdID = try await LibraryDataManager.shared.duplicateFeed(
            ThreadSafeReference(to: source),
            inCategory: ThreadSafeReference(to: destinationCategory),
            overwriteExisting: false
        )
        let created = try XCTUnwrap(createdID.flatMap { realm.object(ofType: Feed.self, forPrimaryKey: $0) })
        XCTAssertNotEqual(created.id, existing.id)
        XCTAssertEqual(created.categoryID, destinationCategory.id)
        XCTAssertEqual(created.title, source.title)
        XCTAssertEqual(created.rssUrl, source.rssUrl)
        XCTAssertEqual(destinationCategory.getFeeds()?.count, 2)
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            FeedCategory.self,
            Feed.self,
            LibraryConfiguration.self,
            BigSyncPendingMutation.self,
        ]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        return configuration
    }

    private func makeFeed(title: String) -> Feed {
        let feed = Feed()
        feed.title = title
        feed.rssUrl = URL(string: "https://example.com/feed.xml")!
        return feed
    }
}
