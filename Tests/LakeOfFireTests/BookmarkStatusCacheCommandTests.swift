import BigSyncKit
import Combine
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

final class BookmarkStatusCacheCommandTests: XCTestCase {
    @MainActor
    func testOlderAddCompletionCannotOverwriteObservedRemoval() async throws {
        try await assertOlderCompletionCannotOverwriteRemoval(cancelOlder: false)
    }

    @MainActor
    func testCancelledOlderAddCompletionCannotOverwriteObservedRemoval() async throws {
        try await assertOlderCompletionCannotOverwriteRemoval(cancelOlder: true)
    }

    @MainActor
    func testSourceInvalidatedDuringAnalysisIsNotReadAtCommandCompletion() async throws {
        let (configuration, realm, cache) = try await makeFixture()
        let source = makeSource()
        source.html = "<html><body><p>Saved article</p></body></html>"
        let validIdentity = makeSource(url: source.url)
        try realm.write { realm.add(source) }
        let gate = BookmarkStatusAnalysisGate()
        let reachedAnalysis = expectation(description: "Managed source reached follow-up analysis")
        ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer = { _, _, _, _ in
            await gate.wait(entered: reachedAnalysis)
        }
        cache.startIfNeeded()
        let adding = Task { @MainActor in
            try await cache.toggleBookmarkIfNeeded(
                for: source,
                newValue: true,
                isEnabled: true,
                realmConfiguration: configuration
            )
        }
        addTeardownBlock {
            await gate.release()
            _ = await adding.result
        }
        await fulfillment(of: [reachedAnalysis], timeout: 5)
        await waitForBookmarkStatus(true, source: source, cache: cache)
        await realm.asyncRefresh()
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        let generation = try XCTUnwrap(pendingMutation(for: bookmark, in: realm)?.generation)
        try realm.write { realm.delete(source) }
        XCTAssertTrue(source.isInvalidated)

        await gate.release()
        try await adding.value
        XCTAssertFalse(cache.isBookmarked(source))
        XCTAssertTrue(cache.isBookmarked(validIdentity))
        XCTAssertFalse(bookmark.isDeleted)
        XCTAssertEqual(pendingMutation(for: bookmark, in: realm)?.generation, generation)
    }

    @MainActor
    private func assertOlderCompletionCannotOverwriteRemoval(cancelOlder: Bool) async throws {
        let (configuration, realm, cache) = try await makeFixture()
        let source = makeSource()
        source.html = "<html><body><p>Saved article</p></body></html>"
        let gate = BookmarkStatusAnalysisGate()
        let reachedAnalysis = expectation(description: "Add committed and reached inline analysis")
        ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer = { _, _, _, _ in
            await gate.wait(entered: reachedAnalysis)
        }
        cache.startIfNeeded()

        let adding = Task { @MainActor in
            try await cache.toggleBookmarkIfNeeded(
                for: source,
                newValue: true,
                isEnabled: true,
                realmConfiguration: configuration
            )
        }
        addTeardownBlock {
            await gate.release()
            _ = await adding.result
        }
        await fulfillment(of: [reachedAnalysis], timeout: 5)
        await waitForBookmarkStatus(true, source: source, cache: cache)

        // The original button action is still awaiting follow-up analysis.
        // A later action commits a removal and the real observer publishes it.
        try await cache.toggleBookmarkIfNeeded(
            for: source,
            newValue: false,
            isEnabled: true,
            realmConfiguration: configuration
        )
        await waitForBookmarkStatus(false, source: source, cache: cache)
        await realm.asyncRefresh()
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        XCTAssertTrue(bookmark.isDeleted)
        let deletionGeneration = try XCTUnwrap(pendingMutation(for: bookmark, in: realm)?.generation)

        if cancelOlder { adding.cancel() }
        await gate.release()
        do {
            try await adding.value
        } catch is CancellationError {
            XCTAssertTrue(cancelOlder)
        }
        await realm.asyncRefresh()

        XCTAssertFalse(cache.isBookmarked(source), "An older result cannot replace observed current state")
        XCTAssertTrue(bookmark.isDeleted)
        XCTAssertEqual(pendingMutation(for: bookmark, in: realm)?.generation, deletionGeneration)
    }

