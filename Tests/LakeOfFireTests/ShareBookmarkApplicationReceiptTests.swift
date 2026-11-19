import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

@RealmBackgroundActor
final class ShareBookmarkApplicationReceiptTests: XCTestCase {
    private struct Request: Encodable, Sendable {
        var id = UUID()
        var inputURL: URL? = URL(string: "https://example.org/shared")!
        var inputText: String?
        var inputTitle: String? = "Shared article"
        var isReaderModeByDefault = true
        var createdAt = Date(timeIntervalSince1970: 123)

        func canonicalPayload() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }
    }

    private struct JournalState: Equatable {
        let generation: String
        let changedAt: Date
    }

    private enum TestFailure: Error {
        case beforeCommit
    }

    @RealmBackgroundActor
    private final class ApplicationCount {
        var value = 0
    }

    func testFirstApplicationAndExactReplayHaveOneReceiptAndOneAuthoritativeMutation() async throws {
        let (configuration, realm) = try await makeRealm()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let request = Request()
        try await save(request, context: context)
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        let receipt = try XCTUnwrap(realm.objects(ShareBookmarkApplicationReceipt.self).first)
        let creation = bookmark.createdAt
        let appliedAt = receipt.appliedAt
        let journal = journalState(in: realm)
        XCTAssertEqual(bookmark.title, request.inputTitle)
        XCTAssertTrue(bookmark.isReaderModeByDefault)
        XCTAssertFalse(bookmark.isFromClipboard)
        XCTAssertFalse(bookmark.rssContainsFullContent)
        XCTAssertEqual(receipt.canonicalPayload, try request.canonicalPayload())
        XCTAssertEqual(receipt.bookmarkID, bookmark.compoundKey)
        XCTAssertEqual(receipt.appliedAt, bookmark.modifiedAt)
        XCTAssertEqual(Set(journal.keys), ["Bookmark.\(bookmark.compoundKey)"])

        try await save(request, context: context)
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        XCTAssertEqual(realm.objects(ShareBookmarkApplicationReceipt.self).count, 1)
        XCTAssertEqual(bookmark.createdAt, creation)
        XCTAssertEqual(receipt.appliedAt, appliedAt)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    func testOlderAppliedRequestCannotOverwriteALaterRequest() async throws {
        let (configuration, realm) = try await makeRealm()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let older = Request(inputTitle: "Older title")
        let newer = Request(inputTitle: "Newer title", isReaderModeByDefault: false)
        try await save(older, context: context)
        try await save(newer, context: context)
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        let journal = journalState(in: realm)
        try await save(older, context: context)
        XCTAssertEqual(bookmark.title, "Newer title")
        XCTAssertFalse(bookmark.isReaderModeByDefault)
        XCTAssertEqual(realm.objects(ShareBookmarkApplicationReceipt.self).count, 2)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    func testReplayPreservesLaterUserFieldsAndDeletionTombstone() async throws {
        let (configuration, realm) = try await makeRealm()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let request = Request()
        try await save(request, context: context)
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        try realm.write {
            bookmark.title = "User title"
            bookmark.author = "User author"
            bookmark.isReaderModeByDefault = false
            bookmark.isDeleted = true
            bookmark.refreshChangeMetadata(explicitlyModified: true)
        }
        let journal = journalState(in: realm)
        try await save(request, context: context)
        XCTAssertEqual(bookmark.title, "User title")
        XCTAssertEqual(bookmark.author, "User author")
        XCTAssertFalse(bookmark.isReaderModeByDefault)
        XCTAssertTrue(bookmark.isDeleted)
        XCTAssertEqual(realm.objects(ShareBookmarkApplicationReceipt.self).count, 1)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    func testReceiptSurvivesPhysicalTargetRemovalAndReplayDoesNotRecreateIt() async throws {
        let (configuration, realm) = try await makeRealm()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let request = Request()
        try await save(request, context: context)
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        let bookmarkID = bookmark.compoundKey
        // Controlled storage-removal fixture; ordinary deletion remains a tombstone.
        try realm.write { realm.delete(bookmark) }
        let journal = journalState(in: realm)
        try await save(request, context: context)
        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertEqual(realm.objects(ShareBookmarkApplicationReceipt.self).first?.bookmarkID, bookmarkID)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    func testDistinctPayloadsWithTheSameRequestUUIDAreSeparateApplications() async throws {
        let (configuration, realm) = try await makeRealm()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let first = Request(inputTitle: "First payload")
        var second = first
        second.inputTitle = "Second payload"
        second.isReaderModeByDefault = false
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(try first.canonicalPayload(), try second.canonicalPayload())
        try await save(first, context: context)
        try await save(second, context: context)
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        XCTAssertEqual(realm.objects(Bookmark.self).first?.title, "Second payload")
        let receipts = realm.objects(ShareBookmarkApplicationReceipt.self)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(Set(receipts.map(\.canonicalPayload)),
                       Set([try first.canonicalPayload(), try second.canonicalPayload()]))
    }

    func testTextOnlyReplayPreservesSnippetIdentityAndCreation() async throws {
        let (configuration, realm) = try await makeRealm()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let request = Request(inputURL: nil, inputText: "First paragraph\n\nSecond paragraph", inputTitle: nil)
        try await save(request, context: context)
        let bookmark = try XCTUnwrap(realm.objects(Bookmark.self).first)
        let key = bookmark.compoundKey
        let url = bookmark.url
        let creation = bookmark.createdAt
        let html = bookmark.html
        let journal = journalState(in: realm)
        XCTAssertTrue(bookmark.isFromClipboard)
        XCTAssertTrue(bookmark.rssContainsFullContent)
        XCTAssertEqual(url, ReaderContentLoader.snippetURL(key: key))
        XCTAssertEqual(html, ReaderContentLoader.textToHTML(try XCTUnwrap(request.inputText)))
        try await save(request, context: context)
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        XCTAssertEqual(bookmark.compoundKey, key)
        XCTAssertEqual(bookmark.url, url)
        XCTAssertEqual(bookmark.createdAt, creation)
        XCTAssertEqual(bookmark.html, html)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    func testFailureBeforeCommitRollsBackNewBookmarkReceiptAndJournalThenRetries() async throws {
        let (configuration, realm) = try await makeRealm()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let request = Request()
        do {
            try await BookmarkInboxImportObservation.$beforeCommit.withValue({ @RealmBackgroundActor in
                XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
                XCTAssertEqual(realm.objects(ShareBookmarkApplicationReceipt.self).count, 1)
                XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
                throw TestFailure.beforeCommit
            }) {
                try await save(request, context: context)
            }
            XCTFail("Expected the real import transaction to roll back")
        } catch TestFailure.beforeCommit { }
        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(realm.objects(ShareBookmarkApplicationReceipt.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        try await save(request, context: context)
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        XCTAssertEqual(realm.objects(ShareBookmarkApplicationReceipt.self).count, 1)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
    }

    func testFailureBeforeCommitRestoresExistingBookmarkAndJournal() async throws {
        let (configuration, realm) = try await makeRealm()
        let request = Request()
        let bookmark = try await Bookmark.add(
            url: request.inputURL, title: "Existing title", isFromClipboard: false,
            rssContainsFullContent: false, isReaderModeByDefault: false,
            isReaderModeAvailable: false, isReaderModeOfferHidden: false,
            realmConfiguration: configuration
        )
        let creation = bookmark.createdAt
        let journal = journalState(in: realm)
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        do {
            try await BookmarkInboxImportObservation.$beforeCommit.withValue({ @RealmBackgroundActor in
                XCTAssertEqual(bookmark.title, request.inputTitle)
                throw TestFailure.beforeCommit
            }) {
                try await save(request, context: context)
            }
            XCTFail("Expected rollback after the existing row was updated")
        } catch TestFailure.beforeCommit { }
        XCTAssertEqual(bookmark.title, "Existing title")
        XCTAssertFalse(bookmark.isReaderModeByDefault)
        XCTAssertEqual(bookmark.createdAt, creation)
        XCTAssertTrue(realm.objects(ShareBookmarkApplicationReceipt.self).isEmpty)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    func testCancellingAQueuedRequestPreservesTheOtherWriteAndCanRetry() async throws {
        let (configuration, realm) = try await makeRealm()
        let request = Request()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        try realm.beginWrite()
        let peer = Bookmark()
        peer.url = try XCTUnwrap(request.inputURL)
        peer.updateCompoundKey()
        peer.title = "Uncommitted peer edit"
        realm.add(peer)
        let submitted = expectation(description: "Inbox request submitted behind peer write")
        let settled = expectation(description: "Cancelled inbox request settled")
        let writer = Task { @RealmBackgroundActor in
            defer { settled.fulfill() }
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await self.save(request, context: context)
            }
        }
        addTeardownBlock { @RealmBackgroundActor in
            writer.cancel()
            if realm.isInWriteTransaction { realm.cancelWrite() }
            _ = await writer.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        writer.cancel()
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertTrue(realm.isInWriteTransaction)
        XCTAssertFalse(peer.isInvalidated)
        if !peer.isInvalidated {
            XCTAssertEqual(peer.title, "Uncommitted peer edit")
        }
        XCTAssertTrue(realm.objects(ShareBookmarkApplicationReceipt.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        // Release the foreign writer before joining even when cancellation
        // regresses; a timeout must fail the test without blocking cleanup.
        if realm.isInWriteTransaction { realm.cancelWrite() }
        do {
            try await writer.value
            XCTFail("Expected queued request cancellation")
        } catch is CancellationError { }
        try await save(request, context: context)
        XCTAssertEqual(realm.objects(Bookmark.self).first?.title, request.inputTitle)
        XCTAssertEqual(realm.objects(ShareBookmarkApplicationReceipt.self).count, 1)
    }

    func testConcurrentSamePayloadRequestsApplyOnlyOnceAfterAdmission() async throws {
        let (configuration, realm) = try await makeRealm()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let request = Request()
        let applications = ApplicationCount()
        let submitted = expectation(description: "Both requests submitted before the peer releases its write")
        submitted.expectedFulfillmentCount = 2
        try realm.beginWrite()
        func makeWriter() -> Task<Void, Error> {
            Task { @RealmBackgroundActor in
                try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    try await BookmarkInboxImportObservation.$beforeCommit.withValue({ @RealmBackgroundActor in
                        applications.value += 1
                    }) {
                        try await self.save(request, context: context)
                    }
                }
            }
        }
        let first = makeWriter()
        let second = makeWriter()
        addTeardownBlock { @RealmBackgroundActor in
            first.cancel()
            second.cancel()
            if realm.isInWriteTransaction { realm.cancelWrite() }
            _ = await first.result
            _ = await second.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        try realm.commitWrite()
        try await first.value
        try await second.value
        XCTAssertEqual(applications.value, 1)
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        XCTAssertEqual(realm.objects(ShareBookmarkApplicationReceipt.self).count, 1)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
    }

    func testCancellationAfterCommitSubmissionReturnsDurableSuccess() async throws {
        let (configuration, realm) = try await makeRealm()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let request = Request()
        let writer = Task { @RealmBackgroundActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await self.save(request, context: context)
            }
            return Task.isCancelled
        }
        let cancelledAfterSubmission = try await writer.value
        XCTAssertTrue(cancelledAfterSubmission)
        XCTAssertEqual(realm.objects(Bookmark.self).count, 1)
        XCTAssertEqual(realm.objects(ShareBookmarkApplicationReceipt.self).count, 1)
        let journal = journalState(in: realm)
        XCTAssertEqual(journal.count, 1)
        try await save(request, context: context)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    func testFirstCreatedStoreUsesTheSameContextForWarmupAndSaveAndReceiptSurvivesReopen() async throws {
        let configuration = try makeFileConfiguration()
        let request = Request()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
        let key = try await saveThenReleaseFileRealm(request, configuration: configuration)

        let reopened = try await Realm(configuration: configuration, actor: RealmBackgroundActor.shared)
        let bookmark = try XCTUnwrap(reopened.object(ofType: Bookmark.self, forPrimaryKey: key))
        let originalCreation = bookmark.createdAt
        try reopened.write {
            bookmark.title = "Edited after reopening"
            bookmark.isDeleted = true
            bookmark.refreshChangeMetadata(explicitlyModified: true)
        }
        let journal = journalState(in: reopened)
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        try await save(request, context: context)
        await reopened.asyncRefresh()
        XCTAssertEqual(bookmark.title, "Edited after reopening")
        XCTAssertTrue(bookmark.isDeleted)
        XCTAssertEqual(bookmark.createdAt, originalCreation)
        XCTAssertEqual(reopened.objects(ShareBookmarkApplicationReceipt.self).count, 1)
        XCTAssertEqual(journalState(in: reopened), journal)
    }

    func testOriginalContextRejectsReplacementBeforeOpeningAndLeavesBothStoresUntouched() async throws {
        let configuration = try makeFileConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let replacement = try replaceFileWithCopy(of: realm, configuration: configuration)
        let request = Request()
        do {
            try await save(request, context: context)
            XCTFail("An original-store context must reject the replacement")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(realm.objects(ShareBookmarkApplicationReceipt.self).isEmpty)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(configuration.fileURL)), replacement)
    }

    func testQueuedRequestRechecksOriginalFileIdentityAtWriteAdmission() async throws {
        let configuration = try makeFileConfiguration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let fileURL = try XCTUnwrap(configuration.fileURL)
        let replacementURL = fileURL.deletingLastPathComponent().appendingPathComponent("replacement.realm")
        try realm.writeCopy(toFile: replacementURL)
        let replacementBytes = try Data(contentsOf: replacementURL)
        let request = Request()
        let submitted = expectation(description: "Request captured the original Realm and queued its write")
        try realm.beginWrite()
        let writer = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await self.save(request, context: context)
            }
        }
        addTeardownBlock { @RealmBackgroundActor in
            writer.cancel()
            if realm.isInWriteTransaction { realm.cancelWrite() }
            _ = await writer.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        try FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("retired"))
        try FileManager.default.moveItem(at: replacementURL, to: fileURL)
        try realm.commitWrite()
        do {
            try await writer.value
            XCTFail("Queued work must not use a replaced source store")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        XCTAssertTrue(realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(realm.objects(ShareBookmarkApplicationReceipt.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), replacementBytes)
    }

    func testFullPayloadMismatchNeverCountsAsAReplay() async throws {
        let (configuration, realm) = try await makeRealm()
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        let request = Request()
        try await save(request, context: context)
        let receipt = try XCTUnwrap(realm.objects(ShareBookmarkApplicationReceipt.self).first)
        let alteredPayload = Data("different payload under the same digest".utf8)
        try realm.write { receipt.canonicalPayload = alteredPayload }
        let journal = journalState(in: realm)
        do {
            try await save(request, context: context)
            XCTFail("The full original bytes must match before returning replay success")
        } catch BookmarkInboxImportError.payloadDigestCollision { }
        XCTAssertEqual(receipt.canonicalPayload, alteredPayload)
        XCTAssertEqual(realm.objects(Bookmark.self).first?.title, request.inputTitle)
        XCTAssertEqual(journalState(in: realm), journal)
    }

    func testMismatchedExplicitSchemaFailsBeforeCreatingAStore() async throws {
        var configuration = try makeFileConfiguration()
        configuration.objectTypes = [Bookmark.self, BigSyncPendingMutation.self]
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        do {
            try await context.prepareStorage()
            XCTFail("The paired receipt schema is required")
        } catch BookmarkInboxImportError.incompatibleSchema { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
    }

    private func save(_ request: Request, context: BookmarkInboxImportContext) async throws {
        try await ReaderContentLoader.saveInboxBookmark(
            inputURL: request.inputURL,
            inputText: request.inputText,
            inputTitle: request.inputTitle,
            isReaderModeByDefault: request.isReaderModeByDefault,
            canonicalPayload: request.canonicalPayload(),
            context: context
        )
    }

    private func makeRealm() async throws -> (Realm.Configuration, Realm) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configure(&configuration)
        let captured = configuration
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        return (configuration, realm)
    }

    private func makeFileConfiguration() throws -> Realm.Configuration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Realm.Configuration(fileURL: directory.appendingPathComponent("reader.realm"))
        configure(&configuration)
        let captured = configuration
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: captured)
            try? FileManager.default.removeItem(at: directory)
        }
        return configuration
    }

    private func configure(_ configuration: inout Realm.Configuration) {
        configuration.objectTypes = [Bookmark.self, ShareBookmarkApplicationReceipt.self, BigSyncPendingMutation.self]
        BigSyncMutationTracking.install(
            configurations: [configuration],
            excludedClassNames: [ShareBookmarkApplicationReceipt.className()]
        )
    }

    private func saveThenReleaseFileRealm(_ request: Request, configuration: Realm.Configuration) async throws -> String {
        let context = BookmarkInboxImportContext(realmConfiguration: configuration)
        try await context.prepareStorage()
        try context.validateCurrentStorage()
        try await save(request, context: context)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let key = try XCTUnwrap(realm.objects(ShareBookmarkApplicationReceipt.self).first?.bookmarkID)
        _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        return key
    }

    private func replaceFileWithCopy(of realm: Realm, configuration: Realm.Configuration) throws -> Data {
        let fileURL = try XCTUnwrap(configuration.fileURL)
        let replacementURL = fileURL.deletingLastPathComponent().appendingPathComponent("replacement.realm")
        try realm.writeCopy(toFile: replacementURL)
        let bytes = try Data(contentsOf: replacementURL)
        try FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("retired"))
        try FileManager.default.moveItem(at: replacementURL, to: fileURL)
        return bytes
    }

    private func journalState(in realm: Realm) -> [String: JournalState] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, JournalState(generation: $0.generation, changedAt: $0.changedAt))
        })
    }
}
