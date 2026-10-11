import XCTest
import BigSyncKit
import RealmSwift
@testable import RealmSwiftGaps
@testable import LakeOfFireContent

final class ReaderContentAuthorityTests: XCTestCase {
    func testSummaryAndMissingFeedBodiesPreserveCapturedBookmarkAndHistory() {
        let fullBody = Data("<article>Captured full article.</article>".utf8)
        let mirrors: [any ReaderContentProtocol] = [Bookmark(), HistoryRecord()]
        for content in mirrors {
            content.content = fullBody
            content.rssContainsFullContent = true
            let incomingBodies: [Data?] = [Data("<p>Updated teaser.</p>".utf8), nil]
            for incomingBody in incomingBodies {
                let incoming = FeedEntry()
                incoming.title = incomingBody == nil ? "Metadata-only refresh" : "Updated title"
                incoming.content = incomingBody
                XCTAssertTrue(applyPayload(FeedEntryPayload(entry: incoming, containsFullContent: false), to: content))
                XCTAssertEqual(content.title, incoming.title)
                XCTAssertEqual(content.content, fullBody)
                XCTAssertTrue(content.rssContainsFullContent)
            }
        }
    }

    func testAuthoritativeFeedBodyPromotesSummaryAndNoBodyNeverClearsCapture() {
        let bookmark = Bookmark()
        let fullBody = Data("<article>Complete article.</article>".utf8)
        XCTAssertTrue(applyFeedBody(fullBody, containsFullContent: true, to: bookmark))
        XCTAssertEqual(bookmark.content, fullBody)
        XCTAssertTrue(bookmark.rssContainsFullContent)
        XCTAssertFalse(applyFeedBody(nil, containsFullContent: true, to: bookmark))
        XCTAssertFalse(applyFeedBody(Data(), containsFullContent: true, to: bookmark))
        XCTAssertFalse(applyFeedBody(fullBody, containsFullContent: true, to: bookmark))
        XCTAssertEqual(bookmark.content, fullBody)
    }

