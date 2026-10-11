import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

final class LibraryRSSAddConfigurationOwnershipTests: XCTestCase {
    @MainActor
    func testRSSAddCreatesAndSelectsInTheRequestedRealm() async throws {
        let configurationA = makeConfiguration()
        let configurationB = makeConfiguration()
        let originalLibraryConfiguration = LibraryDataManager.realmConfiguration
        let originalFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        LibraryDataManager.realmConfiguration = configurationB
        ReaderContentLoader.feedEntryRealmConfiguration = configurationB
        defer {
            LibraryDataManager.realmConfiguration = originalLibraryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = originalFeedConfiguration
        }
        let viewModel = LibraryManagerViewModel()
        let rssURL = URL(string: "https://example.com/rss.xml")!

        try await viewModel.add(rssURL: rssURL, title: "Requested feed", realmConfiguration: configurationA)

        let feed = try XCTUnwrap(viewModel.selectedFeed)
        XCTAssertEqual(feed.rssUrl, rssURL)
        XCTAssertEqual(feed.title, "Requested feed")
        XCTAssertEqual(feed.realm?.configuration.inMemoryIdentifier, configurationA.inMemoryIdentifier)
        let feedID = feed.id
        let categoryID = try XCTUnwrap(feed.categoryID)
        try await { @RealmBackgroundActor in
            let realmA = try await RealmBackgroundActor.shared.cachedRealm(for: configurationA)
            let realmB = try await RealmBackgroundActor.shared.cachedRealm(for: configurationB)
            let category = try XCTUnwrap(realmA.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
            XCTAssertEqual(category.title, "My Library")
            let library = try XCTUnwrap(realmA.objects(LibraryConfiguration.self).filter { !$0.isDeleted }.first)
            XCTAssertTrue(library.categoryIDs.contains(categoryID))
            XCTAssertNotNil(realmA.object(ofType: Feed.self, forPrimaryKey: feedID))
            XCTAssertEqual(realmB.objects(Feed.self).count, 0)
            XCTAssertEqual(realmB.objects(FeedCategory.self).count, 0)
            XCTAssertNotNil(realmA.object(
                ofType: BigSyncPendingMutation.self,
                forPrimaryKey: Feed.className() + "." + feedID.uuidString
            ))
        }()
    }

    @MainActor
    func testDeletedDestinationDoesNotCreateAFallbackCategoryOrFeed() async throws {
        let configuration = makeConfiguration()
        let originalLibraryConfiguration = LibraryDataManager.realmConfiguration
        LibraryDataManager.realmConfiguration = configuration
        defer { LibraryDataManager.realmConfiguration = originalLibraryConfiguration }
        let realm = try await Realm.open(configuration: configuration)
        let category = FeedCategory()
        category.isDeleted = true
        try realm.write { realm.add(category) }
        let viewModel = LibraryManagerViewModel()
        do {
            try await viewModel.add(
                rssURL: URL(string: "https://example.com/rss.xml")!,
                title: nil,
                toCategory: ThreadSafeReference(to: category),
                realmConfiguration: configuration
            )
            XCTFail("A deleted explicit destination must fail instead of creating a fallback category")
        } catch RealmBackgroundActorError.unableToResolveObject {
        }
        await realm.asyncRefresh()
        XCTAssertEqual(realm.objects(FeedCategory.self).count, 1)
        XCTAssertTrue(realm.objects(Feed.self).isEmpty)
        XCTAssertNil(viewModel.selectedFeed)
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, FeedDirectory.self, Feed.self,
            UserScript.self, UserScriptAllowedDomain.self, BigSyncPendingMutation.self,
        ]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        return configuration
    }
}
