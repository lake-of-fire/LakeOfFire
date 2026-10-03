import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryFeedEditorOwnershipTests: XCTestCase {
    func testDelayedFeedFieldAndPasteStayInOriginatingRealm() async throws {
        let originalConfiguration = configuration()
        let replacementConfiguration = configuration()
        let original = try Realm(configuration: originalConfiguration)
        let replacement = try Realm(configuration: replacementConfiguration)
        let categoryID = UUID()
        let feedID = UUID()
        let originalFeed = try installFeed(id: feedID, categoryID: categoryID, title: "Original", in: original)
        let replacementFeed = try installFeed(
            id: feedID, categoryID: categoryID, title: "Replacement", in: replacement
        )
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = originalConfiguration
        let model = LibraryFeedFormSectionsViewModel(feed: originalFeed)
        let initialized = await waitUntil { model.hasInitializedValues }
        XCTAssertTrue(initialized)
        model.feedTitle = "Leading original edit"
        model.feedTitle = "Delayed original edit"
        LibraryDataManager.realmConfiguration = replacementConfiguration
        let edited = await waitUntil { original.refresh(); return originalFeed.title == "Delayed original edit" }
        XCTAssertTrue(edited)
        try await model.pasteRSSURL(strings: ["https://example.com/edited.xml"]).value
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(originalFeed.rssUrl.absoluteString, "https://example.com/edited.xml")
        XCTAssertEqual(model.feedURL, "https://example.com/edited.xml")
        XCTAssertEqual(replacementFeed.title, "Replacement")
        XCTAssertEqual(replacementFeed.rssUrl.absoluteString, "https://example.com/original.xml")
        XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertFalse(original.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testFeedWriterRechecksCurrentCategoryAndDeletionBeforeMutating() async throws {
        let realm = try Realm(configuration: configuration())
        let categoryID = UUID()
        let feed = try installFeed(id: UUID(), categoryID: categoryID, title: "Original", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        let pending = model.pasteRSSURL(strings: ["https://example.com/blocked.xml"])
        try realm.write { category.opmlURL = URL(string: "https://example.com/managed.opml") }
        try await pending.value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://example.com/original.xml")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        try realm.write { category.opmlURL = nil; category.isDeleted = true }
        XCTAssertFalse(feed.isUserEditable())
        try await model.pasteRSSURL(strings: ["https://example.com/deleted-category.xml"]).value
        try realm.write { realm.delete(category) }
        XCTAssertFalse(feed.isUserEditable())
        try await model.pasteRSSURL(strings: ["https://example.com/missing-category.xml"]).value
        let freshCategory = FeedCategory()
        freshCategory.id = categoryID
        try realm.write { realm.add(freshCategory); feed.isDeleted = true }
        try await model.pasteRSSURL(strings: ["https://example.com/deleted-feed.xml"]).value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://example.com/original.xml")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testFeedHydrationAndNoOpPasteLeaveJournalGenerationStable() async throws {
        let realm = try Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "Original", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed)
        let initialized = await waitUntil { model.hasInitializedValues }
        XCTAssertTrue(initialized)
        try await model.pasteRSSURL(strings: [feed.rssUrl.absoluteString]).value
        realm.refresh()
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        try await model.pasteRSSURL(strings: ["https://example.com/changed.xml"]).value
        realm.refresh()
        let generations = journalGenerations(in: realm)
        XCTAssertEqual(generations.count, 1)
        model.refresh()
        try await model.pasteRSSURL(strings: ["https://example.com/changed.xml"]).value
        // Await the same serialized writer lane after a complete debounce window.
        try await Task.sleep(for: .milliseconds(500))
        try await model.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertEqual(journalGenerations(in: realm), generations)
    }

    func testLibraryButtonObserversKeepTheirPublishedRealmAfterReplacement() async throws {
        let originalConfiguration = configuration()
        let original = try Realm(configuration: originalConfiguration)
        let replacementConfiguration = configuration()
        let replacement = try Realm(configuration: replacementConfiguration)
        let categoryID = UUID()
        let feedID = UUID()
        let originalFeed = try installFeed(id: feedID, categoryID: categoryID, title: "Original", in: original)
        _ = try installFeed(id: feedID, categoryID: categoryID, title: "Replacement", in: replacement)
        let libraryID = UUID()
        for realm in [original, replacement] {
            let library = LibraryConfiguration()
            library.id = libraryID
            library.categoryIDs.append(categoryID)
            try realm.write { realm.add(library) }
        }
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = originalConfiguration
        let webFeedState = WebFeedButtonLibraryState(realmConfiguration: originalConfiguration)
        let categoryState = ContentCategoryButtonsViewModel(realmConfiguration: originalConfiguration)
        webFeedState.startIfNeeded()
        let observed = await waitUntil {
            webFeedState.feed(matching: [originalFeed.rssUrl])?.title == "Original"
                && categoryState.libraryConfiguration != nil
        }
        XCTAssertTrue(observed)
        LibraryDataManager.realmConfiguration = replacementConfiguration
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: originalConfiguration)
            try await realm.asyncWrite {
                let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: feedID))
                feed.title = "Updated original"
                feed.refreshChangeMetadata(explicitlyModified: true)
                let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                category.title = "Updated original category"
                category.refreshChangeMetadata(explicitlyModified: true)
                let library = try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryID))
                library.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        let updated = await waitUntil {
            webFeedState.feed(matching: [originalFeed.rssUrl])?.title == "Updated original"
                && webFeedState.userCategories?.first?.title == "Updated original category"
                && categoryState.libraryConfiguration?.getCategories()?.first?.title == "Updated original category"
        }
        XCTAssertTrue(updated)
        replacement.refresh()
        XCTAssertEqual(replacement.object(ofType: Feed.self, forPrimaryKey: feedID)?.title, "Replacement")
        XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testFeedFieldCanReturnToEarlierUserValueAfterHydration() async throws {
        let realm = try Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "Original", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed)
        let initialized = await waitUntil { model.hasInitializedValues }
        XCTAssertTrue(initialized)
        model.feedTitle = "User value"
        let first = await waitUntil { realm.refresh(); return feed.title == "User value" }
        XCTAssertTrue(first)
        try realm.write { feed.title = "Hydrated value" }
        model.refresh()
        model.feedTitle = "User value"
        let second = await waitUntil { realm.refresh(); return feed.title == "User value" }
        XCTAssertTrue(second)
    }

    func testFeedPasteReplacesBufferedOlderURLWithoutLaterJournalRefresh() async throws {
        let realm = try Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "Original", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed)
        let initialized = await waitUntil { model.hasInitializedValues }
        XCTAssertTrue(initialized)
        model.feedURL = "https://example.com/leading.xml"
        model.feedURL = "https://example.com/buffered.xml"
        try await model.pasteRSSURL(strings: ["https://example.com/pasted.xml"]).value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://example.com/pasted.xml")
        let generations = journalGenerations(in: realm)
        try await Task.sleep(for: .milliseconds(500))
        try await model.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://example.com/pasted.xml")
        XCTAssertEqual(model.feedURL, "https://example.com/pasted.xml")
        XCTAssertEqual(journalGenerations(in: realm), generations)
    }

    private func configuration() -> Realm.Configuration {
        var result = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        result.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&result)
        let captured = result
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        return result
    }

    private func installFeed(id: UUID, categoryID: UUID, title: String, in realm: Realm) throws -> Feed {
        let category = FeedCategory()
        category.id = categoryID
        let feed = Feed()
        feed.id = id
        feed.categoryID = categoryID
        feed.title = title
        feed.rssUrl = URL(string: "https://example.com/original.xml")!
        try realm.write { realm.add(category); realm.add(feed) }
        return feed
    }

    private func journalGenerations(in realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, $0.generation)
        })
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
