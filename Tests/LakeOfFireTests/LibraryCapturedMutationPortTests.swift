import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@available(iOS 16.0, macOS 13.0, *)
@MainActor
final class LibraryCapturedMutationPortTests: XCTestCase {
    func testManagerAddAndDuplicateStayInRealmCapturedAtInitialization() async throws {
        let previousLibrary = LibraryDataManager.realmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            LibraryDataManager.realmConfiguration = previousLibrary
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }

        let captured = makeConfiguration()
        let replacement = makeConfiguration()
        LibraryDataManager.realmConfiguration = captured
        ReaderContentLoader.feedEntryRealmConfiguration = captured
        let manager = LibraryManagerViewModel(observesRealm: false)

        LibraryDataManager.realmConfiguration = replacement
        ReaderContentLoader.feedEntryRealmConfiguration = replacement

        let rssURL = URL(string: "https://example.org/captured.xml")!
        try await manager.add(rssURL: rssURL, title: "Captured feed")
        let first = try XCTUnwrap(manager.selectedFeed)
        XCTAssertEqual(first.rssUrl, rssURL)
        let categoryID = try XCTUnwrap(first.categoryID)

        let capturedRealm = try await Realm.open(configuration: captured)
        let category = try XCTUnwrap(
            capturedRealm.object(
                ofType: FeedCategory.self,
                forPrimaryKey: categoryID
            )
        )
        let firstID = first.id

        try await manager.duplicate(
            feed: ThreadSafeReference(to: first),
            inCategory: ThreadSafeReference(to: category),
            overwriteExisting: false
        )
        let duplicate = try XCTUnwrap(manager.selectedFeed)
        XCTAssertNotEqual(duplicate.id, firstID)
        XCTAssertEqual(duplicate.categoryID, categoryID)
        XCTAssertEqual(duplicate.rssUrl, rssURL)

        let counts = try await Task { @RealmBackgroundActor in
            let capturedRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: captured
            )
            let replacementRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: replacement
            )
            return (
                capturedRealm.objects(LibraryConfiguration.self).count,
                capturedRealm.objects(FeedCategory.self).count,
                capturedRealm.objects(Feed.self).count,
                replacementRealm.objects(LibraryConfiguration.self).count,
                replacementRealm.objects(FeedCategory.self).count,
                replacementRealm.objects(Feed.self).count
            )
        }.value
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 2)
        XCTAssertEqual(counts.3, 0)
        XCTAssertEqual(counts.4, 0)
        XCTAssertEqual(counts.5, 0)
    }

    func testExplicitScriptCreationUsesSuppliedRealmAfterGlobalReplacement() async throws {
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }

        let captured = makeConfiguration()
        let replacement = makeConfiguration()
        LibraryDataManager.realmConfiguration = replacement

        let scriptID = try await Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.createEmptyScript(
                addToLibrary: true,
                realmConfiguration: captured
            )
        }.value

        let result = try await Task { @RealmBackgroundActor in
            let capturedRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: captured
            )
            let replacementRealm = try await RealmBackgroundActor.shared.cachedRealm(
                for: replacement
            )
            let library = try XCTUnwrap(
                capturedRealm.objects(LibraryConfiguration.self).first
            )
            return (
                capturedRealm.object(
                    ofType: UserScript.self,
                    forPrimaryKey: scriptID
                ) != nil,
                library.userScriptIDs.contains(scriptID),
                replacementRealm.objects(UserScript.self).count,
                replacementRealm.objects(LibraryConfiguration.self).count
            )
        }.value
        XCTAssertTrue(result.0)
        XCTAssertTrue(result.1)
        XCTAssertEqual(result.2, 0)
        XCTAssertEqual(result.3, 0)
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString
        )
        configuration.objectTypes = [
            LibraryConfiguration.self,
            FeedCategory.self,
            Feed.self,
            FeedDirectory.self,
            UserScript.self,
            UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }
}
