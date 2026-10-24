import Combine
import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

/// Runs the production cache's actor-owned Realm queries and publication path.
/// The barrier holds only the already-queried snapshot, never a Realm write.
@MainActor
final class BookmarkStatusRefreshTests: XCTestCase {
    func testCommandRefreshReadsReplacementStoreAfterOriginalObservationStarted() async throws {
        let originalConfiguration = makeConfiguration()
        let replacementConfiguration = makeConfiguration()
        let originalRealm = try await Realm(
            configuration: originalConfiguration, actor: MainActor.shared
        )
        let replacementRealm = try await Realm(
            configuration: replacementConfiguration, actor: MainActor.shared
        )
        let originalBookmark = makeBookmark("original-store")
        try originalRealm.write { originalRealm.add(originalBookmark) }
        let replacementSource = makeBookmark("replacement-store")
        let previousConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        defer { ReaderContentLoader.bookmarkRealmConfiguration = previousConfiguration }
        ReaderContentLoader.bookmarkRealmConfiguration = originalConfiguration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: originalConfiguration)
            await RealmBackgroundActor.shared.removeCachedRealm(for: replacementConfiguration)
        }

        let cache = BookmarkStatusCache()
        let originalPublished = expectation(description: "Original store populated the observed cache")
        originalPublished.assertForOverFulfill = false
        let observation = cache.objectWillChange.sink { originalPublished.fulfill() }
        defer { observation.cancel() }
        cache.startIfNeeded()
        await fulfillment(of: [originalPublished], timeout: 5)
        XCTAssertTrue(cache.isBookmarked(originalBookmark))
        XCTAssertFalse(cache.isBookmarked(replacementSource))

        ReaderContentLoader.bookmarkRealmConfiguration = replacementConfiguration
        let saved = try await replacementSource.toggleBookmark(
            realmConfiguration: replacementConfiguration
        )
        XCTAssertTrue(saved)
        // No mutation of the original store is needed to refresh the new one.
        await cache.refreshAfterMutation(configuration: replacementConfiguration)

        XCTAssertTrue(cache.isBookmarked(replacementSource))
        XCTAssertFalse(cache.isBookmarked(originalBookmark))
        await replacementRealm.asyncRefresh()
        let persisted = try XCTUnwrap(replacementRealm.object(
            ofType: Bookmark.self, forPrimaryKey: replacementSource.compoundKey
        ))
        XCTAssertFalse(persisted.isDeleted)
    }

    func testDelayedOlderSnapshotCannotOverwriteNewerCommittedState() async throws {
        let configuration = makeConfiguration()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let bookmark = makeBookmark("older-snapshot")
        try realm.write { realm.add(bookmark) }
        let previousConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        defer { ReaderContentLoader.bookmarkRealmConfiguration = previousConfiguration }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration

        let cache = BookmarkStatusCache()
        let queried = expectation(description: "Older refresh read the live bookmark")
        let barrier = BookmarkStatusSnapshotBarrier(entered: queried)
        let olderRefresh = Task { @MainActor in
            await BookmarkStatusRefreshObservation.$afterSnapshot.withValue({
                await barrier.hold()
            }) {
                await cache.refreshAfterMutation(configuration: configuration)
            }
        }
        addTeardownBlock {
            await barrier.release()
            await olderRefresh.value
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        await fulfillment(of: [queried], timeout: 5)

        try realm.write { bookmark.isDeleted = true }
        await cache.refreshAfterMutation(configuration: configuration)
        XCTAssertFalse(cache.isBookmarked(bookmark))

        await barrier.release()
        await olderRefresh.value
        XCTAssertFalse(cache.isBookmarked(bookmark), "A held saved snapshot must not replace the newer tombstone")

        // The same production path must still admit a subsequent live result.
        try realm.write { bookmark.isDeleted = false }
        await cache.refreshAfterMutation(configuration: configuration)
        XCTAssertTrue(cache.isBookmarked(bookmark))
    }

    func testObsoleteStoreAttemptDoesNotRetireValidPendingRefresh() async throws {
        let obsoleteConfiguration = makeConfiguration()
        let currentConfiguration = makeConfiguration()
        let currentRealm = try await Realm(
            configuration: currentConfiguration, actor: MainActor.shared
        )
        let bookmark = makeBookmark("valid-pending-refresh")
        try currentRealm.write { currentRealm.add(bookmark) }
        let previousConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        defer { ReaderContentLoader.bookmarkRealmConfiguration = previousConfiguration }
        ReaderContentLoader.bookmarkRealmConfiguration = currentConfiguration

        let cache = BookmarkStatusCache()
        let queried = expectation(description: "Current store snapshot is waiting to publish")
        let barrier = BookmarkStatusSnapshotBarrier(entered: queried)
        let currentRefresh = Task { @MainActor in
            await BookmarkStatusRefreshObservation.$afterSnapshot.withValue({
                await barrier.hold()
            }) {
                await cache.refreshAfterMutation(configuration: currentConfiguration)
            }
        }
        addTeardownBlock {
            await barrier.release()
            await currentRefresh.value
            await RealmBackgroundActor.shared.removeCachedRealm(for: obsoleteConfiguration)
            await RealmBackgroundActor.shared.removeCachedRealm(for: currentConfiguration)
        }
        await fulfillment(of: [queried], timeout: 5)

        // The initial observer can request this after its configured store has
        // changed. Rejection must precede advancing the shared refresh generation.
        await cache.refreshAfterMutation(configuration: obsoleteConfiguration)
        XCTAssertFalse(cache.isBookmarked(bookmark))
        await barrier.release()
        await currentRefresh.value

        XCTAssertTrue(cache.isBookmarked(bookmark), "The obsolete request must not invalidate the current snapshot")
    }

    func testStoreReplacementRejectsAnAlreadyQueriedSnapshot() async throws {
        let originalConfiguration = makeConfiguration()
        let replacementConfiguration = makeConfiguration()
        let realm = try await Realm(configuration: originalConfiguration, actor: MainActor.shared)
        let bookmark = makeBookmark("retired-store-snapshot")
        try realm.write { realm.add(bookmark) }
        let previousConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        defer { ReaderContentLoader.bookmarkRealmConfiguration = previousConfiguration }
        ReaderContentLoader.bookmarkRealmConfiguration = originalConfiguration

        let cache = BookmarkStatusCache()
        let queried = expectation(description: "Original store snapshot is waiting to publish")
        let barrier = BookmarkStatusSnapshotBarrier(entered: queried)
        let refresh = Task { @MainActor in
            await BookmarkStatusRefreshObservation.$afterSnapshot.withValue({
                await barrier.hold()
            }) {
                await cache.refreshAfterMutation(configuration: originalConfiguration)
            }
        }
        addTeardownBlock {
            await barrier.release()
            await refresh.value
            await RealmBackgroundActor.shared.removeCachedRealm(for: originalConfiguration)
            await RealmBackgroundActor.shared.removeCachedRealm(for: replacementConfiguration)
        }
        await fulfillment(of: [queried], timeout: 5)

        // No newer refresh exists to change the generation: publication must
        // independently revalidate the store after the actual query suspended.
        ReaderContentLoader.bookmarkRealmConfiguration = replacementConfiguration
        await barrier.release()
        await refresh.value

        XCTAssertFalse(cache.isBookmarked(bookmark))
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "BookmarkStatusRefreshTests.\(UUID().uuidString)"
        )
        configuration.objectTypes = [Bookmark.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private func makeBookmark(_ path: String) -> Bookmark {
        let bookmark = Bookmark()
        bookmark.url = URL(string: "https://example.com/\(path)")!
        bookmark.updateCompoundKey()
        return bookmark
    }
}

private actor BookmarkStatusSnapshotBarrier {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    func hold() async {
        entered.fulfill()
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