    @MainActor
    func testImmediateHistoryReloadPreservesCapturedFieldsAfterCachedMiss() async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/\(UUID().uuidString)")!
        let missing = try await ReaderContentLoader.lookupStoredContent(url: url)
        XCTAssertNil(missing)
        let first = try await ReaderContentLoader.load(url: url, persist: true, countsAsHistoryVisit: true)
        let key = try XCTUnwrap(first?.compoundKey)
        await realm.asyncRefresh()
        let stored = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
        let fullBody = Data("<article>Captured full article.</article>".utf8)
        try realm.write {
            stored.title = "Captured title"
            stored.content = fullBody
            stored.rssContainsFullContent = true
            stored.isReaderModeByDefault = true
            stored.refreshChangeMetadata(explicitlyModified: true)
        }
        let second = try await ReaderContentLoader.load(url: url, persist: true, countsAsHistoryVisit: true)
        XCTAssertEqual(second?.compoundKey, key)
        XCTAssertEqual(second?.title, "Captured title")
        XCTAssertEqual(second?.content, fullBody)
        XCTAssertEqual(second?.rssContainsFullContent, true)
        XCTAssertEqual(second?.isReaderModeByDefault, true)
        let lookedUp = try await ReaderContentLoader.lookupStoredContent(url: url)
        XCTAssertEqual(lookedUp?.compoundKey, key)
        await realm.asyncRefresh()
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
        await ReaderContentLoader.resetTransientCachesForTesting()
    }

    @MainActor
    private func guardedWriteFixture() async throws -> (Realm, HistoryRecord) {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "GuardedContentWrite-\(UUID().uuidString)",
            objectTypes: [HistoryRecord.self]
        )
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let capturedConfiguration = configuration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: capturedConfiguration)
        }
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let record = HistoryRecord()
        record.url = URL(string: "https://example.com/exact-write")!
        record.title = "Original"
        record.updateCompoundKey()
        try realm.write { realm.add(record) }
        return (realm, record)
    }

    @MainActor
    func testLiveManagedContentWritesInsideOwnedTransaction() async throws {
        let (realm, record) = try await guardedWriteFixture()
        try await record.asyncWrite { targetRealm, content in
            XCTAssertTrue(targetRealm.isInWriteTransaction)
            content.title = "Edited"
            content.refreshChangeMetadata(explicitlyModified: true)
        }
        realm.refresh()
        XCTAssertEqual(record.title, "Edited")
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
    }

    @MainActor
    func testFrozenLiveRowWritesWithoutRefreshingFrozenRealm() async throws {
        let (realm, record) = try await guardedWriteFixture()
        let frozen = record.freeze()
        try await frozen.asyncWrite { targetRealm, content in
            XCTAssertTrue(targetRealm.isInWriteTransaction)
            content.title = "Edited"
            content.refreshChangeMetadata(explicitlyModified: true)
        }
        realm.refresh()
        XCTAssertEqual(record.title, "Edited")
        XCTAssertEqual(frozen.title, "Original")
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
    }

    @MainActor
    func testFrozenDeletedRowDoesNotRunMutation() async throws {
        let (realm, record) = try await guardedWriteFixture()
        let frozen = record.freeze()
        try realm.write { realm.delete(record) }
        XCTAssertFalse(frozen.isInvalidated, "Historical frozen row remains readable.")
        try await frozen.asyncWrite { _, _ in
            XCTFail("A physically deleted row must not run the mutation.")
        }
        realm.refresh()
        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
    }

    @MainActor
    private func assertSuspendedWriteRejectsReplacement(
        frozen: Bool, recreate: Bool, replaceURL: Bool
    ) async throws {
        let (realm, record) = try await guardedWriteFixture()
        let source = frozen ? record.freeze() : record
        let configuration = realm.configuration
        let key = record.compoundKey
        let originalURL = record.url
        let replacementURL = replaceURL ? URL(string: "https://example.com/replacement")! : originalURL
        let replacementBody = Data("<article>Replacement body.</article>".utf8)
        // Open the actual writer before holding its transaction. Its queued
        // begin ticket cannot be admitted until we commit the replacement.
        try await { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try writer.beginWrite()
        }()
        let submitted = expectation(description: "captured source write submitted")
        let task = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await source.asyncWrite { _, content in
                    XCTFail("A replacement must not receive the captured source body")
                    content.content = Data("<article>Stale captured body.</article>".utf8)
                    content.rssContainsFullContent = true
                    content.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
        await fulfillment(of: [submitted], timeout: 3)
        do {
            try await { @RealmBackgroundActor in
                let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                defer { if writer.isInWriteTransaction { writer.cancelWrite() } }
                let original = try XCTUnwrap(writer.object(ofType: HistoryRecord.self, forPrimaryKey: key))
                let replacement: HistoryRecord
                if recreate {
                    writer.delete(original)
                    replacement = HistoryRecord()
                    replacement.compoundKey = key
                    writer.add(replacement)
                } else {
                    replacement = original
                }
                replacement.url = replacementURL
                replacement.title = "Replacement"
                replacement.content = replacementBody
                try writer.commitWrite()
            }()
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        try await task.value
        realm.refresh()
        let replacement = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
        XCTAssertEqual(replacement.url, replacementURL)
        XCTAssertEqual(replacement.title, "Replacement")
        XCTAssertEqual(replacement.content, replacementBody)
        XCTAssertFalse(replacement.rssContainsFullContent)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @MainActor
    func testLiveWriteDoesNotMutateSameKeyRecreatedRow() async throws {
        try await assertSuspendedWriteRejectsReplacement(frozen: false, recreate: true, replaceURL: false)
    }

    @MainActor
    func testFrozenWriteDoesNotMutateSameKeyRecreatedRow() async throws {
        try await assertSuspendedWriteRejectsReplacement(frozen: true, recreate: true, replaceURL: false)
    }

    @MainActor
    func testLiveWriteDoesNotMutateSameKeyRecreatedRowWithDifferentURL() async throws {
        try await assertSuspendedWriteRejectsReplacement(frozen: false, recreate: true, replaceURL: true)
    }

    @MainActor
    func testFrozenWriteDoesNotMutateSameKeyRecreatedRowWithDifferentURL() async throws {
        try await assertSuspendedWriteRejectsReplacement(frozen: true, recreate: true, replaceURL: true)
    }

    @MainActor
    func testLiveWriteDoesNotApplyCapturedBodyAfterURLReplacement() async throws {
        try await assertSuspendedWriteRejectsReplacement(frozen: false, recreate: false, replaceURL: true)
    }

    @MainActor
    func testFrozenWriteDoesNotApplyCapturedBodyAfterURLReplacement() async throws {
        try await assertSuspendedWriteRejectsReplacement(frozen: true, recreate: false, replaceURL: true)
    }

    @MainActor
    func testAlreadyInvalidatedRowDoesNotReadIdentityOrRunMutation() async throws {
        let (realm, record) = try await guardedWriteFixture()
        try realm.write { realm.delete(record) }
        XCTAssertTrue(record.isInvalidated)
        try await record.asyncWrite { _, _ in XCTFail("Invalidated input must be ignored") }
        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
    }

    @MainActor
    func testUnmanagedContentDoesNotOpenDefaultStorage() async throws {
        let (realm, stored) = try await guardedWriteFixture()
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = realm.configuration
        defer { Realm.Configuration.defaultConfiguration = previous }
        let record = HistoryRecord()
        record.url = stored.url
        record.updateCompoundKey()
        XCTAssertEqual(record.compoundKey, stored.compoundKey)
        try await record.asyncWrite { _, content in
            XCTFail("Unmanaged input cannot nominate a same-key row in default storage")
            content.title = "Unexpected default-store write"
            content.refreshChangeMetadata(explicitlyModified: true)
        }
        realm.refresh()
        XCTAssertNil(record.realm)
        XCTAssertEqual(stored.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @MainActor
    func testPreCancelledWriteLeavesOriginalContentUnchanged() async throws {
        let (realm, record) = try await guardedWriteFixture()
        let cancelled = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await record.asyncWrite { _, _ in XCTFail("Cancelled write must not mutate") }
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected error: \(error)")
                return false
            }
        }.value
        XCTAssertTrue(cancelled)
        realm.refresh()
        XCTAssertEqual(record.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }
}
