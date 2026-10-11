import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
import LakeOfFireCore
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryFeedEditingContinuationTests: XCTestCase {
    func testDelayedFieldWriteKeepsCapturedStorageAfterDefaultReplacement() async throws {
        let originalConfiguration = configuration()
        let replacementConfiguration = configuration()
        let original = try await Realm(configuration: originalConfiguration)
        let replacement = try await Realm(configuration: replacementConfiguration)
        let feed = try installFeed(in: original)
        let other = try installFeed(id: feed.id, in: replacement)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Captured writer suspended")
        let gate = LibraryFeedContinuationGate()
        let writer = model.writeFeedAsync(field: .title, beforeWrite: {
            started.fulfill()
            await gate.wait()
        }) { feed in
            feed.title = "Captured edit"
            return true
        }
        defer { writer.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = replacementConfiguration
        await gate.release()
        try await writer.value
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(feed.title, "Captured edit")
        XCTAssertEqual(other.title, "Original")
        XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testOlderWriterCannotBeatNewEditorsIntentionalNoOp() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let oldEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Older editor suspended")
        let gate = LibraryFeedContinuationGate()
        let older = oldEditor.writeFeedAsync(field: .title, beforeWrite: {
            started.fulfill()
            await gate.wait()
        }) { feed in
            feed.title = "Obsolete"
            return true
        }
        defer { older.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let newEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        // Exercise the form publisher itself: the second same-value input is
        // inside the debounce window but reserves its intent synchronously.
        newEditor.feedTitle = "Original"
        newEditor.feedTitle = "Original"
        await gate.release()
        try await older.value
        newEditor.finishEditing()
        try await newEditor.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testDelayedWriterRejectsReplacementFeedIncarnation() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let id = feed.id
        let categoryID = feed.categoryID
        let createdAt = feed.createdAt
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Writer suspended before record replacement")
        let gate = LibraryFeedContinuationGate()
        let writer = model.writeFeedAsync(field: .title, beforeWrite: {
            started.fulfill()
            await gate.wait()
        }) { feed in
            feed.title = "Obsolete"
            return true
        }
        defer { writer.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let replacement = Feed()
        replacement.id = id
        replacement.categoryID = categoryID
        replacement.createdAt = createdAt.addingTimeInterval(1)
        replacement.title = "Replacement"
        try realm.write { realm.delete(feed); realm.add(replacement) }
        await gate.release()
        try await writer.value
        realm.refresh()
        XCTAssertEqual(replacement.title, "Replacement")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertNil(try model.previewEntries())
    }

    func testDelayedWriterRejectsManagedOrReplacedCategory() async throws {
        for replaceCategory in [false, true] {
            let realm = try await Realm(configuration: configuration())
            let feed = try installFeed(in: realm)
            let category = try XCTUnwrap(feed.getCategory())
            let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let started = expectation(description: "Writer suspended before category change")
            let gate = LibraryFeedContinuationGate()
            let writer = model.writeFeedAsync(field: .title, beforeWrite: {
                started.fulfill()
                await gate.wait()
            }) { feed in
                feed.title = "Obsolete"
                return true
            }
            defer { writer.cancel(); Task { await gate.release() } }
            await fulfillment(of: [started], timeout: 5)
            if replaceCategory {
                let replacement = FeedCategory()
                replacement.id = category.id
                replacement.createdAt = category.createdAt.addingTimeInterval(1)
                try realm.write { realm.delete(category); realm.add(replacement) }
            } else {
                try realm.write { category.opmlURL = URL(string: "https://example.com/managed.opml") }
            }
            await gate.release()
            try await writer.value
            realm.refresh()
            XCTAssertEqual(feed.title, "Original")
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    func testDelayedMetadataCannotFillAfterSourceURLChanges() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm, title: "")
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: source, identifier: generation)
        let started = expectation(description: "Metadata fetch suspended")
        let gate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(expectedRSSURL: source, expectedGeneration: generation) { _ in
                started.fulfill()
                await gate.wait()
                return LibraryFeedOpenGraphMetadata(
                    url: source.domainURL, title: "Old source title", description: "Old description"
                )
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        try await model.pasteRSSURL(strings: ["https://other.example/new.xml"]).value
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(feed.title, "")
        XCTAssertNil(feed.markdownDescription)
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://other.example/new.xml")
    }

    func testMetadataCannotReplaceAnExplicitEmptyDescriptionEdit() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm, title: "Original")
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: source, identifier: generation)
        let started = expectation(description: "Metadata write suspended")
        let gate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(
                expectedRSSURL: source, expectedGeneration: generation,
                beforeWrite: { started.fulfill(); await gate.wait() }
            ) { _ in
                LibraryFeedOpenGraphMetadata(url: source.domainURL, title: nil, description: "Automatic")
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        model.feedDescription = ""
        await gate.release()
        await metadata.value
        try await model.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertNotEqual(feed.markdownDescription, "Automatic")
        XCTAssertEqual(model.feedDescription, "")
    }

    func testHydrationDoesNotPublishNewMutations() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        model.refresh()
        model.finishEditing()
        try await model.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertEqual(model.feedTitle, "Original")
    }

    func testLateMetadataCannotOutrankAnotherEditorsEmptyInput() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm, title: "")
        let oldEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        oldEditor.beginMetadataRefresh(rssURL: source, identifier: generation)
        let started = expectation(description: "Older metadata request suspended")
        let gate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await oldEditor.refreshFromOpenGraph(expectedRSSURL: source, expectedGeneration: generation) { _ in
                await gate.wait(onFirstWait: { started.fulfill() })
                return LibraryFeedOpenGraphMetadata(url: source.domainURL, title: "Obsolete", description: nil)
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let newEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        newEditor.feedTitle = ""
        newEditor.finishEditing()
        try await newEditor.writeFeedAsync { _ in false }.value
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(feed.title, "")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testRetirementDoesNotReplayCancelledMetadata() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: source, identifier: generation)
        let started = expectation(description: "Metadata attempt suspended before write")
        let gate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(
                expectedRSSURL: source, expectedGeneration: generation,
                beforeWrite: { started.fulfill(); await gate.wait() }
            ) { _ in
                LibraryFeedOpenGraphMetadata(url: source.domainURL, title: nil, description: "Cancelled")
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        metadata.cancel()
        model.finishEditing()
        try await model.writeFeedAsync { _ in false }.value
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertNil(feed.markdownDescription)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    private func configuration() -> Realm.Configuration {
        var value = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        value.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&value)
        let captured = value
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        return value
    }

    private func installFeed(id: UUID = UUID(), in realm: Realm, title: String = "Original") throws -> Feed {
        let category = FeedCategory()
        let feed = Feed()
        feed.id = id
        feed.categoryID = category.id
        feed.title = title
        feed.rssUrl = URL(string: "https://example.com/feed.xml")!
        try realm.write { realm.add(category); realm.add(feed) }
        return feed
    }
}

private actor LibraryFeedContinuationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait(onFirstWait: (@Sendable () -> Void)? = nil) async {
        guard !released else { return }
        onFirstWait?()
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
