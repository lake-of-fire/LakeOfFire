import BigSyncKit
import Foundation
import RealmSwift
import XCTest
@testable import RealmSwiftGaps
@testable import SwiftUIWebView
@testable import LakeOfFireContent
@testable import LakeOfFireReader

private actor PageMetadataGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait(registered: @Sendable () -> Void) async {
        if released { registered(); return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            registered()
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor PageMetadataScriptRecorder {
    private(set) var titles: [String] = []
    func append(_ title: String) { titles.append(title) }
}

@MainActor
final class ReaderPageMetadataUpdateTests: XCTestCase {
    private struct Fixture {
        let configuration: Realm.Configuration
        let realm: Realm
        let bookmark: Bookmark
        let model: ReaderViewModel
        let url: URL
    }

    private struct Journal: Equatable {
        let generation: String
        let changedAt: Date
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }

    private func fixture(url: URL? = nil, fileURL: URL? = nil) throws -> Fixture {
        let url = url ?? URL(string: "https://example.test/title/\(UUID().uuidString)")!
        var configuration = fileURL.map { Realm.Configuration(fileURL: $0) }
            ?? Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self, ContentFile.self, Feed.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let oldBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let oldHistory = ReaderContentLoader.historyRealmConfiguration
        let oldFeed = ReaderContentLoader.feedEntryRealmConfiguration
        let oldProviders = ReaderContentLoader.additionalContentProviders
        let oldResolver = ReaderContent.contentResolver
        let captured = configuration
        addTeardownBlock { @MainActor in
            ReaderContentLoader.bookmarkRealmConfiguration = oldBookmark
            ReaderContentLoader.historyRealmConfiguration = oldHistory
            ReaderContentLoader.feedEntryRealmConfiguration = oldFeed
            ReaderContentLoader.additionalContentProviders = oldProviders
            ReaderContent.contentResolver = oldResolver
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: captured)
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.additionalContentProviders = []

        let realm = try Realm(configuration: configuration)
        let bookmark = Bookmark()
        bookmark.url = url
        bookmark.title = "Original title"
        bookmark.author = "Stored author"
        bookmark.createdAt = Date(timeIntervalSinceReferenceDate: 100)
        bookmark.updateCompoundKey()
        try realm.write {
            realm.add(bookmark)
            bookmark.refreshChangeMetadata(explicitlyModified: true)
        }
        let model = ReaderViewModel(realmConfiguration: configuration, systemScripts: [],
                                    observeLibraryChanges: false)
        model.state.pageURL = url
        model.state.isLoading = false
        model.state.isProvisionallyNavigating = false
        return Fixture(configuration: configuration, realm: realm, bookmark: bookmark, model: model, url: url)
    }

    private func bind(_ caller: WebViewScriptCaller, recorder: PageMetadataScriptRecorder? = nil) {
        caller.installBinding(
            ownedBy: UUID(),
            asyncCaller: { _, arguments, _, _ in
                if let title = arguments?["title"] as? String { await recorder?.append(title) }
                return .init(nil)
            },
            unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil }
        )
    }

    private func admission(_ f: Fixture) throws -> ReaderDocumentMutationAdmission {
        try XCTUnwrap(ReaderDocumentMutationAdmission.capture(
            targetURL: f.url, requiring: f.model.scriptCaller.currentJavaScriptBindingToken,
            scriptCaller: f.model.scriptCaller
        ))
    }

    private func journal(_ object: Object & ChangeMetadataRecordable, in realm: Realm) throws -> Journal {
        let key = try XCTUnwrap(object.objectSchema.primaryKeyProperty?.name)
        let identifier = String(describing: try XCTUnwrap(object[key]))
        let pending = try XCTUnwrap(realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: object.objectSchema.className + "." + identifier
        ))
        XCTAssertEqual(pending.changedAt, object.modifiedAt)
        XCTAssertEqual(pending.changedAt, object.explicitlyModifiedAt)
        return Journal(generation: pending.generation, changedAt: pending.changedAt,
                       modifiedAt: object.modifiedAt, explicitlyModifiedAt: object.explicitlyModifiedAt)
    }

    private func holdDiscovery(_ gate: PageMetadataGate, entered: XCTestExpectation) {
        ReaderContentLoader.additionalContentProviders = [
            ReaderContentAdditionalProvider(id: "page-metadata-\(UUID().uuidString)", load: { _ in
                await gate.wait { entered.fulfill() }
                return []
            })
        ]
    }

    private func retainForCleanup<T: Sendable>(_ task: Task<T, Error>, gate: PageMetadataGate) {
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
    }

    func testActualTitlePayloadDistinguishesAbsentExplicitAndMalformedAuthor() throws {
        let url = "https://example.test/article"
        let partial = try XCTUnwrap(PageMetadataUpdatedMessage(body: ["title": "Updated", "url": url]))
        XCTAssertEqual(partial.title, "Updated")
        XCTAssertEqual(partial.url?.absoluteString, url)
        XCTAssertNil(partial.author)
        for author in ["Author", ""] {
            let full = try XCTUnwrap(PageMetadataUpdatedMessage(
                body: ["title": "Updated", "author": author, "url": url]
            ))
            XCTAssertEqual(full.author, author)
        }
        for malformed in [NSNull(), 7, true, ["nested"]] as [Any] {
            XCTAssertNil(PageMetadataUpdatedMessage(
                body: ["title": "Updated", "author": malformed, "url": url]
            ))
        }
    }

    func testMalformedRequiredFieldsAreRejectedWithoutForceCastingURL() {
        for body in [
            ["title": "Updated"],
            ["title": "Updated", "url": NSNull()],
            ["title": "Updated", "url": 42],
            ["title": 42, "url": "https://example.test/article"],
            ["url": "https://example.test/article"],
        ] as [[String: Any]] {
            XCTAssertNil(PageMetadataUpdatedMessage(body: body))
        }
        XCTAssertNil(PageMetadataUpdatedMessage(body: nil))
        XCTAssertNil(PageMetadataUpdatedMessage(body: []))
    }

    func testDecodedTitleUpdateReachesActualNativeWriterAndPreservesAuthor() async throws {
        let f = try fixture()
        let recorder = PageMetadataScriptRecorder()
        bind(f.model.scriptCaller, recorder: recorder)
        try f.realm.write {
            f.bookmark.rssContainsFullContent = true
            f.bookmark.refreshChangeMetadata(explicitlyModified: true)
        }
        let message = try XCTUnwrap(PageMetadataUpdatedMessage(
            body: ["title": "Current complete title", "url": f.url.absoluteString]
        ))
        let admitted = try admission(f)
        let before = try journal(f.bookmark, in: f.realm)
        try await f.model.pageMetadataUpdated(title: message.title, author: message.author, admission: admitted)
        f.realm.refresh()
        XCTAssertEqual(f.bookmark.title, "Current complete title")
        XCTAssertEqual(f.bookmark.author, "Stored author")
        XCTAssertNotEqual(try journal(f.bookmark, in: f.realm).generation, before.generation)
        let titles = await recorder.titles
        XCTAssertEqual(titles, ["Current complete title"])
        let settled = try journal(f.bookmark, in: f.realm)
        try await f.model.pageMetadataUpdated(title: message.title, author: message.author, admission: admitted)
        f.realm.refresh()
        XCTAssertEqual(try journal(f.bookmark, in: f.realm), settled)
        let repeatedTitles = await recorder.titles
        XCTAssertEqual(repeatedTitles, titles)
    }

    func testExplicitAuthorChangeAndClearRemainAuthoritative() async throws {
        let f = try fixture()
        for author in ["New author", ""] {
            let message = try XCTUnwrap(PageMetadataUpdatedMessage(
                body: ["title": "Original title", "author": author, "url": f.url.absoluteString]
            ))
            let before = try journal(f.bookmark, in: f.realm)
            try await f.model.pageMetadataUpdated(title: message.title, author: message.author)
            f.realm.refresh()
            XCTAssertEqual(f.bookmark.author, author)
            XCTAssertEqual(f.bookmark.title, "Original title")
            XCTAssertNotEqual(try journal(f.bookmark, in: f.realm).generation, before.generation)
        }
        let settled = try journal(f.bookmark, in: f.realm)
        try await f.model.pageMetadataUpdated(title: "Original title", author: "")
        f.realm.refresh()
        XCTAssertEqual(try journal(f.bookmark, in: f.realm), settled)
    }

    func testNativeTitleCallbackRetainsPublicAPIAndAuthor() async throws {
        let f = try fixture()
        try await f.model.pageMetadataUpdated(title: "Native page title")
        f.realm.refresh()
        XCTAssertEqual(f.bookmark.title, "Native page title")
        XCTAssertEqual(f.bookmark.author, "Stored author")
    }

    func testPartialTitlePreservesConcurrentAuthorAtQueuedWriteAdmission() async throws {
        let f = try fixture()
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: f.bookmark))
        let message = try XCTUnwrap(PageMetadataUpdatedMessage(
            body: ["title": "Incoming title", "url": f.url.absoluteString]
        ))
        let title = message.title
        let author = message.author
        let configuration = f.configuration
        let key = f.bookmark.compoundKey
        let gate = PageMetadataGate()
        let entered = expectation(description: "concurrent author edit owns its transaction")
        let owner = Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try realm.beginWrite()
            defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
            let record = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: key))
            record.author = "Concurrent author"
            record.refreshChangeMetadata(explicitlyModified: true)
            let timestamp = record.modifiedAt
            await gate.wait { entered.fulfill() }
            try realm.commitWrite()
            return timestamp
        }
        retainForCleanup(owner, gate: gate)
        await fulfillment(of: [entered], timeout: 2)
        let submitted = expectation(description: "metadata has its own queued SDK write ticket")
        let update = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await reference.writePageMetadata(title: title, author: author, isAdmitted: { true })
            }
        }
        retainForCleanup(update, gate: gate)
        await fulfillment(of: [submitted], timeout: 2)
        await gate.release()
        let priorTimestamp = try await owner.value
        let result = try await update.value
        f.realm.refresh()
        XCTAssertEqual(result?.changed, true)
        XCTAssertEqual(f.bookmark.title, "Incoming title")
        XCTAssertEqual(f.bookmark.author, "Concurrent author")
        XCTAssertGreaterThanOrEqual(try journal(f.bookmark, in: f.realm).changedAt, priorTimestamp)
    }

    func testSameURLBindingReplacementRejectsSuspendedNativeMetadata() async throws {
        let f = try fixture()
        bind(f.model.scriptCaller)
        let admitted = try admission(f)
        let gate = PageMetadataGate()
        let entered = expectation(description: "original document discovery suspended")
        holdDiscovery(gate, entered: entered)
        let before = try journal(f.bookmark, in: f.realm)
        let task = Task { @MainActor in
            try await f.model.pageMetadataUpdated(title: "Obsolete", author: "Obsolete author", admission: admitted)
        }
        retainForCleanup(task, gate: gate)
        await fulfillment(of: [entered], timeout: 2)
        bind(f.model.scriptCaller)
        await gate.release()
        try await task.value
        f.realm.refresh()
        XCTAssertEqual(f.bookmark.title, "Original title")
        XCTAssertEqual(f.bookmark.author, "Stored author")
        XCTAssertEqual(try journal(f.bookmark, in: f.realm), before)
    }

    func testCancelledDiscoveryDoesNotWriteOrJournal() async throws {
        let f = try fixture()
        let gate = PageMetadataGate()
        let entered = expectation(description: "metadata discovery registered continuation")
        holdDiscovery(gate, entered: entered)
        let before = try journal(f.bookmark, in: f.realm)
        let task = Task { @MainActor in try await f.model.pageMetadataUpdated(title: "Cancelled") }
        retainForCleanup(task, gate: gate)
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await gate.release()
        do { try await task.value } catch is CancellationError { }
        f.realm.refresh()
        XCTAssertEqual(f.bookmark.title, "Original title")
        XCTAssertEqual(try journal(f.bookmark, in: f.realm), before)
    }

    func testNavigationDuringDiscoveryCannotPublishTheOldTitleIntoCurrentReader() async throws {
        let f = try fixture()
        let gate = PageMetadataGate()
        let entered = expectation(description: "metadata discovery held before navigation")
        holdDiscovery(gate, entered: entered)
        let before = try journal(f.bookmark, in: f.realm)
        let task = Task { @MainActor in try await f.model.pageMetadataUpdated(title: "Old document") }
        retainForCleanup(task, gate: gate)
        await fulfillment(of: [entered], timeout: 2)
        f.model.state.pageURL = URL(string: "https://example.test/successor")!
        await gate.release()
        try await task.value
        f.realm.refresh()
        XCTAssertEqual(f.bookmark.title, "Original title")
        XCTAssertEqual(try journal(f.bookmark, in: f.realm), before)
    }

    func testDiscoveryKeepsOriginalStoresWhenGlobalsChange() async throws {
        let original = try fixture()
        let gate = PageMetadataGate()
        let entered = expectation(description: "original discovery stores and providers captured")
        holdDiscovery(gate, entered: entered)
        let task = Task { @MainActor in try await original.model.pageMetadataUpdated(title: "Original store title") }
        retainForCleanup(task, gate: gate)
        await fulfillment(of: [entered], timeout: 2)
        let successor = try fixture(url: original.url)
        let successorBefore = try journal(successor.bookmark, in: successor.realm)
        await gate.release()
        try await task.value
        original.realm.refresh()
        successor.realm.refresh()
        XCTAssertEqual(original.bookmark.title, "Original store title")
        XCTAssertEqual(original.bookmark.author, "Stored author")
        XCTAssertEqual(successor.bookmark.title, "Original title")
        XCTAssertEqual(try journal(successor.bookmark, in: successor.realm), successorBefore)
    }

    func testDiscoveryCannotAdoptRecreatedSameKeyRecord() async throws {
        let f = try fixture()
        let gate = PageMetadataGate()
        let entered = expectation(description: "original record reference captured before provider wait")
        holdDiscovery(gate, entered: entered)
        let key = f.bookmark.compoundKey
        let createdAt = f.bookmark.createdAt
        let task = Task { @MainActor in try await f.model.pageMetadataUpdated(title: "Retired record") }
        retainForCleanup(task, gate: gate)
        await fulfillment(of: [entered], timeout: 2)
        let replacement = Bookmark()
        replacement.url = f.url
        replacement.title = "Replacement title"
        replacement.author = "Replacement author"
        replacement.createdAt = createdAt.addingTimeInterval(1)
        replacement.updateCompoundKey()
        XCTAssertEqual(replacement.compoundKey, key)
        try f.realm.write {
            f.realm.delete(f.bookmark) // Model acknowledged cleanup and a different creation.
            f.realm.add(replacement)
            replacement.refreshChangeMetadata(explicitlyModified: true)
        }
        let before = try journal(replacement, in: f.realm)
        await gate.release()
        try await task.value
        f.realm.refresh()
        XCTAssertEqual(replacement.title, "Replacement title")
        XCTAssertEqual(replacement.author, "Replacement author")
        XCTAssertEqual(try journal(replacement, in: f.realm), before)
    }

    func testExistingTombstoneIsPreservedDuringNativeDiscovery() async throws {
        let f = try fixture()
        let gate = PageMetadataGate()
        let entered = expectation(description: "metadata target captured before deletion")
        holdDiscovery(gate, entered: entered)
        let task = Task { @MainActor in try await f.model.pageMetadataUpdated(title: "Retired title") }
        retainForCleanup(task, gate: gate)
        await fulfillment(of: [entered], timeout: 2)
        try f.realm.write {
            f.bookmark.isDeleted = true
            f.bookmark.refreshChangeMetadata(explicitlyModified: true)
        }
        let tombstone = try journal(f.bookmark, in: f.realm)
        await gate.release()
        try await task.value
        f.realm.refresh()
        XCTAssertTrue(f.bookmark.isDeleted)
        XCTAssertEqual(f.bookmark.title, "Original title")
        XCTAssertEqual(try journal(f.bookmark, in: f.realm), tombstone)
    }

    func testRejectedWriteCanRetryWithoutClearingAuthorOrPartialJournal() async throws {
        let f = try fixture()
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: f.bookmark))
        let before = try journal(f.bookmark, in: f.realm)
        let rejected = try await reference.writePageMetadata(title: "Retry title", author: nil, isAdmitted: { false })
        f.realm.refresh()
        XCTAssertNil(rejected)
        XCTAssertEqual(try journal(f.bookmark, in: f.realm), before)
        let accepted = try await reference.writePageMetadata(title: "Retry title", author: nil, isAdmitted: { true })
        f.realm.refresh()
        XCTAssertEqual(accepted?.changed, true)
        XCTAssertEqual(f.bookmark.title, "Retry title")
        XCTAssertEqual(f.bookmark.author, "Stored author")
    }

    func testQueuedCancellationPreservesAnotherOwnersTransaction() async throws {
        let f = try fixture()
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: f.bookmark))
        let configuration = f.configuration
        let key = f.bookmark.compoundKey
        let gate = PageMetadataGate()
        let entered = expectation(description: "another owner holds the Realm transaction")
        let owner = Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try realm.beginWrite()
            defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
            let record = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: key))
            record.author = "Other owner's author"
            record.refreshChangeMetadata(explicitlyModified: true)
            await gate.wait { entered.fulfill() }
            try realm.commitWrite()
        }
        retainForCleanup(owner, gate: gate)
        await fulfillment(of: [entered], timeout: 2)
        let submitted = expectation(description: "metadata ticket submitted behind the owner")
        let update = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await reference.writePageMetadata(title: "Cancelled", author: nil, isAdmitted: { true })
            }
        }
        retainForCleanup(update, gate: gate)
        await fulfillment(of: [submitted], timeout: 2)
        update.cancel()
        do { _ = try await update.value; XCTFail("Queued metadata must cancel before admission") }
        catch is CancellationError { }
        let intact = try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            return realm.isInWriteTransaction
                && realm.object(ofType: Bookmark.self, forPrimaryKey: key)?.author == "Other owner's author"
        }.value
        XCTAssertTrue(intact)
        await gate.release()
        try await owner.value
        f.realm.refresh()
        XCTAssertEqual(f.bookmark.title, "Original title")
        XCTAssertEqual(f.bookmark.author, "Other owner's author")
    }

    func testPostCommitCancellationKeepsDurableMetadataAndNoOpRetry() async throws {
        let f = try fixture()
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: f.bookmark))
        let task = Task { @RealmBackgroundActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await reference.writePageMetadata(title: "Committed title", author: nil, isAdmitted: { true })
            }
        }
        let result = try await task.value
        f.realm.refresh()
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(result?.changed, true)
        XCTAssertEqual(f.bookmark.title, "Committed title")
        XCTAssertEqual(f.bookmark.author, "Stored author")
        let settled = try journal(f.bookmark, in: f.realm)
        let repeated = try await reference.writePageMetadata(title: "Committed title", author: nil, isAdmitted: { true })
        f.realm.refresh()
        XCTAssertEqual(repeated?.changed, false)
        XCTAssertEqual(try journal(f.bookmark, in: f.realm), settled)
    }

    func testCapturedReferenceRejectsSamePathStoreReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("current.realm")
        addTeardownBlock {
            let released = await Self.releaseDiskRealms(at: url)
            if released { try FileManager.default.removeItem(at: directory) }
        }
        let f = try fixture(fileURL: url)
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: f.bookmark))
        let original = try journal(f.bookmark, in: f.realm)
        let replacement = directory.appendingPathComponent("replacement.realm")
        try f.realm.writeCopy(toFile: replacement)
        let bytes = try Data(contentsOf: replacement)
        try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("retired.realm"))
        try FileManager.default.moveItem(at: replacement, to: url)
        do {
            _ = try await reference.writePageMetadata(title: "Wrong store", author: nil, isAdmitted: { true })
            XCTFail("The original reference must not admit a replacement file")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        f.realm.refresh()
        XCTAssertEqual(f.bookmark.title, "Original title")
        XCTAssertEqual(try journal(f.bookmark, in: f.realm), original)
    }

    @RealmBackgroundActor
    private static func releaseDiskRealms(at fileURL: URL) -> Bool {
        let owner = RealmBackgroundActor.shared
        let matches = owner.cachedRealms.filter {
            $0.value.configuration.fileURL?.standardizedFileURL == fileURL.standardizedFileURL
        }
        guard matches.values.allSatisfy({ !$0.isInWriteTransaction }) else {
            XCTFail("Disk teardown must not cancel another writer")
            return false
        }
        for key in matches.keys { owner.cachedRealms.removeValue(forKey: key)?.invalidate() }
        return true
    }

    func testMetadataUpdatesSameKeyModelsWithoutSharingAuthorValues() async throws {
        let f = try fixture()
        let history = HistoryRecord()
        history.url = f.url
        history.title = "History original"
        history.author = "History author"
        history.createdAt = f.bookmark.createdAt
        history.updateCompoundKey()
        XCTAssertEqual(history.compoundKey, f.bookmark.compoundKey)
        try f.realm.write {
            f.realm.add(history)
            history.refreshChangeMetadata(explicitlyModified: true)
        }
        try await f.model.pageMetadataUpdated(title: "Shared current title")
        f.realm.refresh()
        XCTAssertEqual(f.bookmark.title, "Shared current title")
        XCTAssertEqual(history.title, "Shared current title")
        XCTAssertEqual(f.bookmark.author, "Stored author")
        XCTAssertEqual(history.author, "History author")
        _ = try journal(history, in: f.realm)
        _ = try journal(f.bookmark, in: f.realm)
    }

    func testExistingTitleAndClipboardNormalizationRemainInTheActualWriter() async throws {
        let f = try fixture()
        try f.realm.write { f.bookmark.isFromClipboard = true }
        try await f.model.pageMetadataUpdated(title: "\u{fffc}📎 Clean title")
        f.realm.refresh()
        XCTAssertEqual(f.bookmark.title, "Clean title")
        XCTAssertEqual(f.bookmark.author, "Stored author")
        let settled = try journal(f.bookmark, in: f.realm)
        try await f.model.pageMetadataUpdated(title: nil, author: "Ignored without title")
        try await f.model.pageMetadataUpdated(title: "", author: "Ignored without title")
        f.realm.refresh()
        XCTAssertEqual(f.bookmark.author, "Stored author")
        XCTAssertEqual(try journal(f.bookmark, in: f.realm), settled)
    }

    func testTopLevelAndExactBindingAdmissionRejectsForeignOrUnreceiptedMessages() throws {
        let f = try fixture()
        bind(f.model.scriptCaller)
        XCTAssertTrue(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: f.url, frameMainDocumentURL: f.url, currentPageURL: f.url,
            requiresMainFrame: true, isMainFrame: true
        ))
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: f.url, frameMainDocumentURL: f.url, currentPageURL: f.url,
            requiresMainFrame: true, isMainFrame: false
        ))
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: URL(string: "https://example.test/other"), frameMainDocumentURL: f.url,
            currentPageURL: f.url, requiresMainFrame: true, isMainFrame: true
        ))
        XCTAssertNil(ReaderDocumentMutationAdmission.capture(
            targetURL: f.url, requiring: nil, scriptCaller: f.model.scriptCaller
        ))
        let other = WebViewScriptCaller()
        bind(other)
        XCTAssertNil(ReaderDocumentMutationAdmission.capture(
            targetURL: f.url, requiring: other.currentJavaScriptBindingToken, scriptCaller: f.model.scriptCaller
        ))
    }
}