    @MainActor
    func testSuccessfulCommandsPublishCanonicalAddAndRemoval() async throws {
        let (configuration, realm, cache) = try await makeFixture()
        let source = makeSource()
        cache.startIfNeeded()

        try await cache.toggleBookmarkIfNeeded(
            for: source,
            newValue: true,
            isEnabled: true,
            realmConfiguration: configuration
        )
        await waitForBookmarkStatus(true, source: source, cache: cache)
        await realm.asyncRefresh()
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        XCTAssertFalse(bookmark.isDeleted)
        let addGeneration = try XCTUnwrap(pendingMutation(for: bookmark, in: realm)?.generation)

        try await cache.toggleBookmarkIfNeeded(
            for: source,
            newValue: false,
            isEnabled: true,
            realmConfiguration: configuration
        )
        await waitForBookmarkStatus(false, source: source, cache: cache)
        await realm.asyncRefresh()
        XCTAssertTrue(bookmark.isDeleted)
        XCTAssertNotEqual(pendingMutation(for: bookmark, in: realm)?.generation, addGeneration)
    }

    @MainActor
    func testUnchangedBindingValuesDoNotIssueMutations() async throws {
        let (configuration, realm, cache) = try await makeFixture()
        let source = makeSource()
        cache.startIfNeeded()

        try await cache.toggleBookmarkIfNeeded(
            for: source,
            newValue: false,
            isEnabled: true,
            realmConfiguration: configuration
        )
        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)

        try await cache.toggleBookmarkIfNeeded(
            for: source,
            newValue: true,
            isEnabled: true,
            realmConfiguration: configuration
        )
        await waitForBookmarkStatus(true, source: source, cache: cache)
        await realm.asyncRefresh()
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        let generation = try XCTUnwrap(pendingMutation(for: bookmark, in: realm)?.generation)

