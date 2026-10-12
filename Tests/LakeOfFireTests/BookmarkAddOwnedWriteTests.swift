import Foundation
import BigSyncKit
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

@RealmBackgroundActor
final class BookmarkAddOwnedWriteTests: XCTestCase {
    func testPreCancelledAddDoesNotCreateOrJournalBookmark() async throws {
        let (configuration, realm) = try await makeRealm()
        let task = Task { @RealmBackgroundActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await self.add(configuration: configuration)
                return false
            } catch is CancellationError {
                return true
            }
        }
        let cancelled = try await task.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testCancellationAfterCommitSubmissionReturnsDurableBookmark() async throws {
        let (configuration, realm) = try await makeRealm()
        let task = Task { @RealmBackgroundActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await self.add(configuration: configuration)
            }
        }
        let result = try await task.value
        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(result.isDeleted)
        XCTAssertEqual(result.title, "Saved article")
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        XCTAssertNotNil(result.explicitlyModifiedAt)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
    }

    func testAddResurrectsExistingBookmarkAndPreservesCreationIdentity() async throws {
        let (configuration, realm) = try await makeRealm()
        let existing = Bookmark()
        existing.url = URL(string: "https://example.com/owned-add")!
        existing.updateCompoundKey()
        existing.title = "Old title"
        existing.isDeleted = true
        let key = existing.compoundKey
        let createdAt = existing.createdAt
        try realm.write { realm.add(existing) }

        let result = try await add(configuration: configuration)
        XCTAssertEqual(result.compoundKey, key)
        XCTAssertEqual(result.createdAt, createdAt)
        XCTAssertFalse(result.isDeleted)
        XCTAssertEqual(result.title, "Saved article")
        XCTAssertEqual(result.feedEntryCollectionKey, "collection")
        XCTAssertEqual(result.feedEntryCollectionTitle, "Collection title")
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
    }

    private func add(configuration: Realm.Configuration) async throws -> Bookmark {
        try await Bookmark.add(
            url: URL(string: "https://example.com/owned-add")!,
            title: "Saved article",
            isFromClipboard: false,
            rssContainsFullContent: false,
            isReaderModeByDefault: true,
            isReaderModeAvailable: true,
            feedEntryCollectionKey: "collection",
            feedEntryCollectionTitle: "Collection title",
            realmConfiguration: configuration
        )
    }

    private func makeRealm() async throws -> (Realm.Configuration, Realm) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let capturedConfiguration = configuration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: capturedConfiguration)
        }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        return (configuration, realm)
    }
}
