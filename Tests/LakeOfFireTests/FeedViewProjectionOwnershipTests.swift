import BigSyncKit
import Combine
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
import LakeOfFireContent
import LakeOfFireReader
@testable import LakeOfFireLibrary

private actor FeedProjectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(entered: XCTestExpectation) async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class FeedViewProjectionOwnershipTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let realm: Realm
        let feed: Feed
        let entry: FeedEntry
        let collection: FeedEntryCollection
        var configuration: Realm.Configuration { realm.configuration }
    }

    private enum ExpectedFailure: Error { case read, fetch }

    private func fixture(
        label: String, id: UUID = UUID(), isFollowed: Bool = false, fileURL: URL? = nil
    ) async throws -> Fixture {
        var configuration = Realm.Configuration()
        if let fileURL { configuration.fileURL = fileURL }
        else { configuration.inMemoryIdentifier = "feed-projection-\(UUID())" }
        configuration.objectTypes = [
            Feed.self, FeedEntry.self, FeedEntryCollection.self,
            Bookmark.self, HistoryRecord.self, ContentFile.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let captured = configuration
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let feed = Feed()
        feed.id = id
        feed.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        feed.title = label
        feed.rssUrl = URL(string: "https://example.com/feed.xml")!
        feed.iconUrl = feed.rssUrl
        feed.isFollowed = isFollowed
        let entry = makeEntry(feedID: id, suffix: label)
        let collection = FeedEntryCollection()
        collection.feedID = id
        collection.scheme = "https://example.com/collections"
        collection.term = label
        collection.title = label
        collection.order = 1
        collection.updateCompoundKey()
        try realm.write {
            realm.add(feed)
            realm.add(entry)
            realm.add(collection)
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        return Fixture(realm: realm, feed: feed, entry: entry, collection: collection)
    }

    private func makeEntry(feedID: UUID, suffix: String) -> FeedEntry {
        let entry = FeedEntry()
        entry.feedID = feedID
        entry.url = URL(string: "https://example.com/items/\(suffix)")!
        entry.title = suffix
        entry.updateCompoundKey()
        return entry
    }

    private func generations(_ realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, $0.generation)
        })
    }

    private func entryIDs(_ model: FeedViewModel) -> Set<String> {
        Set((model.entries ?? []).map(\.compoundKey))
    }

    private func assertRetired(_ model: FeedViewModel) {
        XCTAssertNil(model.entries)
        XCTAssertNil(model.collections)
        XCTAssertFalse(model.isFeedGroupFollowed)
    }

    func testInitialAndReloadedProjectionStayWithOriginalStoreAndLiveValues() async throws {
        let original = try await fixture(label: "A")
        let replacement = try await fixture(label: "B", id: original.feed.id, isFollowed: true)
        let saved = ReaderContentLoader.feedEntryRealmConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = replacement.configuration
        defer { ReaderContentLoader.feedEntryRealmConfiguration = saved }
        let originalJournal = generations(original.realm)
        let replacementJournal = generations(replacement.realm)
        let model = FeedViewModel(feed: original.feed, observesRealm: false)
        XCTAssertEqual(model.collections?.map(\.compoundKey), [original.collection.compoundKey])
        XCTAssertFalse(model.isFeedGroupFollowed)
        await model.refreshProjection()
        XCTAssertEqual(entryIDs(model), [original.entry.compoundKey])
        XCTAssertEqual(model.collections?.map(\.compoundKey), [original.collection.compoundKey])
        XCTAssertFalse(model.isFeedGroupFollowed)
        XCTAssertFalse(try XCTUnwrap(model.entries?.first).isFrozen)
        XCTAssertFalse(try XCTUnwrap(model.collections?.first).isFrozen)
        try original.realm.write { original.entry.title = "Live update" }
        XCTAssertEqual(model.entries?.first?.title, "Live update")
        XCTAssertEqual(generations(original.realm), originalJournal)
        XCTAssertEqual(generations(replacement.realm), replacementJournal)
    }

    func testCanonicalAliasesArchiveFiltersAndCollectionOrderArePreserved() async throws {
        let fixture = try await fixture(label: "A")
        let alias = Feed()
        alias.rssUrl = URL(string: "https://EXAMPLE.com:443/feed.xml#alias")!
        alias.iconUrl = alias.rssUrl
        let archived = Feed()
        archived.rssUrl = fixture.feed.rssUrl
        archived.iconUrl = archived.rssUrl
        archived.isArchived = true
        archived.isFollowed = true
        let aliasEntry = makeEntry(feedID: alias.id, suffix: "alias")
        let archivedEntry = makeEntry(feedID: archived.id, suffix: "archived")
        let firstCollection = FeedEntryCollection()
        firstCollection.feedID = alias.id
        firstCollection.scheme = "https://example.com/collections"
        firstCollection.term = "first"
        firstCollection.title = "First"
        firstCollection.order = 20
        firstCollection.updateCompoundKey()
        try fixture.realm.write {
            fixture.realm.add([alias, archived])
            fixture.realm.add([aliasEntry, archivedEntry])
            fixture.realm.add(firstCollection)
        }
        let model = FeedViewModel(feed: fixture.feed, observesRealm: false)
        await model.refreshProjection()
        XCTAssertEqual(entryIDs(model), [fixture.entry.compoundKey, aliasEntry.compoundKey])
        XCTAssertEqual(model.collections?.map(\.compoundKey), [firstCollection.compoundKey, fixture.collection.compoundKey])
        // Existing status considers all non-deleted canonical peers; content
        // groups exclude archived peers. Preserve those distinct query rules.
        XCTAssertTrue(model.isFeedGroupFollowed)
    }

    func testGlobalReplacementDuringHeldReadCannotRedirectAnyProjection() async throws {
        let original = try await fixture(label: "A")
        let replacement = try await fixture(label: "B", id: original.feed.id, isFollowed: true)
        let gate = FeedProjectionGate()
        let entered = expectation(description: "Original reload is pending")
        var holdsFirstRead = true
        let model = FeedViewModel(feed: original.feed, observesRealm: false, beforeRead: { _ in
            if holdsFirstRead {
                holdsFirstRead = false
                await gate.wait(entered: entered)
            }
        })
        let read = Task { await model.refreshProjection() }
        addTeardownBlock { await gate.release(); await read.value }
        await fulfillment(of: [entered], timeout: 5)
        let saved = ReaderContentLoader.feedEntryRealmConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = replacement.configuration
        defer { ReaderContentLoader.feedEntryRealmConfiguration = saved }
        await gate.release()
        await read.value
        XCTAssertEqual(entryIDs(model), [original.entry.compoundKey])
        XCTAssertEqual(model.collections?.map(\.compoundKey), [original.collection.compoundKey])
        XCTAssertFalse(model.isFeedGroupFollowed)
    }

    func testDelayedRealObserversRegisterAndReloadOnlyOriginalStore() async throws {
        let original = try await fixture(label: "A")
        let replacement = try await fixture(label: "B", id: original.feed.id, isFollowed: true)
        let gate = FeedProjectionGate()
        let entered = expectation(description: "Observer setup is pending")
        let initialEntries = expectation(description: "Entries observer completed initial delivery")
        let initialCollections = expectation(description: "Collections observer completed initial delivery")
        let initialFeeds = expectation(description: "Feeds observer completed initial delivery")
        for item in [initialEntries, initialCollections, initialFeeds] { item.assertForOverFulfill = false }
        let model = FeedViewModel(
            feed: original.feed, observesRealm: true,
            beforeObserverOpen: { await gate.wait(entered: entered) },
            observerDidRefresh: { kind in
                switch kind {
                case .entries: initialEntries.fulfill()
                case .collections: initialCollections.fulfill()
                case .followedStatus: initialFeeds.fulfill()
                }
            }
        )
        addTeardownBlock { await gate.release() }
        await fulfillment(of: [entered], timeout: 5)
        let saved = ReaderContentLoader.feedEntryRealmConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = replacement.configuration
        defer { ReaderContentLoader.feedEntryRealmConfiguration = saved }
        await gate.release()
        await fulfillment(of: [initialEntries, initialCollections, initialFeeds], timeout: 5)
        XCTAssertEqual(entryIDs(model), [original.entry.compoundKey])
        XCTAssertFalse(model.isFeedGroupFollowed)

        let newEntry = makeEntry(feedID: original.feed.id, suffix: "after-observation")
        let newKey = newEntry.compoundKey
        let delivered = expectation(description: "Real A notification publishes its new entry")
        delivered.assertForOverFulfill = false
        let token = model.$entries.sink { values in
            if values?.contains(where: { !$0.isInvalidated && $0.compoundKey == newKey }) == true {
                delivered.fulfill()
            }
        }
        defer { token.cancel() }
        try original.realm.write { original.realm.add(newEntry) }
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(entryIDs(model), [original.entry.compoundKey, newKey])
        XCTAssertFalse(model.isFeedGroupFollowed)
        XCTAssertEqual(replacement.realm.objects(FeedEntry.self).count, 1)
    }

    func testOlderReadCannotReplaceNewerMembershipAfterPublicationSuspends() async throws {
        let fixture = try await fixture(label: "A")
        let gate = FeedProjectionGate()
        let entered = expectation(description: "Old entry membership is captured")
        var hold = true
        let model = FeedViewModel(feed: fixture.feed, observesRealm: false, beforePublication: { kind in
            if kind == .entries, hold {
                hold = false
                await gate.wait(entered: entered)
            }
        })
        let oldRead = Task { await model.refreshProjection() }
        addTeardownBlock { await gate.release(); await oldRead.value }
        await fulfillment(of: [entered], timeout: 5)
        let newest = makeEntry(feedID: fixture.feed.id, suffix: "newest")
        try fixture.realm.write { fixture.realm.add(newest) }
        await model.refreshProjection()
        XCTAssertEqual(entryIDs(model), [fixture.entry.compoundKey, newest.compoundKey])
        await gate.release()
        await oldRead.value
        XCTAssertEqual(entryIDs(model), [fixture.entry.compoundKey, newest.compoundKey])
    }

    func testPhysicalSourceReplacementAfterReadRetiresOldModelAndNewModelCanLoad() async throws {
        let fixture = try await fixture(label: "A")
        let id = fixture.feed.id
        let createdAt = fixture.feed.createdAt
        let url = fixture.feed.rssUrl
        let gate = FeedProjectionGate()
        let entered = expectation(description: "Old physical source projection is ready")
        var hold = true
        let model = FeedViewModel(feed: fixture.feed, observesRealm: false, beforePublication: { kind in
            if kind == .entries, hold { hold = false; await gate.wait(entered: entered) }
        })
        let read = Task { await model.refreshProjection() }
        addTeardownBlock { await gate.release(); await read.value }
        await fulfillment(of: [entered], timeout: 5)
        let replacement = Feed()
        replacement.id = id
        replacement.createdAt = createdAt
        replacement.rssUrl = url
        replacement.iconUrl = url
        replacement.isFollowed = true
        let replacementEntry = makeEntry(feedID: id, suffix: "physical-successor")
        try fixture.realm.write {
            fixture.realm.delete(fixture.feed)
            fixture.realm.delete(fixture.entry)
            fixture.realm.add(replacement)
            fixture.realm.add(replacementEntry)
        }
        await gate.release()
        await read.value
        assertRetired(model)
        // A later callback must reject the invalidated original before making
        // another reference, even though its primary-key successor now exists.
        await model.refreshProjection()
        assertRetired(model)
        let successor = FeedViewModel(feed: replacement, observesRealm: false)
        await successor.refreshProjection()
        XCTAssertEqual(entryIDs(successor), [replacementEntry.compoundKey])
        XCTAssertTrue(successor.isFeedGroupFollowed)
    }

    func testRetargetCreationAndTombstoneChangesRejectPendingPublication() async throws {
        for change in ["url", "createdAt", "deleted"] {
            let fixture = try await fixture(label: change)
            let gate = FeedProjectionGate()
            let entered = expectation(description: "Projection awaits owner validation")
            var hold = true
            let model = FeedViewModel(feed: fixture.feed, observesRealm: false, beforePublication: { kind in
                if kind == .entries, hold { hold = false; await gate.wait(entered: entered) }
            })
            let read = Task { await model.refreshProjection() }
            addTeardownBlock { await gate.release(); await read.value }
            await fulfillment(of: [entered], timeout: 5)
            try fixture.realm.write {
                switch change {
                case "url": fixture.feed.rssUrl = URL(string: "https://example.com/retarget.xml")!
                case "createdAt": fixture.feed.createdAt = fixture.feed.createdAt.addingTimeInterval(1)
                default: fixture.feed.isDeleted = true
                }
            }
            await gate.release()
            await read.value
            assertRetired(model)
        }
    }

    func testTitleOnlyChangePreservesCurrentLiveProjection() async throws {
        let fixture = try await fixture(label: "A")
        let gate = FeedProjectionGate()
        let entered = expectation(description: "Projection before title update")
        var hold = true
        let model = FeedViewModel(feed: fixture.feed, observesRealm: false, beforePublication: { kind in
            if kind == .entries, hold { hold = false; await gate.wait(entered: entered) }
        })
        let read = Task { await model.refreshProjection() }
        addTeardownBlock { await gate.release(); await read.value }
        await fulfillment(of: [entered], timeout: 5)
        try fixture.realm.write {
            fixture.feed.title = "Current feed title"
            fixture.entry.title = "Current entry title"
        }
        await gate.release()
        await read.value
        XCTAssertEqual(entryIDs(model), [fixture.entry.compoundKey])
        XCTAssertEqual(model.entries?.first?.title, "Current entry title")
    }

    func testCancelledReadCannotClearSuccessfulSuccessorAndFreshReadRetries() async throws {
        let fixture = try await fixture(label: "A")
        let gate = FeedProjectionGate()
        let entered = expectation(description: "Read waits at publication")
        var hold = true
        let model = FeedViewModel(feed: fixture.feed, observesRealm: false, beforePublication: { kind in
            if kind == .entries, hold { hold = false; await gate.wait(entered: entered) }
        })
        let oldRead = Task { await model.refreshProjection() }
        addTeardownBlock { oldRead.cancel(); await gate.release(); await oldRead.value }
        await fulfillment(of: [entered], timeout: 5)
        oldRead.cancel()
        let newest = makeEntry(feedID: fixture.feed.id, suffix: "after-cancel")
        try fixture.realm.write { fixture.realm.add(newest) }
        await model.refreshProjection()
        await gate.release()
        await oldRead.value
        XCTAssertEqual(entryIDs(model), [fixture.entry.compoundKey, newest.compoundKey])
        await model.refreshProjection()
        XCTAssertEqual(entryIDs(model), [fixture.entry.compoundKey, newest.compoundKey])
    }

    func testCurrentReadFailureKeepsVisibleProjectionAndRetryLoadsNewMembership() async throws {
        let fixture = try await fixture(label: "A")
        var fails = false
        let model = FeedViewModel(feed: fixture.feed, observesRealm: false, beforeRead: { _ in
            if fails { throw ExpectedFailure.read }
        })
        await model.refreshProjection()
        let newest = makeEntry(feedID: fixture.feed.id, suffix: "retry")
        try fixture.realm.write { fixture.realm.add(newest) }
        fails = true
        await model.refreshProjection()
        XCTAssertEqual(entryIDs(model), [fixture.entry.compoundKey])
        fails = false
        await model.refreshProjection()
        XCTAssertEqual(entryIDs(model), [fixture.entry.compoundKey, newest.compoundKey])
    }

    func testProjectionWaitsOutsideMainActorPeerWriteAndKeepsItsRollback() async throws {
        let fixture = try await fixture(label: "A")
        let model = FeedViewModel(feed: fixture.feed, observesRealm: false)
        let gate = FeedProjectionGate()
        let entered = expectation(description: "MainActor peer owns its write")
        let peer = Task { @MainActor in
            try fixture.realm.beginWrite()
            fixture.feed.title = "Provisional title"
            await gate.wait(entered: entered)
            let retained = fixture.realm.isInWriteTransaction
            if retained { fixture.realm.cancelWrite() }
            return retained
        }
        addTeardownBlock { await gate.release(); _ = await peer.result }
        await fulfillment(of: [entered], timeout: 5)
        let submitted = expectation(description: "Projection queues its own barrier")
        submitted.assertForOverFulfill = false
        let read = Task {
            await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                await model.refreshProjection()
            }
        }
        addTeardownBlock { read.cancel(); await gate.release(); await read.value }
        await fulfillment(of: [submitted], timeout: 5)
        XCTAssertTrue(fixture.realm.isInWriteTransaction)
        await gate.release()
        let retained = try await peer.value
        XCTAssertTrue(retained)
        await read.value
        XCTAssertEqual(fixture.feed.title, "A")
        XCTAssertEqual(entryIDs(model), [fixture.entry.compoundKey])
    }

    func testFetchWrapperUsesOriginalStoreAndPreservesRecentAndForcedPolicy() async throws {
        let original = try await fixture(label: "A")
        let replacement = try await fixture(label: "B", id: original.feed.id)
        try original.realm.write { original.feed.lastRefreshedEntriesAt = Date() }
        let expectedStore = original.configuration.inMemoryIdentifier
        var calls = 0
        let model = FeedViewModel(feed: original.feed, observesRealm: false, fetchFeed: { feed, configuration in
            calls += 1
            XCTAssertEqual(configuration.inMemoryIdentifier, expectedStore)
            XCTAssertEqual(feed.realm?.configuration.inMemoryIdentifier, expectedStore)
        })
        let saved = ReaderContentLoader.feedEntryRealmConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = replacement.configuration
        defer { ReaderContentLoader.feedEntryRealmConfiguration = saved }
        try await model.fetchIfNeeded(feed: original.feed.freeze(), force: false)
        XCTAssertEqual(calls, 0)
        try await model.fetchIfNeeded(feed: original.feed.freeze(), force: true)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(entryIDs(model), [original.entry.compoundKey])
        do {
            try await model.fetchIfNeeded(feed: replacement.feed.freeze(), force: true)
            XCTFail("Another store's presented feed must be rejected")
        } catch is CancellationError { }
        XCTAssertEqual(calls, 1)
    }

    func testFetchCompletionRetiresDeletedSourceWithoutReadingInvalidatedFields() async throws {
        for fails in [false, true] {
            let fixture = try await fixture(label: fails ? "failure" : "success")
            let gate = FeedProjectionGate()
            let entered = expectation(description: "Actual fetch wrapper awaits producer")
            let model = FeedViewModel(feed: fixture.feed, observesRealm: false, fetchFeed: { _, _ in
                await gate.wait(entered: entered)
                if fails { throw ExpectedFailure.fetch }
            })
            let presented = fixture.feed.freeze()
            let fetch = Task { try await model.fetchIfNeeded(feed: presented, force: true) }
            addTeardownBlock { fetch.cancel(); await gate.release(); _ = await fetch.result }
            await fulfillment(of: [entered], timeout: 5)
            try fixture.realm.write { fixture.realm.delete(fixture.feed) }
            await gate.release()
            do {
                try await fetch.value
                XCTFail("Retired or failed fetch must not publish success")
            } catch ExpectedFailure.fetch {
                XCTAssertTrue(fails)
            } catch is CancellationError {
                XCTAssertFalse(fails)
            }
            XCTAssertNil(model.entries)
        }
    }

    func testFetchCancellationAfterIgnoringProducerCannotPublishReload() async throws {
        let fixture = try await fixture(label: "A")
        let gate = FeedProjectionGate()
        let entered = expectation(description: "Fetch producer ignores cancellation")
        let model = FeedViewModel(feed: fixture.feed, observesRealm: false, fetchFeed: { _, _ in
            await gate.wait(entered: entered)
        })
        let fetch = Task { try await model.fetchIfNeeded(feed: fixture.feed.freeze(), force: true) }
        addTeardownBlock { fetch.cancel(); await gate.release(); _ = await fetch.result }
        await fulfillment(of: [entered], timeout: 5)
        fetch.cancel()
        await gate.release()
        do {
            try await fetch.value
            XCTFail("Cancelled fetch completion must not reload")
        } catch is CancellationError { }
        XCTAssertNil(model.entries)
    }

    func testPhysicalStorageReplacementBeforeOpenAndAfterReadRetiresProjection() async throws {
        for replaceAfterRead in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feed-projection-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let originalURL = directory.appendingPathComponent("original.realm")
            let replacementURL = directory.appendingPathComponent("replacement.realm")
            let retiredURL = directory.appendingPathComponent("retired.realm")
            let original = try await fixture(label: "A", fileURL: originalURL)
            let replacement = try await fixture(
                label: "B", id: original.feed.id, isFollowed: true, fileURL: replacementURL
            )
            let originalJournal = generations(original.realm)
            let replacementJournal = generations(replacement.realm)
            let gate = FeedProjectionGate()
            let entered = expectation(description: "Actual projection is at storage replacement boundary")
            var hold = true
            let model = FeedViewModel(
                feed: original.feed, observesRealm: false,
                beforeRead: { _ in
                    if !replaceAfterRead, hold {
                        hold = false
                        await gate.wait(entered: entered)
                    }
                },
                beforePublication: { kind in
                    if replaceAfterRead, kind == .entries, hold {
                        hold = false
                        await gate.wait(entered: entered)
                    }
                }
            )
            let read = Task { await model.refreshProjection() }
            addTeardownBlock { read.cancel(); await gate.release(); await read.value }
            await fulfillment(of: [entered], timeout: 5)
            try FileManager.default.moveItem(at: originalURL, to: retiredURL)
            do { try FileManager.default.moveItem(at: replacementURL, to: originalURL) }
            catch {
                try? FileManager.default.moveItem(at: retiredURL, to: originalURL)
                throw error
            }
            defer {
                XCTAssertNoThrow(try FileManager.default.moveItem(at: originalURL, to: replacementURL))
                XCTAssertNoThrow(try FileManager.default.moveItem(at: retiredURL, to: originalURL))
            }
            await gate.release()
            await read.value
            assertRetired(model)
            XCTAssertEqual(generations(original.realm), originalJournal)
            XCTAssertEqual(generations(replacement.realm), replacementJournal)
        }
    }

    func testUnmanagedAndInvalidatedInitialSourcesDoNotReadPersistedGettersOrStartWork() async throws {
        let unmanaged = Feed()
        let unmanagedModel = FeedViewModel(feed: unmanaged, observesRealm: false)
        await unmanagedModel.refreshProjection()
        assertRetired(unmanagedModel)
        do {
            try await unmanagedModel.fetchIfNeeded(feed: unmanaged, force: true)
            XCTFail("Unmanaged initial source must be rejected")
        } catch is CancellationError { }

        let fixture = try await fixture(label: "A")
        try fixture.realm.write { fixture.realm.delete(fixture.feed) }
        let model = FeedViewModel(feed: fixture.feed, observesRealm: false)
        await model.refreshProjection()
        assertRetired(model)
        do {
            try await model.fetchIfNeeded(feed: fixture.feed, force: true)
            XCTFail("Invalidated initial source must be rejected")
        } catch is CancellationError { }
    }
}
