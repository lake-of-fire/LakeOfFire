import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import SwiftSoup
import XCTest
@testable import LakeOfFireContent

private actor ContentImportWriteGate {
    nonisolated let entered = XCTestExpectation(description: "Original writer is held")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func hold() async {
        entered.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// A controlled value for the production admission predicate. Account locking
/// remains the actual caller's AccountSessionAccess responsibility.
private final class ContentImportPermission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true

    func permitsCommit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }

    func revoke() {
        lock.lock()
        allowed = false
        lock.unlock()
    }
}

/// This observes actual provisional Realm rows/links at the production
/// permission boundary. It does not implement an import or account state machine.
private final class ContentImportWriteProbe: @unchecked Sendable {
    enum Mode { case rejectNewHistory, cancelNewHistory, rejectBookmarkLink }
    let realm: Realm
    let mode: Mode
    private(set) var observedMutation = false

    init(realm: Realm, mode: Mode) {
        self.realm = realm
        self.mode = mode
    }

    // The production API invokes this synchronously on RealmBackgroundActor.
    func permitsCommit() -> Bool {
        guard realm.isInWriteTransaction else { return true }
        switch mode {
        case .rejectNewHistory:
            observedMutation = observedMutation || !realm.objects(HistoryRecord.self).isEmpty
            return !observedMutation
        case .cancelNewHistory:
            if !realm.objects(HistoryRecord.self).isEmpty {
                observedMutation = true
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return true
        case .rejectBookmarkLink:
            observedMutation = observedMutation
                || realm.objects(HistoryRecord.self).contains { $0.bookmarkID != nil }
            return !observedMutation
        }
    }
}

final class ReaderContentImportTests: XCTestCase {
    private enum FixtureError: Error { case afterCommit }

