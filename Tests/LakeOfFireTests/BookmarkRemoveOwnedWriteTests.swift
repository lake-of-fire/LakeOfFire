import Foundation
import BigSyncKit
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

@MainActor
final class BookmarkRemoveOwnedWriteTests: XCTestCase {
    func testRemovalJournalsTombstoneAndRepeatedRemovalDoesNotRejournal() async throws {
        let (configuration, realm, source) = try makeRealm()
        let removed = try await source.removeBookmark(realmConfiguration: configuration)
        XCTAssertTrue(removed)
        await realm.asyncRefresh()
        XCTAssertTrue(source.isDeleted)
        let generation = try XCTUnwrap(realm.objects(BigSyncPendingMutation.self).first?.generation)
        let changedAt = source.explicitlyModifiedAt
        let repeated = try await source.removeBookmark(realmConfiguration: configuration)
        XCTAssertFalse(repeated)
        await realm.asyncRefresh()
        XCTAssertEqual(source.explicitlyModifiedAt, changedAt)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).first?.generation, generation)
    }

    func testPreCancelledRemovalLeavesBookmarkAndJournalUntouched() async throws {
        let (configuration, realm, source) = try makeRealm()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await source.removeBookmark(realmConfiguration: configuration)
                return false
            } catch is CancellationError {
                return true
            }
        }
        let cancelled = try await task.value
        XCTAssertTrue(cancelled)
        await realm.asyncRefresh()
        XCTAssertFalse(source.isDeleted)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testInvalidatedSourceIsRejectedBeforeReadingPersistedFields() async throws {
        let (configuration, realm, source) = try makeRealm()
        try realm.write { realm.delete(source) }
        do {
            _ = try await source.removeBookmark(realmConfiguration: configuration)
            XCTFail("An invalidated source must be rejected")
        } catch is CancellationError { }
        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testCancellationAfterCommitSubmissionRetainsRemovalResult() async throws {
        let (configuration, realm, source) = try makeRealm()
        let task = Task { @MainActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await source.removeBookmark(realmConfiguration: configuration)
            }
        }
        let removed = try await task.value
        XCTAssertTrue(removed)
        XCTAssertTrue(task.isCancelled)
        await realm.asyncRefresh()
        XCTAssertTrue(source.isDeleted)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
    }

    func testInvalidatedSourceCannotBeAddedOrToggled() async throws {
        let (configuration, realm, source) = try makeRealm()
        try realm.write { realm.delete(source) }
        do {
            try await source.addBookmark(realmConfiguration: configuration)
            XCTFail("Adding an invalidated source must be rejected before property access")
        } catch is CancellationError { }
        do {
            _ = try await source.toggleBookmark(realmConfiguration: configuration)
            XCTFail("Toggling an invalidated source must be rejected")
        } catch is CancellationError { }
        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    private func makeRealm() throws -> (Realm.Configuration, Realm, Bookmark) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let capturedConfiguration = configuration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: capturedConfiguration)
        }
        let realm = try Realm(configuration: configuration)
        let source = Bookmark()
        source.url = URL(string: "https://example.com/owned-removal")!
        source.updateCompoundKey()
        try realm.write { realm.add(source) }
        return (configuration, realm, source)
    }
}
