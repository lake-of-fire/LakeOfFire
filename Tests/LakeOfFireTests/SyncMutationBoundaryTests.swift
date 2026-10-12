import BigSyncKit
import Combine
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

func configureLakeOfFireMutationTrackingForTesting(
    _ configuration: inout Realm.Configuration
) {
    let objectTypes = configuration.objectTypes ?? []
    if !objectTypes.contains(where: {
        $0.className() == BigSyncPendingMutation.className()
    }) {
        configuration.objectTypes = objectTypes + [BigSyncPendingMutation.self]
    }
    BigSyncMutationTracking.install(
        configurations: [configuration],
        excludedClassNames: []
    )
}

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

    func testRepeatedFollowingFeedGroupUpdateDoesNotRewriteOrRejournalFeeds() throws {
        let configuration = makeConfiguration()
        let realm = try Realm(configuration: configuration)
        let first = makeFeed(url: "https://example.com/feed.xml")
        let duplicate = makeFeed(
            url: "https://EXAMPLE.com:443/feed.xml#fragment"
        )
        try realm.write {
            realm.add(first)
            realm.add(duplicate)
            Feed.setFollowingStatusForFeedGroup(
                containing: first,
                isFollowed: true,
                in: realm,
                now: Date(timeIntervalSinceReferenceDate: 54_000)
            )
        }
        let firstGeneration = try XCTUnwrap(
            pendingMutation(for: first, in: realm)?.generation
        )
        let duplicateGeneration = try XCTUnwrap(
            pendingMutation(for: duplicate, in: realm)?.generation
        )

        try realm.write {
            Feed.setFollowingStatusForFeedGroup(
                containing: first,
                isFollowed: true,
                in: realm,
                now: Date(timeIntervalSinceReferenceDate: 55_000)
            )
        }

        XCTAssertEqual(
            first.modifiedAt,
            Date(timeIntervalSinceReferenceDate: 54_000)
        )
        XCTAssertEqual(
            duplicate.modifiedAt,
            Date(timeIntervalSinceReferenceDate: 54_000)
        )
        XCTAssertEqual(
            pendingMutation(for: first, in: realm)?.generation,
            firstGeneration
        )
        XCTAssertEqual(
            pendingMutation(for: duplicate, in: realm)?.generation,
            duplicateGeneration
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

    @RealmBackgroundActor
    func testEbookMetadataJournalsPublicationOnlyUpdateOnce() async throws {
        let configuration = makeConfiguration(objectTypes: [ContentFile.self])
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let file = ContentFile()
        file.url = URL(string: "ebook://ebook/load/test.epub")!
        file.updateCompoundKey()
        try await realm.asyncWrite {
            realm.add(file)
        }
        let publicationDate = Date(timeIntervalSinceReferenceDate: 56_000)
        let mutationDate = Date(timeIntervalSinceReferenceDate: 57_000)

        try await EbookFileManager.applyMetadataUpdates(
            images: [],
            titles: [],
            authors: [],
            publicationDates: [(file, publicationDate)],
            physicalMedia: [],
            at: mutationDate
        )

        XCTAssertEqual(file.publicationDate, publicationDate)
        let firstGeneration = try XCTUnwrap(
            pendingMutation(for: file, in: realm)?.generation
        )
        XCTAssertEqual(pendingMutation(for: file, in: realm)?.changedAt, mutationDate)

        try await EbookFileManager.applyMetadataUpdates(
            images: [],
            titles: [],
            authors: [],
            publicationDates: [(file, publicationDate)],
            physicalMedia: [],
            at: mutationDate.addingTimeInterval(60)
        )

        XCTAssertEqual(
            pendingMutation(for: file, in: realm)?.generation,
            firstGeneration
        )
    }

    @RealmBackgroundActor
    func testBulkBookmarkRemovalCreatesDurableTombstones() async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self])
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let first = Bookmark()
        first.url = URL(string: "https://example.com/first")!
        first.updateCompoundKey()
        let second = Bookmark()
        second.url = URL(string: "https://example.com/second")!
        second.updateCompoundKey()
        try await realm.asyncWrite {
            realm.add(first)
            realm.add(second)
        }
        let deletionDate = Date(timeIntervalSinceReferenceDate: 58_000)

        try await Bookmark.removeAll(
            realmConfiguration: configuration,
            at: deletionDate
        )

        XCTAssertTrue(first.isDeleted)
        XCTAssertTrue(second.isDeleted)
        XCTAssertEqual(pendingMutation(for: first, in: realm)?.changedAt, deletionDate)
        XCTAssertEqual(pendingMutation(for: second, in: realm)?.changedAt, deletionDate)
    }

    @RealmBackgroundActor
    func testBookmarkAddCommitsCreationAndResurrectionWithJournalInExplicitStore() async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self])
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/bookmark-writer")!
        let bookmark = try await addBookmark(url: url, title: "First title", configuration: configuration)
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertEqual(bookmark.realm?.configuration.inMemoryIdentifier, configuration.inMemoryIdentifier)
        XCTAssertEqual(bookmark.title, "First title")
        let creationGeneration = try XCTUnwrap(pendingMutation(for: bookmark, in: realm)?.generation)
        XCTAssertEqual(pendingMutation(for: bookmark, in: realm)?.changedAt, bookmark.explicitlyModifiedAt)

        try await realm.asyncWrite {
            bookmark.isDeleted = true
            bookmark.refreshChangeMetadata(explicitlyModified: true)
        }
        let deletionGeneration = try XCTUnwrap(pendingMutation(for: bookmark, in: realm)?.generation)
        let resurrected = try await addBookmark(url: url, title: "Updated title", configuration: configuration)
        XCTAssertEqual(resurrected.compoundKey, bookmark.compoundKey)
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        XCTAssertFalse(resurrected.isDeleted)
        XCTAssertEqual(resurrected.title, "Updated title")
        let updateGeneration = try XCTUnwrap(pendingMutation(for: resurrected, in: realm)?.generation)
        XCTAssertNotEqual(updateGeneration, creationGeneration)
        XCTAssertNotEqual(updateGeneration, deletionGeneration)
        XCTAssertEqual(pendingMutation(for: resurrected, in: realm)?.changedAt, resurrected.explicitlyModifiedAt)
    }

    @RealmBackgroundActor
    func testConcurrentBookmarkAddsCommitIndependentTransactionsForOneIdentity() async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self])
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/concurrent-bookmark")!
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask { @RealmBackgroundActor in
                    let bookmark = try await self.addBookmark(
                        url: url, title: "Title \(index)", configuration: configuration
                    )
                    return bookmark.compoundKey
                }
            }
            for try await key in group {
                XCTAssertEqual(key, Bookmark.makePrimaryKey(url: url, html: nil))
            }
        }
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        XCTAssertNotNil(pendingMutation(for: bookmark, in: realm))
        XCTAssertEqual(pendingMutation(for: bookmark, in: realm)?.changedAt, bookmark.explicitlyModifiedAt)
    }

    @MainActor
    func testOverlappingBookmarkTogglesFromUnsavedStateLeaveJournaledTombstone() async throws {
        try await assertOverlappingBookmarkToggles(initiallySaved: false)
    }

    @MainActor
    func testOverlappingBookmarkTogglesFromSavedStateResurrectOneJournaledBookmark() async throws {
        try await assertOverlappingBookmarkToggles(initiallySaved: true)
    }

    @MainActor
    private func assertOverlappingBookmarkToggles(initiallySaved: Bool) async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        defer { ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration }
        ReaderContentLoader.historyRealmConfiguration = configuration
        let realm = try await Realm.open(configuration: configuration)
        let source = makeHistory(url: "https://example.com/overlapping-toggles")
        let original = Bookmark()
        original.url = source.url
        original.updateCompoundKey()
        if initiallySaved {
            try await realm.asyncWrite {
                realm.add(original)
                original.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        let initialGeneration = realm.objects(BigSyncPendingMutation.self).first?.generation
        let barrier = BookmarkWriterOwnerBarrier()
        let owner = Task { try await barrier.hold(configuration: configuration) }
        defer { barrier.release() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let firstSubmitted = expectation(description: "First toggle queued behind owner")
        let secondSubmitted = expectation(description: "Second toggle queued behind owner")
        firstSubmitted.assertForOverFulfill = false
        secondSubmitted.assertForOverFulfill = false
        let first = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ firstSubmitted.fulfill() }) {
                try await source.toggleBookmark(realmConfiguration: configuration)
            }
        }
        let second = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ secondSubmitted.fulfill() }) {
                try await source.toggleBookmark(realmConfiguration: configuration)
            }
        }
        addTeardownBlock {
            barrier.release()
            _ = await first.result
            _ = await second.result
            _ = await owner.result
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        // Both actual calls submitted their writer tickets before either can
        // decide whether to add or remove. No sleep or scheduling guess.
        await fulfillment(of: [firstSubmitted, secondSubmitted], timeout: 5)
        barrier.release()
        try await owner.value
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(Set([firstResult, secondResult]), Set([false, true]))
        try await realm.asyncRefresh()
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        XCTAssertEqual(bookmark.compoundKey, original.compoundKey)
        XCTAssertEqual(bookmark.isDeleted, !initiallySaved)
        let mutation = try XCTUnwrap(pendingMutation(for: bookmark, in: realm))
        XCTAssertEqual(mutation.changedAt, bookmark.explicitlyModifiedAt)
        XCTAssertNotEqual(mutation.generation, initialGeneration)
    }

    @MainActor
    func testCancelledQueuedBookmarkToggleDoesNotMutateOrJournal() async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let realm = try await Realm.open(configuration: configuration)
        let source = makeHistory(url: "https://example.com/cancelled-toggle")
        let barrier = BookmarkWriterOwnerBarrier()
        let owner = Task { try await barrier.hold(configuration: configuration) }
        defer { barrier.release() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let submitted = expectation(description: "Cancelled toggle submitted")
        let toggle = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await source.toggleBookmark(realmConfiguration: configuration)
            }
        }
        addTeardownBlock {
            barrier.release()
            _ = await toggle.result
            _ = await owner.result
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        await fulfillment(of: [submitted], timeout: 5)
        toggle.cancel()
        do {
            _ = try await toggle.value
            XCTFail("A cancelled waiter must not mutate the bookmark")
        } catch is CancellationError { }
        barrier.release()
        try await owner.value
        try await realm.asyncRefresh()
        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @MainActor
    func testQueuedBookmarkToggleRejectsSourceInvalidatedBeforeAdmission() async throws {
        try await assertQueuedBookmarkToggleRejectsInvalidatedSource(recreateSource: false)
    }

    @MainActor
    func testQueuedBookmarkToggleCannotAdoptRecreatedSourceWithSamePrimaryKey() async throws {
        try await assertQueuedBookmarkToggleRejectsInvalidatedSource(recreateSource: true)
    }

    @MainActor
    func testQueuedBookmarkRemovalRejectsInvalidatedSource() async throws {
        try await assertQueuedBookmarkToggleRejectsInvalidatedSource(recreateSource: false, removingBookmark: true)
    }

    @MainActor
    func testQueuedBookmarkRemovalCannotAdoptRecreatedSourceWithSamePrimaryKey() async throws {
        try await assertQueuedBookmarkToggleRejectsInvalidatedSource(recreateSource: true, removingBookmark: true)
    }

    @MainActor
    private func assertQueuedBookmarkToggleRejectsInvalidatedSource(
        recreateSource: Bool,
        removingBookmark: Bool = false
    ) async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let realm = try await Realm.open(configuration: configuration)
        let source = makeHistory(url: "https://example.com/invalidated-queued-toggle")
        try await realm.asyncWrite {
            realm.add(source)
            if removingBookmark {
                let saved = Bookmark()
                saved.url = source.url
                saved.updateCompoundKey()
                realm.add(saved)
            }
        }
        let sourceKey = source.compoundKey
        let barrier = BookmarkWriterOwnerBarrier()
        let owner = Task {
            try await barrier.hold(configuration: configuration, beforeCommit: { owningRealm in
                if let current = owningRealm.object(ofType: HistoryRecord.self, forPrimaryKey: sourceKey) {
                    owningRealm.delete(current)
                }
                if recreateSource {
                    let replacement = HistoryRecord()
                    replacement.url = URL(string: "https://example.com/invalidated-queued-toggle")!
                    replacement.title = "Replacement row"
                    replacement.updateCompoundKey()
                    XCTAssertEqual(replacement.compoundKey, sourceKey)
                    owningRealm.add(replacement)
                }
            })
        }
        defer { barrier.release() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let submitted = expectation(description: "Bookmark mutation queued before source invalidation")
        let toggle = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                if removingBookmark {
                    return try await source.removeBookmark(realmConfiguration: configuration)
                }
                return try await source.toggleBookmark(realmConfiguration: configuration)
            }
        }
        addTeardownBlock {
            barrier.release()
            _ = await toggle.result
            _ = await owner.result
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        await fulfillment(of: [submitted], timeout: 5)
        barrier.release()
        try await owner.value
        do {
            _ = try await toggle.value
            XCTFail("A source deleted during admission cannot initiate a bookmark mutation")
        } catch is CancellationError { }
        try await realm.asyncRefresh()
        XCTAssertTrue(source.isInvalidated)
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, recreateSource ? 1 : 0)
        XCTAssertEqual(realm.objects(Bookmark.self).count, removingBookmark ? 1 : 0)
        if removingBookmark {
            XCTAssertFalse(try XCTUnwrap(realm.objects(Bookmark.self).first).isDeleted)
        }
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @MainActor
    func testOlderBookmarkAddCompletionAfterRemovalDoesNotReviveOrPromoteHistory() async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let historyConfiguration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        defer {
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = historyConfiguration
        let realm = try await Realm.open(configuration: configuration)
        let historyRealm = try await Realm.open(configuration: historyConfiguration)
        let source = makeHistory(url: "https://example.com/delayed-bookmark-completion")
        let history = makeHistory(url: source.url.absoluteString)
        history.isDemoted = true
        try await historyRealm.asyncWrite { historyRealm.add(history) }
        let barrier = BookmarkWriterOwnerBarrier()
        let owner = Task { try await barrier.hold(configuration: historyConfiguration) }
        defer { barrier.release() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let submitted = expectation(description: "Add submitted bookmark then history writes")
        submitted.expectedFulfillmentCount = 2
        let adding = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await source.toggleBookmark(realmConfiguration: configuration)
            }
        }
        addTeardownBlock {
            barrier.release()
            _ = await adding.result
            _ = await owner.result
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            await RealmBackgroundActor.shared.removeCachedRealm(for: historyConfiguration)
        }
        await fulfillment(of: [submitted], timeout: 5)
        let cache = BookmarkStatusCache()
        cache.startIfNeeded()
        await waitForBookmarkStatus(true, source: source, cache: cache)
        // The first call has committed its add but cannot finish history work.
        let removed = try await source.toggleBookmark(realmConfiguration: configuration)
        XCTAssertFalse(removed)
        try await realm.asyncRefresh()
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        let deletionGeneration = try XCTUnwrap(pendingMutation(for: bookmark, in: realm)?.generation)
        XCTAssertTrue(bookmark.isDeleted)
        await waitForBookmarkStatus(false, source: source, cache: cache)
        barrier.release()
        try await owner.value
        let olderResult = try await adding.value
        XCTAssertTrue(olderResult, "An older transaction result must never be treated as current UI state")
        try await realm.asyncRefresh()
        try await historyRealm.asyncRefresh()
        XCTAssertTrue(bookmark.isDeleted)
        XCTAssertFalse(cache.isBookmarked(source), "Older completion must leave canonical removed status visible")
        XCTAssertEqual(pendingMutation(for: bookmark, in: realm)?.generation, deletionGeneration)
        XCTAssertEqual(history.isDemoted, true)
        XCTAssertNil(pendingMutation(for: history, in: historyRealm))
    }

    @MainActor
    func testQueuedBookmarkHistoryPromotionCannotAdoptRecreatedHistoryRow() async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let historyConfiguration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        defer { ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration }
        ReaderContentLoader.historyRealmConfiguration = historyConfiguration
        let historyRealm = try await Realm.open(configuration: historyConfiguration)
        let source = makeHistory(url: "https://example.com/recreated-bookmark-history")
        let history = makeHistory(url: source.url.absoluteString)
        history.isDemoted = true
        try await historyRealm.asyncWrite { historyRealm.add(history) }
        let historyKey = history.compoundKey
        let historyURL = history.url
        let barrier = BookmarkWriterOwnerBarrier()
        let owner = Task {
            try await barrier.hold(configuration: historyConfiguration, beforeCommit: { owningRealm in
                let current = try XCTUnwrap(owningRealm.object(ofType: HistoryRecord.self, forPrimaryKey: historyKey))
                owningRealm.delete(current)
                let replacement = HistoryRecord()
                replacement.url = historyURL
                replacement.compoundKey = historyKey
                replacement.isDemoted = true
                owningRealm.add(replacement)
            })
        }
        defer { barrier.release() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let submitted = expectation(description: "Bookmark add queued history promotion")
        submitted.expectedFulfillmentCount = 2
        let adding = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await source.addBookmark(realmConfiguration: configuration)
            }
        }
        addTeardownBlock {
            barrier.release()
            _ = await adding.result
            _ = await owner.result
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            await RealmBackgroundActor.shared.removeCachedRealm(for: historyConfiguration)
        }
        await fulfillment(of: [submitted], timeout: 5)
        barrier.release()
        try await owner.value
        try await adding.value
        try await historyRealm.asyncRefresh()
        XCTAssertTrue(history.isInvalidated)
        let replacement = try XCTUnwrap(historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: historyKey))
        XCTAssertEqual(replacement.isDemoted, true)
        XCTAssertNil(pendingMutation(for: replacement, in: historyRealm))
    }

    @MainActor
    private func waitForBookmarkStatus(
        _ expected: Bool,
        source: HistoryRecord,
        cache: BookmarkStatusCache
    ) async {
        if cache.isBookmarked(source) == expected { return }
        let reached = expectation(description: "Canonical bookmark status becomes \(expected)")
        reached.assertForOverFulfill = false
        let cancellable = cache.objectWillChange.sink {
            // objectWillChange fires before @Published assigns its value.
            Task { @MainActor in
                if cache.isBookmarked(source) == expected { reached.fulfill() }
            }
        }
        await fulfillment(of: [reached], timeout: 5)
        XCTAssertEqual(cache.isBookmarked(source), expected)
        withExtendedLifetime(cancellable) { }
    }

    @MainActor
    func testRemoveBookmarkCommitsTombstoneAndRepeatedRemovalDoesNotRejournal() async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self])
        let realm = try await Realm.open(configuration: configuration)
        let bookmark = Bookmark()
        bookmark.url = URL(string: "https://example.com/remove-bookmark")!
        bookmark.updateCompoundKey()
        try await realm.asyncWrite { realm.add(bookmark) }

        let removed = try await bookmark.removeBookmark(realmConfiguration: configuration)
        XCTAssertTrue(removed)
        try await realm.asyncRefresh()
        XCTAssertTrue(bookmark.isDeleted)
        let generation = try XCTUnwrap(pendingMutation(for: bookmark, in: realm)?.generation)
        let timestamp = bookmark.modifiedAt

        let removedAgain = try await bookmark.removeBookmark(realmConfiguration: configuration)
        XCTAssertFalse(removedAgain)
        try await realm.asyncRefresh()
        XCTAssertEqual(bookmark.modifiedAt, timestamp)
        XCTAssertEqual(pendingMutation(for: bookmark, in: realm)?.generation, generation)
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
    }

    @MainActor
    func testAddBookmarkCopiesUnmanagedMediaAndPromotesHistoryInCapturedStores() async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        defer { ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration }
        ReaderContentLoader.historyRealmConfiguration = configuration
        let realm = try await Realm.open(configuration: configuration)
        let source = HistoryRecord()
        source.url = URL(string: "https://example.com/bookmark-media")!
        source.title = "Article"
        source.updateCompoundKey()
        source.voiceAudioURL = URL(string: "https://example.com/audio.mp3")!
        source.voiceAudioURLs.append(source.voiceAudioURL!)
        source.audioSubtitlesURL = URL(string: "https://example.com/subtitles.vtt")!
        let history = HistoryRecord()
        history.url = source.url
        history.compoundKey = "legacy-history-media"
        history.isDemoted = true
        try await realm.asyncWrite { realm.add(history) }

        try await source.addBookmark(realmConfiguration: configuration)
        try await realm.asyncRefresh()
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        XCTAssertEqual(bookmark.voiceAudioURL, source.voiceAudioURL)
        XCTAssertEqual(Array(bookmark.voiceAudioURLs), Array(source.voiceAudioURLs))
        XCTAssertEqual(bookmark.audioSubtitlesURL, source.audioSubtitlesURL)
        XCTAssertEqual(bookmark.audioSubtitlesRoleRawValue, AudioSubtitlesRole.content.rawValue)
        XCTAssertNotNil(pendingMutation(for: bookmark, in: realm))
        XCTAssertEqual(history.isDemoted, false)
        let historyGeneration = try XCTUnwrap(pendingMutation(for: history, in: realm)?.generation)

        try await source.addBookmark(realmConfiguration: configuration)
        try await realm.asyncRefresh()
        XCTAssertEqual(pendingMutation(for: history, in: realm)?.generation, historyGeneration)
    }

    @MainActor
    func testManagedBookmarkConfigurationLinksHistoryInExplicitStoreAfterGlobalReplacement() async throws {
        let configuration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let replacementConfiguration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let realm = try await Realm.open(configuration: configuration)
        let replacementRealm = try await Realm.open(configuration: replacementConfiguration)
        let source = makeHistory(url: "https://example.com/bookmark-link")
        let replacement = makeHistory(url: source.url.absoluteString)
        try await realm.asyncWrite { realm.add(source) }
        try await replacementRealm.asyncWrite { replacementRealm.add(replacement) }
        let previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
        }
        ReaderContentLoader.bookmarkRealmConfiguration = replacementConfiguration
        ReaderContentLoader.historyRealmConfiguration = configuration

        try await source.addBookmark(realmConfiguration: configuration)
        // configureBookmark's association is an independent actor task. Await
        // its observable result instead of assuming scheduling order.
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try await realm.asyncRefresh()
            if source.bookmarkID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        XCTAssertEqual(source.bookmarkID, bookmark.compoundKey)
        XCTAssertNotNil(pendingMutation(for: source, in: realm))
        try await replacementRealm.asyncRefresh()
        XCTAssertNil(replacement.bookmarkID)
        XCTAssertNil(pendingMutation(for: replacement, in: replacementRealm))
        XCTAssertTrue(replacementRealm.objects(Bookmark.self).isEmpty)
    }

    @RealmBackgroundActor
    func testScheduledBookmarkAssociationSkipsDeletedMissingAndRecreatedTargets() async throws {
        for targetDisposition in 0..<3 {
            let configuration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let history = makeHistory(url: "https://example.com/association-target")
            let target = Bookmark()
            target.url = history.url
            target.updateCompoundKey()
            try await realm.asyncWrite {
                realm.add(history)
                realm.add(target)
            }
            let previousModifiedAt = history.modifiedAt
            let previousExplicitlyModifiedAt = history.explicitlyModifiedAt

            let completed = expectation(description: "Owned bookmark association settled")
            // Creation of the actual association task inherits this observer.
            // Invalidate its target before releasing this owned transaction.
            try await realm.asyncWrite {
                BookmarkAssociationObservation.$completed.withValue({ succeeded in
                    XCTAssertTrue(succeeded, "Association must settle without a writer error")
                    completed.fulfill()
                }) {
                    history.configureBookmark(target)
                    if targetDisposition != 0 {
                        let targetURL = target.url
                        let targetKey = target.compoundKey
                        realm.delete(target)
                        if targetDisposition == 2 {
                            let replacement = Bookmark()
                            replacement.url = targetURL
                            replacement.updateCompoundKey()
                            XCTAssertEqual(replacement.compoundKey, targetKey)
                            realm.add(replacement)
                        }
                    } else {
                        target.isDeleted = true
                        target.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertNil(history.bookmarkID)
            XCTAssertEqual(history.modifiedAt, previousModifiedAt)
            XCTAssertEqual(history.explicitlyModifiedAt, previousExplicitlyModifiedAt)
            XCTAssertNil(pendingMutation(for: history, in: realm))
            if targetDisposition == 0 {
                XCTAssertTrue(target.isDeleted)
                XCTAssertNotNil(pendingMutation(for: target, in: realm))
            }
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
    }

    @MainActor
    func testAddBookmarkCapturesHistoryStoreBeforeActualSuspension() async throws {
        let bookmarkConfiguration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let historyConfiguration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let replacementConfiguration = makeConfiguration(objectTypes: [Bookmark.self, HistoryRecord.self])
        let bookmarkRealm = try await Realm.open(configuration: bookmarkConfiguration)
        let historyRealm = try await Realm.open(configuration: historyConfiguration)
        let replacementRealm = try await Realm.open(configuration: replacementConfiguration)
        let source = makeHistory(url: "https://example.com/history-store-interleaving")
        let history = makeHistory(url: source.url.absoluteString)
        history.isDemoted = true
        let replacement = makeHistory(url: source.url.absoluteString)
        replacement.isDemoted = true
        try await historyRealm.asyncWrite { historyRealm.add(history) }
        try await replacementRealm.asyncWrite { replacementRealm.add(replacement) }
        let previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
        }
        ReaderContentLoader.bookmarkRealmConfiguration = bookmarkConfiguration
        ReaderContentLoader.historyRealmConfiguration = historyConfiguration

        let barrier = BookmarkWriterOwnerBarrier()
        let owner = Task {
            try await barrier.hold(configuration: bookmarkConfiguration)
        }
        addTeardownBlock {
            barrier.release()
            _ = await owner.result
        }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let entered = expectation(description: "MainActor enters actual addBookmark")
        let completed = expectation(description: "Actual addBookmark returned")
        var didComplete = false
        let adding = Task { @MainActor in
            // No suspension separates this signal and the same-actor entry.
            // The test's next MainActor turn runs after addBookmark captures its
            // inputs and awaits the background actor. Its writer remains held.
            entered.fulfill()
            defer {
                didComplete = true
                completed.fulfill()
            }
            try await source.addBookmark(realmConfiguration: bookmarkConfiguration)
        }
        addTeardownBlock {
            barrier.release()
            _ = await adding.result
            await RealmBackgroundActor.shared.removeCachedRealm(for: bookmarkConfiguration)
            await RealmBackgroundActor.shared.removeCachedRealm(for: historyConfiguration)
            await RealmBackgroundActor.shared.removeCachedRealm(for: replacementConfiguration)
        }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertFalse(didComplete, "The owner must hold the actual call across global replacement")
        ReaderContentLoader.bookmarkRealmConfiguration = replacementConfiguration
        ReaderContentLoader.historyRealmConfiguration = replacementConfiguration
        barrier.release()
        try await owner.value
        await fulfillment(of: [completed], timeout: 5)
        try await adding.value

        try await bookmarkRealm.asyncRefresh()
        try await historyRealm.asyncRefresh()
        try await replacementRealm.asyncRefresh()
        XCTAssertEqual(bookmarkRealm.objects(Bookmark.self).count, 1)
        XCTAssertFalse(history.isDemoted ?? true)
        XCTAssertNotNil(pendingMutation(for: history, in: historyRealm))
        XCTAssertTrue(replacement.isDemoted ?? false)
        XCTAssertNil(pendingMutation(for: replacement, in: replacementRealm))
        XCTAssertTrue(replacementRealm.objects(Bookmark.self).isEmpty)
    }

    @MainActor
    func testNavigationCommitAwaitsHistoryJournalInOwningConfiguration() async throws {
        let configuration = makeNavigationConfiguration()
        let replacementConfiguration = makeNavigationConfiguration()
        let realm = try await Realm.open(configuration: configuration)
        let replacementRealm = try await Realm.open(configuration: replacementConfiguration)
        let history = makeHistory(url: "https://example.com/navigation-history")
        let replacement = makeHistory(url: history.url.absoluteString)
        try await realm.asyncWrite { realm.add(history) }
        try await replacementRealm.asyncWrite { replacementRealm.add(replacement) }
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        defer { ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration }
        ReaderContentLoader.historyRealmConfiguration = replacementConfiguration
        let model = ReaderViewModel(realmConfiguration: configuration, systemScripts: [])
        let previousVisit = history.lastVisitedAt

        try await model.onNavigationCommitted(content: history, newState: .empty)
        try await realm.asyncRefresh()
        try await replacementRealm.asyncRefresh()
        XCTAssertGreaterThan(history.lastVisitedAt, previousVisit)
        XCTAssertNotNil(pendingMutation(for: history, in: realm))
        XCTAssertEqual(pendingMutation(for: history, in: realm)?.changedAt, history.explicitlyModifiedAt)
        XCTAssertEqual(replacement.lastVisitedAt, Date(timeIntervalSinceReferenceDate: 59_000))
        XCTAssertNil(pendingMutation(for: replacement, in: replacementRealm))
    }

    @MainActor
    func testNavigationCommitDoesNotRewriteDeletedHistoryOrUnmanagedContent() async throws {
        let configuration = makeNavigationConfiguration()
        let realm = try await Realm.open(configuration: configuration)
        let history = makeHistory(url: "https://example.com/deleted-history")
        history.isDeleted = true
        try await realm.asyncWrite { realm.add(history) }
        let model = ReaderViewModel(realmConfiguration: configuration, systemScripts: [])

        try await model.onNavigationCommitted(content: history, newState: .empty)
        let unmanaged = makeHistory(url: "https://example.com/unmanaged-history")
        try await model.onNavigationCommitted(content: unmanaged, newState: .empty)
        try await realm.asyncRefresh()
        XCTAssertEqual(history.lastVisitedAt, Date(timeIntervalSinceReferenceDate: 59_000))
        XCTAssertTrue(history.isDeleted)
        XCTAssertNil(pendingMutation(for: history, in: realm))
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
    }

    @MainActor
    func testCancelledNavigationCommitDoesNotWriteHistory() async throws {
        let configuration = makeNavigationConfiguration()
        let realm = try await Realm.open(configuration: configuration)
        let history = makeHistory(url: "https://example.com/cancelled-history")
        try await realm.asyncWrite { realm.add(history) }
        let model = ReaderViewModel(realmConfiguration: configuration, systemScripts: [])
        // MainActor cannot execute this task until the current synchronous turn
        // yields, so cancellation precedes the writer's first admission check.
        let task = Task { @MainActor in
            try await model.onNavigationCommitted(content: history, newState: .empty)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled navigation must propagate cancellation")
        } catch is CancellationError {
        }
        try await realm.asyncRefresh()
        XCTAssertEqual(history.lastVisitedAt, Date(timeIntervalSinceReferenceDate: 59_000))
        XCTAssertNil(pendingMutation(for: history, in: realm))
    }

    private func makeNavigationConfiguration() -> Realm.Configuration {
        makeConfiguration(objectTypes: [
            Bookmark.self, HistoryRecord.self, LibraryConfiguration.self, UserScript.self, FeedCategory.self,
        ])
    }

    private func makeHistory(url: String) -> HistoryRecord {
        let history = HistoryRecord()
        history.url = URL(string: url)!
        history.updateCompoundKey()
        history.lastVisitedAt = Date(timeIntervalSinceReferenceDate: 59_000)
        return history
    }

    @RealmBackgroundActor
    private func addBookmark(
        url: URL,
        title: String,
        configuration: Realm.Configuration
    ) async throws -> Bookmark {
        try await Bookmark.add(
            url: url,
            title: title,
            isFromClipboard: false,
            rssContainsFullContent: false,
            isReaderModeByDefault: false,
            isReaderModeAvailable: false,
            isReaderModeOfferHidden: false,
            realmConfiguration: configuration
        )
    }

    private func makeConfiguration(
        objectTypes: [Object.Type] = [Feed.self, OPDSCatalog.self]
    ) -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString
        )
        configuration.objectTypes = objectTypes
        configureLakeOfFireMutationTrackingForTesting(&configuration)
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

/// Holds a synchronous transaction on its own queue and Realm. Its transaction
/// never suspends an actor or crosses a task boundary.
private final class BookmarkWriterOwnerBarrier: @unchecked Sendable {
    let entered = XCTestExpectation(description: "External bookmark writer owner entered")
    private let queue = DispatchQueue(label: "LakeOfFireTests.bookmark-external-owner")
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func hold(
        configuration: Realm.Configuration,
        beforeCommit: @escaping @Sendable (Realm) throws -> Void = { _ in }
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            queue.async {
                autoreleasepool {
                    do {
                        let realm = try Realm(configuration: configuration)
                        try realm.write {
                            self.entered.fulfill()
                            self.releaseSemaphore.wait()
                            try beforeCommit(realm)
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}
