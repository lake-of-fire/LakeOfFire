import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class LibraryRegressionTests: XCTestCase {
    func test_scriptPublisherKeepsObservedRealmAfterConfigurationReplacement() async throws {
        try await verifyScriptPublisherKeepsObservedRealmAfterConfigurationReplacement()
    }

    @RealmBackgroundActor
    private func verifyScriptPublisherKeepsObservedRealmAfterConfigurationReplacement() async throws {
        let observedConfiguration = makeScriptConfiguration()
        let replacementConfiguration = makeScriptConfiguration()
        let originalConfiguration = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = originalConfiguration }

        let observedRealm = try await Realm(
            configuration: observedConfiguration, actor: RealmBackgroundActor.shared
        )
        let observedLibrary = LibraryConfiguration()
        let initialScript = UserScript()
        try await observedRealm.asyncWrite {
            observedRealm.add(observedLibrary)
            observedRealm.add(initialScript)
        }

        LibraryDataManager.realmConfiguration = observedConfiguration
        let manager = LibraryDataManager()
        defer { manager.realmCancellables.forEach { $0.cancel() } }

        // The initial collection publication proves both the real subscription
        // and its debounced callback have run before replacing the global Realm.
        let initialDelivery = try await eventually {
            observedLibrary.userScriptIDs.contains(initialScript.id)
        }
        XCTAssertTrue(initialDelivery)
        guard initialDelivery else { return }
        let recordName = "LibraryConfiguration.\(observedLibrary.id)"
        let initialGeneration = try XCTUnwrap(observedRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
        )?.generation)

        let replacementRealm = try await Realm(
            configuration: replacementConfiguration, actor: RealmBackgroundActor.shared
        )
        // An orphan in the replacement Realm exposes a misrouted callback as
        // a changed library row and a durable journal entry there.
        let replacementLibrary = LibraryConfiguration()
        let replacementOrphan = UserScript()
        try await replacementRealm.asyncWrite {
            replacementRealm.add(replacementLibrary)
            replacementRealm.add(replacementOrphan)
        }
        let replacementRecordName = "LibraryConfiguration.\(replacementLibrary.id)"
        XCTAssertNil(replacementRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: replacementRecordName
        ))

        LibraryDataManager.realmConfiguration = replacementConfiguration
        let nextObservedScript = UserScript()
        try await observedRealm.asyncWrite { observedRealm.add(nextObservedScript) }

        let nextDelivery = try await eventually {
            observedLibrary.userScriptIDs.contains(nextObservedScript.id)
        }
        XCTAssertTrue(nextDelivery)
        XCTAssertEqual(Array(observedLibrary.userScriptIDs), [initialScript.id, nextObservedScript.id])
        let nextMutation = try XCTUnwrap(observedRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
        ))
        XCTAssertNotEqual(nextMutation.generation, initialGeneration)
        XCTAssertEqual(Array(replacementLibrary.userScriptIDs), [])
        XCTAssertNil(replacementRealm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: replacementRecordName
        ))
    }

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

    private func makeScriptConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    @RealmBackgroundActor
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func makeFeed(title: String) -> Feed {
        let feed = Feed()
        feed.title = title
        feed.rssUrl = URL(string: "https://example.com/feed.xml")!
        return feed
    }
}