        try await cache.toggleBookmarkIfNeeded(
            for: source,
            newValue: true,
            isEnabled: true,
            realmConfiguration: configuration
        )
        // The binding presents false while disabled, even for a saved source.
        try await cache.toggleBookmarkIfNeeded(
            for: source,
            newValue: false,
            isEnabled: false,
            realmConfiguration: configuration
        )
        await realm.asyncRefresh()
        XCTAssertTrue(cache.isBookmarked(source))
        XCTAssertFalse(bookmark.isDeleted)
        XCTAssertEqual(pendingMutation(for: bookmark, in: realm)?.generation, generation)
    }

    @MainActor
    func testInvalidatedSourceCannotReadChangeOrSubmitCachedStatus() async throws {
        let (configuration, realm, cache) = try await makeFixture()
        let source = makeSource()
        let validIdentity = makeSource(url: source.url)
        try realm.write { realm.add(source) }
        cache.setIsBookmarked(true, for: source)
        try realm.write { realm.delete(source) }
        XCTAssertTrue(source.isInvalidated)

        XCTAssertFalse(cache.isBookmarked(source))
        cache.setIsBookmarked(false, for: source)
        XCTAssertTrue(cache.isBookmarked(validIdentity), "Invalidated accessors cannot alter the live cache entry")
        try await cache.toggleBookmarkIfNeeded(
            for: source,
            newValue: true,
            isEnabled: true,
            realmConfiguration: configuration
        )

        XCTAssertTrue(cache.isBookmarked(validIdentity))
        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @MainActor
    func testFailedCommandPreservesObservedStatusAndJournal() async throws {
        let (configuration, realm, cache) = try await makeFixture()
        let source = makeSource()
        cache.startIfNeeded()
        try await cache.toggleBookmarkIfNeeded(
            for: source,
            newValue: true,
            isEnabled: true,
            realmConfiguration: configuration
        )
        await waitForBookmarkStatus(true, source: source, cache: cache)
        await realm.asyncRefresh()
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        let generation = try XCTUnwrap(pendingMutation(for: bookmark, in: realm)?.generation)

        // Opening a directory as a Realm file fails before any mutation.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkStatusFailure-\(UUID().uuidString).realm", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directoryURL) }
        var unavailableConfiguration = Realm.Configuration(fileURL: directoryURL)
        unavailableConfiguration.objectTypes = configuration.objectTypes
        do {
            try await cache.toggleBookmarkIfNeeded(
                for: source,
                newValue: false,
                isEnabled: true,
                realmConfiguration: unavailableConfiguration
            )
            XCTFail("Opening a directory as a Realm file must fail")
        } catch {
            // The actual command's storage error must propagate to its caller.
        }

        await realm.asyncRefresh()
        XCTAssertTrue(cache.isBookmarked(source))
        XCTAssertFalse(bookmark.isDeleted)
        XCTAssertEqual(pendingMutation(for: bookmark, in: realm)?.generation, generation)
    }

    @MainActor
    private func makeFixture() async throws -> (Realm.Configuration, Realm, BookmarkStatusCache) {
        let originalBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let originalHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let originalAnalysisEnqueuer = ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let fixtureConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = fixtureConfiguration
        ReaderContentLoader.historyRealmConfiguration = fixtureConfiguration
        ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer = nil
        addTeardownBlock {
            await Self.releaseFixtureCache(fixtureConfiguration)
            ReaderContentLoader.bookmarkRealmConfiguration = originalBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = originalHistoryConfiguration
            ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer = originalAnalysisEnqueuer
        }
        let realm = try await Realm(configuration: fixtureConfiguration, actor: MainActor.shared)
        return (fixtureConfiguration, realm, BookmarkStatusCache())
    }

    @RealmBackgroundActor
    private static func releaseFixtureCache(_ configuration: Realm.Configuration) {
        let actor = RealmBackgroundActor.shared
        let keys = actor.cachedRealms.keys.filter {
            actor.cachedRealms[$0]?.configuration.inMemoryIdentifier == configuration.inMemoryIdentifier
        }
        for key in keys {
            guard actor.cachedRealms[key]?.isInWriteTransaction == false else { continue }
            actor.cachedRealms.removeValue(forKey: key)?.invalidate()
        }
    }

    @MainActor
    private func makeSource(url: URL? = nil) -> HistoryRecord {
        let source = HistoryRecord()
        source.url = url ?? URL(string: "https://example.com/bookmark-status/\(UUID().uuidString)")!
        source.title = "Saved article"
        source.updateCompoundKey()
        return source
    }

    @MainActor
    private func waitForBookmarkStatus(
        _ expected: Bool,
        source: HistoryRecord,
        cache: BookmarkStatusCache
    ) async {
        if cache.isBookmarked(source) == expected { return }
        let reached = expectation(description: "Observed bookmark status becomes \(expected)")
        reached.assertForOverFulfill = false
        let observation = cache.objectWillChange.sink {
            // objectWillChange precedes @Published's assignment.
            Task { @MainActor in
                if cache.isBookmarked(source) == expected { reached.fulfill() }
            }
        }
        await fulfillment(of: [reached], timeout: 5)
        XCTAssertEqual(cache.isBookmarked(source), expected)
        withExtendedLifetime(observation) { }
    }

    @MainActor
    private func pendingMutation(for bookmark: Bookmark, in realm: Realm) -> BigSyncPendingMutation? {
        realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: bookmark.objectSchema.className + "." + bookmark.compoundKey
        )
    }
}

private actor BookmarkStatusAnalysisGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(entered: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            guard !released else {
                continuation.resume()
                return
            }
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