    @RealmBackgroundActor
    func testFreshImportReturnsOneJournaledSnippetWithConsistentMetadata() async throws {
        let fixture = try await makeFixture()
        let html = "<p>日本語の文章です。</p>"
        let result = try await ReaderContentLoader.importContent(
            .html(html, fromClipboard: true), storage: fixture.storage,
            permitsCommit: { true }, commitIfCurrent: Self.commitWithoutAccount
        )
        let reference = try XCTUnwrap(result).reference
        let record = try XCTUnwrap(fixture.history.object(
            ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
        ))
        XCTAssertEqual(result?.objectID, record.id)

        XCTAssertEqual(fixture.history.objects(HistoryRecord.self).count, 1)
        XCTAssertTrue(record.url.isSnippetURL)
        XCTAssertEqual(reference.contentURL, record.url)
        XCTAssertEqual(reference.contentCreatedAt, record.createdAt)
        XCTAssertEqual(reference.realmConfiguration.inMemoryIdentifier, fixture.historyConfiguration.inMemoryIdentifier)
        XCTAssertTrue(record.isFromClipboard)
        XCTAssertTrue(record.rssContainsFullContent)
        XCTAssertTrue(record.isReaderModeByDefault)
        XCTAssertEqual(record.isDemoted, false)
        XCTAssertEqual(record.title, ReaderContentLoader.generatedSnippetTitle(fromSourceHTML: record.html ?? ""))
        XCTAssertTrue(record.isTitlePrefixOfContent)
        XCTAssertTrue(record.html?.contains("日本語の文章です。") == true)
        XCTAssertEqual(record.createdAt, record.lastVisitedAt)
        XCTAssertEqual(record.createdAt, record.publicationDate)
        XCTAssertEqual(record.createdAt, record.modifiedAt)
        XCTAssertEqual(record.createdAt, record.explicitlyModifiedAt)
        let journal = try XCTUnwrap(fixture.history.objects(BigSyncPendingMutation.self).first)
        XCTAssertEqual(fixture.history.objects(BigSyncPendingMutation.self).count, 1)
        XCTAssertEqual(journal.recordName, HistoryRecord.className() + "." + record.compoundKey)
        XCTAssertEqual(journal.changedAt, record.explicitlyModifiedAt)
        XCTAssertFalse(fixture.history.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testDurableResultCarriesPhysicalRowIdentityAcrossActorsAndRecreation() async throws {
        let fixture = try await makeFixture()
        let saved = try await ReaderContentLoader.importContent(
            .html("<p>Original physical row</p>", fromClipboard: false),
            storage: fixture.storage, permitsCommit: { true },
            commitIfCurrent: Self.commitWithoutAccount
        )
        let result = try XCTUnwrap(saved)
        let reference = result.reference
        let mainActorID = try await { @MainActor () throws -> UInt64 in
            let realm = try await Realm(
                configuration: reference.realmConfiguration, actor: MainActor.shared
            )
            let row = try XCTUnwrap(realm.object(
                ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
            ))
            return row.id
        }()
        XCTAssertEqual(mainActorID, result.objectID)

        let original = try XCTUnwrap(fixture.history.object(
            ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
        ))
        let successor = HistoryRecord()
        successor.compoundKey = reference.contentKey
        successor.createdAt = reference.contentCreatedAt
        successor.url = reference.contentURL
        try fixture.history.write {
            fixture.history.delete(original)
            fixture.history.add(successor)
            successor.refreshChangeMetadata(explicitlyModified: true)
        }
        XCTAssertTrue(original.isInvalidated)
        XCTAssertEqual(successor.compoundKey, reference.contentKey)
        XCTAssertEqual(successor.createdAt, reference.contentCreatedAt)
        XCTAssertEqual(successor.url, reference.contentURL)
        XCTAssertNotEqual(successor.id, result.objectID)
        XCTAssertEqual(result.objectID, mainActorID)
    }

    @RealmBackgroundActor
    func testInitialAndFinalPermissionRejectionLeaveNoRowsOrJournal() async throws {
        let fixture = try await makeFixture()
        for payload in [
            ReaderContentLoader.ImportPayload.html("<p>Rejected snippet</p>", fromClipboard: true),
            .url(URL(string: "https://example.com/rejected-import")!),
        ] {
            do {
                _ = try await ReaderContentLoader.importContent(
                    payload, storage: fixture.storage, permitsCommit: { false },
                    commitIfCurrent: Self.commitWithoutAccount
                )
                XCTFail("An expired action must not begin an import")
            } catch is CancellationError { }

            let probe = ContentImportWriteProbe(realm: fixture.history, mode: .rejectNewHistory)
            do {
                _ = try await ReaderContentLoader.importContent(
                    payload, storage: fixture.storage, permitsCommit: { probe.permitsCommit() },
                    commitIfCurrent: Self.commitWithoutAccount
                )
                XCTFail("Final withdrawal must roll back the actual provisional row and journal")
            } catch is CancellationError { }
            XCTAssertTrue(probe.observedMutation)
            XCTAssertTrue(fixture.history.objects(HistoryRecord.self).isEmpty)
            XCTAssertTrue(fixture.history.objects(BigSyncPendingMutation.self).isEmpty)
            XCTAssertFalse(fixture.history.isInWriteTransaction)
        }
    }

    @RealmBackgroundActor
    func testFinalCommitAdmissionCannotBeReplacedByAStaleBoolean() async throws {
        let fixture = try await makeFixture()
        for reportedAdmission in [false, true] {
            do {
                _ = try await ReaderContentLoader.importContent(
                    .html("<p>Requires an actual admitted commit</p>", fromClipboard: false),
                    storage: fixture.storage, permitsCommit: { true },
                    commitIfCurrent: { _ in reportedAdmission }
                )
                XCTFail("A result without invoking the synchronous commit must not auto-commit")
            } catch is CancellationError { }
            XCTAssertTrue(fixture.history.objects(HistoryRecord.self).isEmpty)
            XCTAssertTrue(fixture.history.objects(BigSyncPendingMutation.self).isEmpty)
            XCTAssertFalse(fixture.history.isInWriteTransaction)
        }
    }

    @RealmBackgroundActor
    func testCancellationDuringProvisionalMutationRollsBackCreation() async throws {
        let fixture = try await makeFixture()
        let probe = ContentImportWriteProbe(realm: fixture.history, mode: .cancelNewHistory)
        let task = Task { @RealmBackgroundActor in
            try await ReaderContentLoader.importContent(
                .html("<p>Cancelled while provisional</p>", fromClipboard: false),
                storage: fixture.storage, permitsCommit: { probe.permitsCommit() },
                commitIfCurrent: Self.commitWithoutAccount
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation at the final permission boundary must roll back")
        } catch is CancellationError { }
        XCTAssertTrue(probe.observedMutation)
        XCTAssertTrue(fixture.history.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(fixture.history.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertFalse(fixture.history.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testCancellationInsideCommitAdmissionIsCheckedBeforeActualCommit() async throws {
        let fixture = try await makeFixture()
        let task = Task { @RealmBackgroundActor in
            try await ReaderContentLoader.importContent(
                .html("<p>Cancelled inside admission</p>", fromClipboard: false),
                storage: fixture.storage, permitsCommit: { true },
                commitIfCurrent: { commit in
                    withUnsafeCurrentTask { $0?.cancel() }
                    try commit()
                    return true
                }
            )
        }
        do {
            _ = try await task.value
            XCTFail("The final commit operation must observe cancellation")
        } catch is CancellationError { }
        XCTAssertTrue(fixture.history.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(fixture.history.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertFalse(fixture.history.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testSuccessfulCommitSurvivesLaterCallbackCancellationAndError() async throws {
        let fixture = try await makeFixture()
        let task = Task { @RealmBackgroundActor in
            try await ReaderContentLoader.importContent(
                .html("<p>Already saved</p>", fromClipboard: false),
                storage: fixture.storage, permitsCommit: { true },
                commitIfCurrent: { commit in
                    try commit()
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw FixtureError.afterCommit
                }
            )
        }
        let result = try await task.value
        let reference = try XCTUnwrap(result).reference
        XCTAssertTrue(task.isCancelled)
        let record = try XCTUnwrap(fixture.history.object(
            ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
        ))
        XCTAssertTrue(record.html?.contains("Already saved") == true)
        XCTAssertEqual(fixture.history.objects(BigSyncPendingMutation.self).count, 1)
        XCTAssertFalse(fixture.history.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testCapturedStorageDoesNotFollowReplacementGlobalConfiguration() async throws {
        let original = try await makeFixture()
        let replacement = try await makeFixture()
        let previous = await MainActor.run {
            let previous = ImportGlobalConfigurations.capture()
            ImportGlobalConfigurations(
                bookmarks: replacement.bookmarkConfiguration,
                history: replacement.historyConfiguration,
                feeds: replacement.feedConfiguration
            ).install()
            return previous
        }
        addTeardownBlock { await previous.install() }

        let result = try await ReaderContentLoader.importContent(
            .html("<p>Original captured store</p>", fromClipboard: true),
            storage: original.storage, permitsCommit: { true },
            commitIfCurrent: Self.commitWithoutAccount
        )
        let reference = try XCTUnwrap(result).reference
        XCTAssertEqual(reference.realmConfiguration.inMemoryIdentifier, original.historyConfiguration.inMemoryIdentifier)
        XCTAssertEqual(original.history.objects(HistoryRecord.self).count, 1)
        XCTAssertEqual(original.history.objects(BigSyncPendingMutation.self).count, 1)
        XCTAssertTrue(replacement.history.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(replacement.history.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @RealmBackgroundActor
    func testCancelledQueuedImportPreservesForeignWriteAndCanRetry() async throws {
        let fixture = try await makeFixture()
        let gate = ContentImportWriteGate()
        let owner = Task { @RealmBackgroundActor in
            try fixture.history.beginWrite()
            let bookmark = Bookmark()
            bookmark.compoundKey = "foreign-writer"
            bookmark.url = URL(string: "https://example.com/foreign")!
            bookmark.title = "Foreign write must survive"
            fixture.history.add(bookmark)
            bookmark.refreshChangeMetadata(explicitlyModified: true)
            await gate.hold()
            let stillOwned = fixture.history.isInWriteTransaction
            if stillOwned { try fixture.history.commitWrite() }
            return stillOwned
        }
        addTeardownBlock {
            await gate.release()
            _ = await owner.result
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        let foreignSnapshot = Self.snapshot(in: fixture.history)
        let submitted = XCTestExpectation(description: "Import begin ticket submitted")
        let settled = XCTestExpectation(description: "Cancelled import settled")
        let lookup = Task { @RealmBackgroundActor in
            defer { settled.fulfill() }
            return try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await ReaderContentLoader.importContent(
                    .html("<p>Queued import</p>", fromClipboard: false),
                    storage: fixture.storage, permitsCommit: { true },
                    commitIfCurrent: Self.commitWithoutAccount
                )
            }
        }
        addTeardownBlock {
            lookup.cancel()
            await gate.release()
            _ = await lookup.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        lookup.cancel()
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertTrue(fixture.history.isInWriteTransaction)
        XCTAssertEqual(Self.snapshot(in: fixture.history), foreignSnapshot)
        // If cancellation regresses, release the foreign owner before joining
        // the queued task so a failed expectation cannot hang this fixture.
        await gate.release()
        let retained = try await owner.value
        XCTAssertTrue(retained)
        do {
            _ = try await lookup.value
            XCTFail("Cancellation must retire only the queued import ticket")
        } catch is CancellationError { }

        let retry = try await ReaderContentLoader.importContent(
            .html("<p>Queued import</p>", fromClipboard: false),
            storage: fixture.storage, permitsCommit: { true },
            commitIfCurrent: Self.commitWithoutAccount
        )
        XCTAssertNotNil(retry)
        XCTAssertEqual(fixture.history.object(
            ofType: Bookmark.self, forPrimaryKey: "foreign-writer"
        )?.title, "Foreign write must survive")
        XCTAssertEqual(fixture.history.objects(HistoryRecord.self).count, 1)
        XCTAssertFalse(fixture.history.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testRejectedURLVisitRollsBackMetadataAndBookmarkLinksTogether() async throws {
        let fixture = try await makeFixture()
        let url = URL(string: "https://example.com/bookmark-import")!
        try Self.seedBookmarkAndHistory(url: url, in: fixture.history)
        let before = Self.snapshot(in: fixture.history)
        let probe = ContentImportWriteProbe(realm: fixture.history, mode: .rejectBookmarkLink)
        do {
            _ = try await ReaderContentLoader.importContent(
                .url(url), storage: fixture.storage,
                permitsCommit: { probe.permitsCommit() },
                commitIfCurrent: Self.commitWithoutAccount
            )
            XCTFail("Visit, copied metadata and links must roll back in the same write")
        } catch is CancellationError { }
        XCTAssertTrue(probe.observedMutation)
        XCTAssertEqual(Self.snapshot(in: fixture.history), before)
        XCTAssertNil(fixture.history.objects(HistoryRecord.self).first?.bookmarkID)
        XCTAssertFalse(fixture.history.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testSplitStoreURLImportLeavesCapturedSourcesUnchanged() async throws {
        let fixture = try await makeFixture(splitStores: true)
        let url = URL(string: "https://example.com/split-import")!
        let bookmark = Bookmark()
        bookmark.compoundKey = "split-bookmark"
        bookmark.url = url
        bookmark.title = "Captured source"
        bookmark.html = "<p>Captured full body</p>"
        bookmark.rssContainsFullContent = true
        try fixture.bookmarks.write {
            fixture.bookmarks.add(bookmark)
            bookmark.refreshChangeMetadata(explicitlyModified: true)
        }
        let sourceBefore = Self.snapshot(in: fixture.bookmarks)
        let feedBefore = Self.snapshot(in: fixture.feeds)
        let result = try await ReaderContentLoader.importContent(
            .url(url), storage: fixture.storage, permitsCommit: { true },
            commitIfCurrent: Self.commitWithoutAccount
        )
        let reference = try XCTUnwrap(result).reference
        let history = try XCTUnwrap(fixture.history.object(
            ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
        ))
        XCTAssertEqual(history.title, bookmark.title)
        XCTAssertEqual(history.html, bookmark.html)
        XCTAssertEqual(history.bookmarkID, bookmark.compoundKey)
        XCTAssertEqual(reference.realmConfiguration.inMemoryIdentifier, fixture.historyConfiguration.inMemoryIdentifier)
        XCTAssertEqual(Self.snapshot(in: fixture.bookmarks), sourceBefore)
        XCTAssertEqual(Self.snapshot(in: fixture.feeds), feedBefore)
        XCTAssertEqual(fixture.history.objects(BigSyncPendingMutation.self).count, 1)
    }

    @RealmBackgroundActor
    func testURLSourceIsSelectedAfterRealQueuedWriteAdmission() async throws {
        let fixture = try await makeFixture()
        let url = URL(string: "https://example.com/queued-source")!
        try Self.seedBookmarkAndHistory(url: url, in: fixture.history)
        let gate = ContentImportWriteGate()
        let owner = Task { @RealmBackgroundActor () throws -> [String: String]? in
            try fixture.history.beginWrite()
            await gate.hold()
            guard fixture.history.isInWriteTransaction else { return nil }
            let bookmark = fixture.history.objects(Bookmark.self).first!
            bookmark.isDeleted = true
            bookmark.refreshChangeMetadata(explicitlyModified: true)
            let expected = Self.snapshot(in: fixture.history)
            try fixture.history.commitWrite()
            return expected
        }
        addTeardownBlock {
            await gate.release()
            _ = await owner.result
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        let submitted = XCTestExpectation(description: "URL import queued before source retirement")
        let lookup = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await ReaderContentLoader.importContent(
                    .url(url), storage: fixture.storage, permitsCommit: { true },
                    commitIfCurrent: Self.commitWithoutAccount
                )
            }
        }
        addTeardownBlock {
            lookup.cancel()
            await gate.release()
            _ = await lookup.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        XCTAssertFalse(fixture.history.objects(Bookmark.self).first!.isDeleted)
        await gate.release()
        let expectedResult = try await owner.value
        let expected = try XCTUnwrap(expectedResult)
        let result = try await lookup.value
        let reference = try XCTUnwrap(result).reference
        let record = try XCTUnwrap(fixture.history.object(
            ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
        ))
        XCTAssertEqual(record.title, "Original history")
        XCTAssertNil(record.bookmarkID)
        let after = Self.snapshot(in: fixture.history)
        let bookmarkKey = Bookmark.className() + ".original-bookmark"
        XCTAssertEqual(after[bookmarkKey], expected[bookmarkKey])
        XCTAssertEqual(after["journal." + bookmarkKey], expected["journal." + bookmarkKey])
        XCTAssertFalse(fixture.history.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testURLImportRevivesCanonicalHistoryAndPreservesDownloadedBody() async throws {
        let fixture = try await makeFixture()
        let url = URL(string: "https://example.com/canonical-import")!
        let canonical = HistoryRecord()
        canonical.url = url
        canonical.updateCompoundKey()
        canonical.html = "<p>Keep the downloaded body.</p>"
        canonical.isDeleted = true
        let alias = HistoryRecord()
        alias.compoundKey = "deleted-alias"
        alias.url = ReaderContentLoader.readerLoaderURL(for: url)!
        alias.lastVisitedAt = .distantFuture
        alias.isDeleted = true
        let bookmark = Bookmark()
        bookmark.compoundKey = "canonical-bookmark"
        bookmark.url = url
        bookmark.title = "Current source title"
        bookmark.rssContainsFullContent = false
        bookmark.voiceAudioURLs.append(URL(string: "https://example.com/audio.mp3")!)
        bookmark.audioSubtitlesURL = URL(string: "https://example.com/audio.vtt")!
        bookmark.redditTranslationsUrl = URL(string: "https://example.com/translations.json")!
        bookmark.redditTranslationsTitle = "Current translations"
        bookmark.feedEntryCollectionTitle = "Source collection"
        try fixture.history.write {
            fixture.history.add(canonical)
            fixture.history.add(alias)
            fixture.history.add(bookmark)
            for row in [canonical, alias, bookmark] as [Bookmark] {
                row.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        let before = Self.snapshot(in: fixture.history)
        let result = try await ReaderContentLoader.importContent(
            .url(url), storage: fixture.storage, permitsCommit: { true },
            commitIfCurrent: Self.commitWithoutAccount
        )
        XCTAssertEqual(result?.reference.contentKey, canonical.compoundKey)
        XCTAssertFalse(canonical.isDeleted)
        XCTAssertTrue(alias.isDeleted)
        XCTAssertEqual(canonical.html, "<p>Keep the downloaded body.</p>")
        XCTAssertEqual(canonical.title, bookmark.title)
        XCTAssertEqual(canonical.bookmarkID, bookmark.compoundKey)
        XCTAssertEqual(canonical.voiceAudioURLs.first, bookmark.voiceAudioURLs.first)
        XCTAssertEqual(canonical.audioSubtitlesURL, bookmark.audioSubtitlesURL)
        XCTAssertEqual(canonical.audioSubtitlesRole, .content)
        XCTAssertEqual(canonical.redditTranslationsUrl, bookmark.redditTranslationsUrl)
        XCTAssertEqual(canonical.redditTranslationsTitle, bookmark.redditTranslationsTitle)
        XCTAssertEqual(canonical.feedEntryCollectionTitle, bookmark.feedEntryCollectionTitle)
        XCTAssertEqual(canonical.isDemoted, false)
        XCTAssertEqual(fixture.history.objects(HistoryRecord.self).count, 2)
        let after = Self.snapshot(in: fixture.history)
        for key in [
            HistoryRecord.className() + ".deleted-alias",
            Bookmark.className() + ".canonical-bookmark",
        ] {
            XCTAssertEqual(after[key], before[key])
            XCTAssertEqual(after["journal." + key], before["journal." + key])
        }
    }

    @RealmBackgroundActor
    func testContentFileImportUsesCapturedHistoryStoreWhenBookmarksAreSeparate() async throws {
        let fixture = try await makeFixture(splitStores: true)
        let url = URL(string: "https://example.com/stored-content-file")!
        let original = ContentFile()
        original.compoundKey = "history-file"
        original.url = url
        original.title = "History-owned file"
        original.html = "<p>Original captured file body.</p>"
        original.rssContainsFullContent = true
        try fixture.history.write {
            fixture.history.add(original)
            original.refreshChangeMetadata(explicitlyModified: true)
        }
        let unrelated = ContentFile()
        unrelated.compoundKey = "bookmarks-file"
        unrelated.url = url
        unrelated.title = "Different store's file"
        unrelated.createdAt = .distantFuture
        try fixture.bookmarks.write {
            fixture.bookmarks.add(unrelated)
            unrelated.refreshChangeMetadata(explicitlyModified: true)
        }
        let historyBefore = Self.snapshot(in: fixture.history)
        let bookmarksBefore = Self.snapshot(in: fixture.bookmarks)
        let result = try await ReaderContentLoader.importContent(
            .url(url), storage: fixture.storage, permitsCommit: { true },
            commitIfCurrent: Self.commitWithoutAccount
        )
        let reference = try XCTUnwrap(result).reference
        let record = try XCTUnwrap(fixture.history.object(
            ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
        ))
        XCTAssertEqual(record.title, original.title)
        XCTAssertEqual(record.html, original.html)
        let fileKey = ContentFile.className() + "." + original.compoundKey
        let historyAfter = Self.snapshot(in: fixture.history)
        XCTAssertEqual(historyAfter[fileKey], historyBefore[fileKey])
        XCTAssertEqual(historyAfter["journal." + fileKey], historyBefore["journal." + fileKey])
        XCTAssertEqual(Self.snapshot(in: fixture.bookmarks), bookmarksBefore)
        XCTAssertEqual(fixture.history.objects(HistoryRecord.self).count, 1)
        XCTAssertEqual(fixture.history.objects(BigSyncPendingMutation.self).count, 2)
    }

    @RealmBackgroundActor
    func testTranscriptURLImportPreservesTheRegisteredBodyTitleAndSourceURL() async throws {
        let fixture = try await makeFixture()
        let asset = TranscriptPageAsset(
            key: "content-import-\(UUID())",
            canonicalContentURL: URL(string: "https://example.com/original-media")!,
            title: "Registered transcript title",
            html: "<html><body><p>登録済みの字幕です。</p></body></html>"
        )
        await TranscriptPageRegistry.shared.register(asset)
        addTeardownBlock { await TranscriptPageRegistry.shared.remove(key: asset.key) }
        let pageURL = try XCTUnwrap(asset.pageURL)
        let result = try await ReaderContentLoader.importContent(
            .url(pageURL, fromClipboard: true), storage: fixture.storage,
            permitsCommit: { true }, commitIfCurrent: Self.commitWithoutAccount
        )
        let reference = try XCTUnwrap(result).reference
        let record = try XCTUnwrap(fixture.history.object(
            ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
        ))
        XCTAssertEqual(reference.contentURL, pageURL)
        XCTAssertEqual(record.url, pageURL)
        XCTAssertEqual(record.title, asset.title)
        XCTAssertEqual(record.html, asset.html)
        XCTAssertEqual(record.sourceDownloadURL, asset.canonicalContentURL)
        XCTAssertTrue(record.rssContainsFullContent)
        XCTAssertTrue(record.isReaderModeByDefault)
        XCTAssertEqual(result?.objectID, record.id)
        XCTAssertEqual(record.explicitlyModifiedAt, record.lastVisitedAt)
        XCTAssertEqual(fixture.history.objects(HistoryRecord.self).count, 1)
        XCTAssertEqual(fixture.history.objects(BigSyncPendingMutation.self).count, 1)
        let retainedAsset = await TranscriptPageRegistry.shared.asset(forKey: asset.key)
        XCTAssertEqual(retainedAsset, asset)
        XCTAssertFalse(fixture.history.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testQueuedTranscriptImportKeepsItsSnapshotAndRechecksOriginalAdmission() async throws {
        for (removeAsset, rejectAdmission) in [(false, false), (true, false), (false, true)] {
            let fixture = try await makeFixture()
            let asset = TranscriptPageAsset(
                key: "held-content-import-\(UUID())",
                canonicalContentURL: URL(string: "https://example.com/held-media")!,
                title: "Captured transcript",
                html: "<html><body><p>Captured transcript body.</p></body></html>"
            )
            let replacement = TranscriptPageAsset(
                key: asset.key, canonicalContentURL: asset.canonicalContentURL,
                title: "Replacement registry value", html: "<p>Later body.</p>"
            )
            await TranscriptPageRegistry.shared.register(asset)
            addTeardownBlock { await TranscriptPageRegistry.shared.remove(key: asset.key) }
            let pageURL = try XCTUnwrap(asset.pageURL)
            let permission = ContentImportPermission()
            let gate = ContentImportWriteGate()
            let owner = Task { @RealmBackgroundActor in
                try fixture.history.beginWrite()
                await gate.hold()
                let stillOwned = fixture.history.isInWriteTransaction
                if stillOwned { try fixture.history.commitWrite() }
                return stillOwned
            }
            addTeardownBlock {
                await gate.release()
                _ = await owner.result
            }
            await fulfillment(of: [gate.entered], timeout: 5)
            let submitted = XCTestExpectation(description: "Transcript snapshot reached actual write submission")
            let importing = Task { @RealmBackgroundActor in
                try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    try await ReaderContentLoader.importContent(
                        .url(pageURL, fromClipboard: true), storage: fixture.storage,
                        permitsCommit: { permission.permitsCommit() },
                        commitIfCurrent: Self.commitWithoutAccount
                    )
                }
            }
            addTeardownBlock {
                importing.cancel()
                await gate.release()
                _ = await owner.result
                _ = await importing.result
            }
            await fulfillment(of: [submitted], timeout: 5)
            if removeAsset {
                await TranscriptPageRegistry.shared.remove(key: asset.key)
            } else {
                await TranscriptPageRegistry.shared.register(replacement)
            }
            if rejectAdmission { permission.revoke() }
            XCTAssertTrue(fixture.history.isInWriteTransaction)
            XCTAssertTrue(fixture.history.objects(HistoryRecord.self).isEmpty)
            await gate.release()
            let retained = try await owner.value
            XCTAssertTrue(retained)

            if rejectAdmission {
                do {
                    _ = try await importing.value
                    XCTFail("Original admission must be checked again after the held write becomes available")
                } catch is CancellationError { }
                XCTAssertTrue(fixture.history.objects(HistoryRecord.self).isEmpty)
                XCTAssertTrue(fixture.history.objects(BigSyncPendingMutation.self).isEmpty)
            } else {
                let saved = try await importing.value
                let reference = try XCTUnwrap(saved).reference
                let record = try XCTUnwrap(fixture.history.object(
                    ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
                ))
                XCTAssertEqual(record.title, asset.title)
                XCTAssertEqual(record.html, asset.html)
                XCTAssertEqual(record.sourceDownloadURL, asset.canonicalContentURL)
                XCTAssertEqual(fixture.history.objects(BigSyncPendingMutation.self).count, 1)
            }
            let retainedAsset = await TranscriptPageRegistry.shared.asset(forKey: asset.key)
            XCTAssertEqual(retainedAsset, removeAsset ? nil : replacement)
            XCTAssertFalse(fixture.history.isInWriteTransaction)
        }
    }

    @RealmBackgroundActor
    func testStoredSnippetImportKeepsCanonicalBodyRepairInsideTheVisitTransaction() async throws {
        for fromClipboard in [false, true] {
            let fixture = try await makeFixture()
            let record = HistoryRecord()
            record.compoundKey = "existing-snippet"
            record.url = try XCTUnwrap(ReaderContentLoader.snippetURL(key: record.compoundKey))
            record.title = "Retained custom title"
            record.html = """
            <html><body>
              <div id="reader-header"><h1 id="reader-title">Retained header</h1></div>
              <div id="reader-content"><div id="reader-content"><p>Retained inner body.</p></div></div>
            </body></html>
            """
            record.isReaderModeByDefault = false
            record.rssContainsFullContent = false
            record.isFromClipboard = false
            record.isDemoted = true
            record.lastVisitedAt = .distantPast
            try fixture.history.write {
                fixture.history.add(record)
                record.refreshChangeMetadata(explicitlyModified: true)
            }
            let originalID = record.id
            let originalCreation = record.createdAt
            let original = Self.snapshot(in: fixture.history)
            do {
                _ = try await ReaderContentLoader.importContent(
                    .url(record.url, fromClipboard: fromClipboard), storage: fixture.storage,
                    permitsCommit: { true }, commitIfCurrent: { _ in false }
                )
                XCTFail("Rejected visit must roll back body repair and presentation flags together")
            } catch is CancellationError { }
            XCTAssertEqual(Self.snapshot(in: fixture.history), original)

            let result = try await ReaderContentLoader.importContent(
                .url(record.url, fromClipboard: fromClipboard), storage: fixture.storage,
                permitsCommit: { true }, commitIfCurrent: Self.commitWithoutAccount
            )
            let document = try SwiftSoup.parse(XCTUnwrap(record.html))
            XCTAssertEqual(try document.select("#reader-content").array().count, 1)
            XCTAssertEqual(try document.select("#reader-content").text(), "Retained inner body.")
            XCTAssertEqual(try document.select("#reader-title").text(), "Retained header")
            XCTAssertEqual(record.title, "Retained custom title")
            XCTAssertEqual(record.createdAt, originalCreation)
            XCTAssertEqual(result?.objectID, originalID)
            XCTAssertEqual(result?.reference.contentKey, record.compoundKey)
            XCTAssertTrue(record.isReaderModeByDefault)
            XCTAssertTrue(record.rssContainsFullContent)
            XCTAssertEqual(record.isFromClipboard, fromClipboard)
            XCTAssertEqual(record.isDemoted, false)
            XCTAssertEqual(record.modifiedAt, record.lastVisitedAt)
            XCTAssertEqual(record.explicitlyModifiedAt, record.lastVisitedAt)
            XCTAssertEqual(fixture.history.objects(BigSyncPendingMutation.self).count, 1)
            XCTAssertEqual(fixture.history.objects(BigSyncPendingMutation.self).first?.changedAt, record.lastVisitedAt)
            XCTAssertFalse(fixture.history.isInWriteTransaction)
        }
    }

    @RealmBackgroundActor
    func testHTTPSImportUsesHTTPFeedWithoutWritingItsImageCache() async throws {
        let fixture = try await makeFixture()
        let url = URL(string: "https://example.com/feed-import")!
        let feed = Feed()
        feed.extractImageFromContent = true
        feed.rssContainsFullContent = true
        let entry = FeedEntry()
        entry.compoundKey = "http-feed-import"
        entry.feedID = feed.id
        entry.url = URL(string: "http://example.com/feed-import")!
        entry.title = "HTTP source"
        entry.html = "<html><body><img src='https://example.com/photo.jpg'><p>Full feed body.</p></body></html>"
        try fixture.history.write {
            fixture.history.add(feed)
            fixture.history.add(entry)
            feed.refreshChangeMetadata(explicitlyModified: true)
            entry.refreshChangeMetadata(explicitlyModified: true)
        }
        let before = Self.snapshot(in: fixture.history)
        let result = try await ReaderContentLoader.importContent(
            .url(url), storage: fixture.storage, permitsCommit: { true },
            commitIfCurrent: Self.commitWithoutAccount
        )
        let reference = try XCTUnwrap(result).reference
        let history = try XCTUnwrap(fixture.history.object(
            ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
        ))
        XCTAssertEqual(history.url, url)
        XCTAssertEqual(history.title, entry.title)
        XCTAssertEqual(history.content, entry.content)
        XCTAssertEqual(history.imageUrl, URL(string: "https://example.com/photo.jpg"))
        XCTAssertNil(entry.imageUrl)
        let after = Self.snapshot(in: fixture.history)
        for key in [
            FeedEntry.className() + "." + entry.compoundKey,
            Feed.className() + "." + feed.id.uuidString,
        ] {
            XCTAssertNotNil(before[key])
            XCTAssertNotNil(before["journal." + key])
            XCTAssertEqual(after[key], before[key])
            XCTAssertEqual(after["journal." + key], before["journal." + key])
        }
    }

    @RealmBackgroundActor
    func testForeignSourceWriteIsNotBorrowedAndRetryUsesCommittedMetadata() async throws {
        let fixture = try await makeFixture(splitStores: true)
        let url = URL(string: "https://example.com/foreign-source")!
        let bookmark = Bookmark()
        bookmark.compoundKey = "foreign-source"
        bookmark.url = url
        bookmark.title = "Committed source"
        try fixture.bookmarks.write {
            fixture.bookmarks.add(bookmark)
            bookmark.refreshChangeMetadata(explicitlyModified: true)
        }
        let before = Self.snapshot(in: fixture.bookmarks)
        try fixture.bookmarks.beginWrite()
        defer {
            if fixture.bookmarks.isInWriteTransaction { fixture.bookmarks.cancelWrite() }
        }
        bookmark.title = "Provisional source"
        do {
            _ = try await ReaderContentLoader.importContent(
                .url(url), storage: fixture.storage, permitsCommit: { true },
                commitIfCurrent: Self.commitWithoutAccount
            )
            XCTFail("Another source store's open write cannot authorize copied metadata")
        } catch ReaderContentImportError.sourceWriteInProgress { }
        XCTAssertTrue(fixture.bookmarks.isInWriteTransaction)
        XCTAssertEqual(bookmark.title, "Provisional source")
        XCTAssertTrue(fixture.history.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(fixture.history.objects(BigSyncPendingMutation.self).isEmpty)
        fixture.bookmarks.cancelWrite()
        XCTAssertEqual(Self.snapshot(in: fixture.bookmarks), before)

        let result = try await ReaderContentLoader.importContent(
            .url(url), storage: fixture.storage, permitsCommit: { true },
            commitIfCurrent: Self.commitWithoutAccount
        )
        let reference = try XCTUnwrap(result).reference
        XCTAssertEqual(fixture.history.object(
            ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey
        )?.title, "Committed source")
        XCTAssertEqual(Self.snapshot(in: fixture.bookmarks), before)
    }

    @RealmBackgroundActor
    func testSamePathReplacementRejectsCapturedImportAndPreservesOriginalLiveRealm() async throws {
        let fixture = try await makeFixture(fileBacked: true)
        let fileURL = try XCTUnwrap(fixture.historyConfiguration.fileURL)
        let replacementURL = fileURL.deletingLastPathComponent().appendingPathComponent("replacement.realm")
        try fixture.history.writeCopy(toFile: replacementURL)
        try FileManager.default.moveItem(
            at: fileURL, to: fileURL.deletingLastPathComponent().appendingPathComponent("retired.realm")
        )
        try FileManager.default.moveItem(at: replacementURL, to: fileURL)
        let before = Self.snapshot(in: fixture.history)

        do {
            _ = try await ReaderContentLoader.importContent(
                .html("<p>Must not enter successor file</p>", fromClipboard: false),
                storage: fixture.storage, permitsCommit: { true },
                commitIfCurrent: Self.commitWithoutAccount
            )
            XCTFail("The captured admission must reject a same-path successor")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        XCTAssertEqual(Self.snapshot(in: fixture.history), before)
        XCTAssertFalse(fixture.history.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testStorageReplacementInsideCommitAdmissionRollsBackProvisionalImport() async throws {
        let fixture = try await makeFixture(fileBacked: true)
        let fileURL = try XCTUnwrap(fixture.historyConfiguration.fileURL)
        let directory = fileURL.deletingLastPathComponent()
        let replacementURL = directory.appendingPathComponent("replacement.realm")
        let retiredURL = directory.appendingPathComponent("retired.realm")
        try fixture.history.writeCopy(toFile: replacementURL)
        let before = Self.snapshot(in: fixture.history)
        do {
            _ = try await ReaderContentLoader.importContent(
                .html("<p>Retired just before commit</p>", fromClipboard: false),
                storage: fixture.storage, permitsCommit: { true },
                commitIfCurrent: { commit in
                    try FileManager.default.moveItem(at: fileURL, to: retiredURL)
                    try FileManager.default.moveItem(at: replacementURL, to: fileURL)
                    try commit()
                    return true
                }
            )
            XCTFail("The operation inside the final gate must recheck physical identity")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        XCTAssertEqual(Self.snapshot(in: fixture.history), before)
        XCTAssertFalse(fixture.history.isInWriteTransaction)
    }

    func testTextPayloadUsesExistingNormalizationAndExactURLPolicy() {
        XCTAssertNil(ReaderContentLoader.importPayload(fromText: " \n "))
        if case let .url(url, fromClipboard)? = ReaderContentLoader.importPayload(
            fromText: " https://example.com/a%23b?x=1%26y=2 "
        ) {
            XCTAssertEqual(url.absoluteString, "https://example.com/a%23b?x=1%26y=2")
            XCTAssertFalse(fromClipboard)
        } else {
            XCTFail("A supported URL should remain a URL payload")
        }
        if case let .html(html, fromClipboard)? = ReaderContentLoader.importPayload(fromText: " 日本語\n文章 ") {
            XCTAssertEqual(html, ReaderContentLoader.snippetHTML(fromRawText: "日本語\n文章"))
            XCTAssertFalse(fromClipboard)
        } else {
            XCTFail("Plain text should use the selected snippet normalizer")
        }
    }

    private static func commitWithoutAccount(_ commit: () throws -> Void) throws -> Bool {
        try commit()
        return true
    }

    @RealmBackgroundActor
    private struct Fixture {
        let storage: ReaderContentLoader.ImportStorage
        let bookmarkConfiguration: Realm.Configuration
        let historyConfiguration: Realm.Configuration
        let feedConfiguration: Realm.Configuration
        let bookmarks: Realm
        let history: Realm
        let feeds: Realm
    }

    private struct ImportGlobalConfigurations: @unchecked Sendable {
        let bookmarks: Realm.Configuration
        let history: Realm.Configuration
        let feeds: Realm.Configuration

        @MainActor
        static func capture() -> Self {
            Self(
                bookmarks: ReaderContentLoader.bookmarkRealmConfiguration,
                history: ReaderContentLoader.historyRealmConfiguration,
                feeds: ReaderContentLoader.feedEntryRealmConfiguration
            )
        }

        @MainActor
        func install() {
            ReaderContentLoader.bookmarkRealmConfiguration = bookmarks
            ReaderContentLoader.historyRealmConfiguration = history
            ReaderContentLoader.feedEntryRealmConfiguration = feeds
        }
    }

    @RealmBackgroundActor
    private func makeFixture(splitStores: Bool = false, fileBacked: Bool = false) async throws -> Fixture {
        var directories = [URL]()
        func configuration(_ role: String) throws -> Realm.Configuration {
            var configuration = Realm.Configuration()
            if fileBacked {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ContentImport-\(role)-\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                directories.append(directory)
                configuration.fileURL = directory.appendingPathComponent("store.realm")
            } else {
                configuration.fileURL = nil
                configuration.inMemoryIdentifier = "ContentImport-\(role)-\(UUID())"
            }
            configuration.objectTypes = [
                Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self, Feed.self,
            ]
            configureLakeOfFireMutationTrackingForTesting(&configuration)
            return configuration
        }
        let historyConfiguration = try configuration("history")
        let bookmarkConfiguration = splitStores ? try configuration("bookmarks") : historyConfiguration
        let feedConfiguration = splitStores ? try configuration("feeds") : historyConfiguration
        let history = try await RealmBackgroundActor.shared.cachedRealm(for: historyConfiguration)
        let bookmarks = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkConfiguration)
        let feeds = try await RealmBackgroundActor.shared.cachedRealm(for: feedConfiguration)
        let cacheKeys = Set([historyConfiguration, bookmarkConfiguration, feedConfiguration].map {
            RealmBackgroundActor.shared.realmCacheKey(for: $0)
        })
        let capturedDirectories = directories
        addTeardownBlock {
            let released = await { @RealmBackgroundActor in
                for key in cacheKeys {
                    if RealmBackgroundActor.shared.cachedRealms[key]?.isInWriteTransaction == true {
                        XCTFail("Import fixture still has an owned writer during teardown")
                        return false
                    }
                }
                for key in cacheKeys {
                    let realm = RealmBackgroundActor.shared.cachedRealms.removeValue(forKey: key)
                    realm?.invalidate()
                }
                return true
            }()
            if released {
                for directory in capturedDirectories {
                    try FileManager.default.removeItem(at: directory)
                }
            }
        }
        let configurations = ImportGlobalConfigurations(
            bookmarks: bookmarkConfiguration, history: historyConfiguration, feeds: feedConfiguration
        )
        let storage = await MainActor.run {
            let previous = ImportGlobalConfigurations.capture()
            defer { previous.install() }
            configurations.install()
            return ReaderContentLoader.ImportStorage.capture()
        }
        return Fixture(
            storage: storage, bookmarkConfiguration: bookmarkConfiguration,
            historyConfiguration: historyConfiguration, feedConfiguration: feedConfiguration,
            bookmarks: bookmarks, history: history, feeds: feeds
        )
    }

    @RealmBackgroundActor
    private static func seedBookmarkAndHistory(url: URL, in realm: Realm) throws {
        let bookmark = Bookmark()
        bookmark.compoundKey = "original-bookmark"
        bookmark.url = url
        bookmark.title = "Original bookmark"
        bookmark.html = "<p>Original bookmark body.</p>"
        bookmark.rssContainsFullContent = true
        bookmark.createdAt = .distantFuture
        let history = HistoryRecord()
        history.compoundKey = "original-history"
        history.url = url
        history.title = "Original history"
        history.html = "<p>Original history body.</p>"
        history.lastVisitedAt = .distantPast
        try realm.write {
            realm.add(bookmark)
            realm.add(history)
            bookmark.refreshChangeMetadata(explicitlyModified: true)
            history.refreshChangeMetadata(explicitlyModified: true)
        }
    }

    @RealmBackgroundActor
    private static func snapshot(in realm: Realm) -> [String: String] {
        var values = [String: String]()
        let contents: [any ReaderContentProtocol] =
            realm.objects(Bookmark.self).map { $0 as any ReaderContentProtocol }
            + realm.objects(HistoryRecord.self).map { $0 as any ReaderContentProtocol }
            + realm.objects(ContentFile.self).map { $0 as any ReaderContentProtocol }
            + realm.objects(FeedEntry.self).map { $0 as any ReaderContentProtocol }
        for content in contents {
            let history = content as? HistoryRecord
            values[content.objectSchema.className + "." + content.compoundKey] = [
                content.url.absoluteString, content.title, content.html ?? "",
                content.content?.base64EncodedString() ?? "",
                String(content.createdAt.timeIntervalSinceReferenceDate),
                String(content.modifiedAt.timeIntervalSinceReferenceDate),
                content.explicitlyModifiedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "nil",
                String(content.isDeleted), String(content.isTitlePrefixOfContent),
                String(content.isFromClipboard), String(content.rssContainsFullContent),
                String(content.isReaderModeByDefault),
                history.map { String($0.lastVisitedAt.timeIntervalSinceReferenceDate) } ?? "nil",
                history.flatMap { $0.isDemoted }.map { String($0) } ?? "nil",
                history?.bookmarkID ?? "nil",
                content.voiceAudioURLs.map(\.absoluteString).joined(separator: ","),
                content.audioSubtitlesURL?.absoluteString ?? "nil",
                content.redditTranslationsUrl?.absoluteString ?? "nil",
                content.redditTranslationsTitle ?? "nil",
                content.feedEntryCollectionTitle ?? "nil",
            ].joined(separator: "|")
        }
        for feed in realm.objects(Feed.self) {
            values[Feed.className() + "." + feed.id.uuidString] =
                "\(feed.title)|\(feed.extractImageFromContent)|\(feed.rssContainsFullContent)"
        }
        for journal in realm.objects(BigSyncPendingMutation.self) {
            values["journal." + journal.recordName] = [
                journal.entityType, journal.objectIdentifier, journal.generation,
                String(journal.changedAt.timeIntervalSinceReferenceDate),
            ].joined(separator: "|")
        }
        return values
    }
}
