import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryFeedRefreshMutationTests: XCTestCase {
    func testEditorAndPasteURLReplacementInvalidateRefreshMetadata() async throws {
        for paste in [false, true] {
            let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
            let feed = try installFeed(in: realm)
            let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let replacement = URL(string: "https://other.example/new.xml")!
            if paste {
                try await model.pasteRSSURL(strings: [replacement.absoluteString]).value
            } else {
                try await model.writeFeedAsync { feed in
                    guard feed.rssUrl != replacement else { return false }
                    feed.rssUrl = replacement
                    return true
                }.value
            }
            await realm.asyncRefresh()
            XCTAssertEqual(feed.rssUrl, replacement)
            XCTAssertNil(feed.lastFetchedETag)
            XCTAssertNil(feed.lastFetchedModifiedAt)
            XCTAssertNil(feed.lastRefreshedEntriesAt)
            XCTAssertNotNil(feed.explicitlyModifiedAt)
            XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    func testSameURLPreservesRefreshMetadataWithoutJournaling() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let original = feed.rssUrl
        let modifiedAt = feed.modifiedAt
        try await model.writeFeedAsync { feed in
            guard feed.rssUrl != original else { return false }
            feed.rssUrl = original
            return true
        }.value
        try await model.pasteRSSURL(strings: [original.absoluteString]).value
        await realm.asyncRefresh()
        assertSeededMetadata(feed)
        XCTAssertEqual(feed.modifiedAt, modifiedAt)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testDelayedURLWriterKeepsCapturedStorage() async throws {
        let originalConfiguration = configuration()
        let replacementConfiguration = configuration()
        let original = try await Realm(configuration: originalConfiguration, actor: MainActor.shared)
        let replacement = try await Realm(configuration: replacementConfiguration, actor: MainActor.shared)
        let feed = try installFeed(in: original)
        let other = try installFeed(id: feed.id, in: replacement)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "URL writer registered at admission gate")
        let gate = FeedURLWriteGate()
        let updatedURL = URL(string: "https://other.example/new.xml")!
        let writer = model.writeFeedAsync(beforeWrite: {
            await gate.wait { started.fulfill() }
        }) { feed in
            feed.rssUrl = updatedURL
            return true
        }
        addTeardownBlock {
            writer.cancel()
            await gate.release()
            _ = try? await writer.value
        }
        await fulfillment(of: [started], timeout: 5)
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = replacementConfiguration
        await gate.release()
        try await writer.value
        await original.asyncRefresh()
        await replacement.asyncRefresh()
        XCTAssertEqual(feed.rssUrl, updatedURL)
        XCTAssertNil(feed.lastFetchedETag)
        XCTAssertEqual(other.rssUrl.absoluteString, "https://example.com/feed.xml")
        assertSeededMetadata(other)
        XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testDelayedURLWriterRejectsChangedCategoryAdmission() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let category = try XCTUnwrap(feed.getCategory())
        let original = feed.rssUrl
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "URL writer registered before category change")
        let gate = FeedURLWriteGate()
        let writer = model.writeFeedAsync(beforeWrite: {
            await gate.wait { started.fulfill() }
        }) { feed in
            feed.rssUrl = URL(string: "https://other.example/new.xml")!
            return true
        }
        addTeardownBlock {
            writer.cancel()
            await gate.release()
            _ = try? await writer.value
        }
        await fulfillment(of: [started], timeout: 5)
        try realm.write { category.opmlURL = URL(string: "https://example.com/managed.opml")! }
        await gate.release()
        try await writer.value
        try await model.pasteRSSURL(strings: ["https://other.example/pasted.xml"]).value
        await realm.asyncRefresh()
        XCTAssertEqual(feed.rssUrl, original)
        assertSeededMetadata(feed)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testCancelledURLWriterDoesNotInvalidateMetadataOrCancelPeerEdit() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let original = feed.rssUrl
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Cancellable URL writer registered")
        let gate = FeedURLWriteGate()
        let writer = model.writeFeedAsync(beforeWrite: {
            await gate.wait { started.fulfill() }
        }) { feed in
            feed.rssUrl = URL(string: "https://cancelled.example/feed.xml")!
            return true
        }
        addTeardownBlock {
            writer.cancel()
            await gate.release()
            _ = try? await writer.value
        }
        await fulfillment(of: [started], timeout: 5)
        writer.cancel()
        try await model.writeFeedAsync { feed in
            feed.title = "Peer edit"
            return true
        }.value
        await gate.release()
        do {
            try await writer.value
            XCTFail("Cancelled URL edit succeeded")
        } catch is CancellationError {}
        await realm.asyncRefresh()
        XCTAssertEqual(feed.rssUrl, original)
        XCTAssertEqual(feed.title, "Peer edit")
        assertSeededMetadata(feed)
        XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    private func configuration() -> Realm.Configuration {
        var value = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        value.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&value)
        return value
    }

    private func installFeed(id: UUID = UUID(), in realm: Realm) throws -> Feed {
        let category = FeedCategory()
        let feed = Feed()
        feed.id = id
        feed.categoryID = category.id
        feed.title = "Original"
        feed.rssUrl = URL(string: "https://example.com/feed.xml")!
        feed.lastFetchedETag = "\"old-resource\""
        feed.lastFetchedModifiedAt = Date(timeIntervalSince1970: 100)
        feed.lastRefreshedEntriesAt = Date(timeIntervalSince1970: 200)
        try realm.write { realm.add(category); realm.add(feed) }
        return feed
    }

    private func assertSeededMetadata(
        _ feed: Feed, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(feed.lastFetchedETag, "\"old-resource\"", file: file, line: line)
        XCTAssertEqual(feed.lastFetchedModifiedAt, Date(timeIntervalSince1970: 100), file: file, line: line)
        XCTAssertEqual(feed.lastRefreshedEntriesAt, Date(timeIntervalSince1970: 200), file: file, line: line)
    }
}

private actor FeedURLWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(registered: @Sendable () -> Void) async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            registered()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
