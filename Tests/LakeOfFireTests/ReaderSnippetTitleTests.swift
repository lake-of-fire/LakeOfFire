import XCTest
import BigSyncKit
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent
@testable import LakeOfFireReader
import SwiftUIWebView

final class ReaderSnippetTitleTests: XCTestCase {
    private func makeRealmConfiguration(name: String = UUID().uuidString) -> Realm.Configuration {
        let realmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("realm")
        var configuration = Realm.Configuration(fileURL: realmURL)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self, Feed.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let fixtureConfiguration = configuration
        addTeardownBlock {
            let released = await RealmBackgroundActor.shared.releaseSnippetTitleFixture(fixtureConfiguration)
            XCTAssertTrue(released, "Snippet fixture writers must finish before file cleanup")
            guard released else { return }
            let sidecarExtensions = ["realm", "realm.lock", "realm.management", "realm.note"]
            for ext in sidecarExtensions {
                try? FileManager.default.removeItem(
                    at: realmURL.deletingPathExtension().appendingPathExtension(ext)
                )
            }
        }
        return configuration
    }

    private func snippetHTML(token: String = "") -> String {
        ReaderContentLoader.snippetHTML(fromRawText: """
        Updated via Snippet Helper

        This snippet body gives the generated title enough content to truncate.

        - First bullet.
        - Second bullet.
        \(token)
        """)
    }

    private func updatedSnippetHTML(token: String = "") -> String {
        ReaderContentLoader.snippetHTML(fromRawText: """
        Updated after editing the snippet content

        The content changed, so the auto-generated title should change too.

        - Replacement bullet.
        - Another replacement bullet.
        \(token)
        """)
    }

    @MainActor
    private func withSnippetRealm<T>(
        _ body: @MainActor @escaping (Realm.Configuration) async throws -> T
    ) async throws -> T {
        let configuration = makeRealmConfiguration()
        let previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let previousFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeedConfiguration
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let result = try await body(configuration)
        await ReaderContentLoader.resetTransientCachesForTesting()
        return result
    }

    @MainActor
    func testRejectedSnippetReloadPreservesNewerRequestAndReaderMode() async throws {
        try await withSnippetRealm { _ in
            let result = try await ReaderContentLoader.load(html: "<p>Original snippet.</p>")
            let original = try XCTUnwrap(result)
            let navigator = WebViewNavigator()
            let destination = URL(string: "https://example.com/newer-request")!
            navigator.load(URLRequest(url: destination))
            let mode = ReaderModeViewModel()
            var admissionChecks = 0
            try await navigator.load(content: original, readerModeViewModel: mode, shouldLoad: {
                admissionChecks += 1
                return false
            })
            XCTAssertEqual(admissionChecks, 1)
            XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, destination.absoluteString)
            XCTAssertFalse(mode.isReaderModeLoading)
        }
    }

    @MainActor
    func testSuspendedOldSnippetLoadCannotChangeSuccessorReaderMode() async throws {
        let navigator = WebViewNavigator()
        let mode = ReaderModeViewModel()
        let original = HistoryRecord()
        original.url = URL(string: "https://example.com/original")!
        original.isReaderModeByDefault = true
        let successor = URL(string: "https://example.com/successor")!
        let entered = expectation(description: "Old resolution suspended")
        var continuation: CheckedContinuation<URL?, Never>?
        let task = Task { @MainActor in
            try await navigator.loadResolvedContent(
                content: original, readerModeViewModel: mode, shouldLoad: { true },
                resolveURL: {
                    await withCheckedContinuation {
                        continuation = $0
                        entered.fulfill()
                    }
                }
            )
        }
        await fulfillment(of: [entered], timeout: 3)
        navigator.load(URLRequest(url: successor))
        continuation?.resume(returning: original.url)
        try await task.value
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, successor.absoluteString)
        XCTAssertFalse(mode.isReaderModeLoading)
        XCTAssertNil(mode.lastRenderedURL)
    }

    @MainActor
    func testCurrentResolvedSnippetStillStartsReaderModeAndNavigates() async throws {
        let navigator = WebViewNavigator()
        let mode = ReaderModeViewModel()
        let content = HistoryRecord()
        content.url = URL(string: "https://example.com/current")!
        content.isReaderModeByDefault = true
        try await navigator.loadResolvedContent(
            content: content, readerModeViewModel: mode, shouldLoad: { true },
            resolveURL: { content.url }
        )
        XCTAssertTrue(mode.isReaderModeLoading)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, content.url.absoluteString)
    }

    @MainActor
    func testDelayedAppendUsesCapturedSnippetURLAfterAnotherSnippetLoads() async throws {
        try await withSnippetRealm { configuration in
            let firstResult = try await ReaderContentLoader.load(html: "<p>Original first snippet.</p>")
            let first = try XCTUnwrap(firstResult)
            let destinationURL = first.url
            let secondResult = try await ReaderContentLoader.load(html: "<p>Second snippet remains unchanged.</p>")
            let second = try XCTUnwrap(secondResult)
            XCTAssertNotEqual(destinationURL, second.url)
            let secondHTML = second.html

            let result = try await ReaderContentLoader.appendSnippetHTML(
                "<p>Delayed photo transcript.</p>", toContentURL: destinationURL
            )
            XCTAssertEqual(result?.url, destinationURL)
            XCTAssertTrue(result?.html?.contains("Delayed photo transcript.") == true)
            let reloadedSecond = try await ReaderContentLoader.load(
                url: second.url, persist: false, countsAsHistoryVisit: false,
                source: "ReaderSnippetTitleTests.destination"
            )
            XCTAssertEqual(reloadedSecond?.html, secondHTML)
        }
    }

    @MainActor
    func testLoadHTMLCreatesSnippetWithGeneratedTitleAndPrefixFlag() async throws {
        let snippetHTML = self.snippetHTML(token: "load-html")
        try await withSnippetRealm { _ in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let content = try XCTUnwrap(loadedContent)
            XCTAssertTrue(content.url.isSnippetURL)
            XCTAssertEqual(
                content.title,
                ReaderContentLoader.generatedSnippetTitle(fromSourceHTML: snippetHTML)
            )
            XCTAssertTrue(content.isTitlePrefixOfContent)
        }
    }

    @MainActor
    func testConcurrentSnippetLoadsKeepEachHistoryRecordAndMutationJournal() async throws {
        try await withSnippetRealm { configuration in
            let keys = try await withThrowingTaskGroup(of: String.self) { group in
                for index in 0..<12 {
                    group.addTask { @MainActor in
                        let content = try await ReaderContentLoader.load(
                            html: "<p>Concurrent startup snippet \(index)</p>",
                            allowContentMatch: false
                        )
                        return try XCTUnwrap(content).compoundKey
                    }
                }
                var keys = [String]()
                for try await key in group {
                    keys.append(key)
                }
                return keys
            }

            XCTAssertEqual(Set(keys).count, 12)
            let realm = try await Realm(configuration: configuration)
            try await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(HistoryRecord.self).count, 12)
            for key in keys {
                let record = try XCTUnwrap(
                    realm.object(ofType: HistoryRecord.self, forPrimaryKey: key)
                )
                let recordName = record.objectSchema.className + "." + key
                XCTAssertNotNil(
                    realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName),
                    "Missing mutation journal for \(key)"
                )
            }
        }
    }

    @MainActor
    func testUpdateSnippetContentAutoRetitlesGeneratedTitles() async throws {
        let snippetHTML = self.snippetHTML(token: "auto-retitle")
        let updatedSnippetHTML = self.updatedSnippetHTML(token: "auto-retitle")
        try await withSnippetRealm { _ in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let content = try XCTUnwrap(loadedContent)
            let originalURL = content.url

            let didUpdate = try await ReaderContentLoader.updateSnippetContent(
                contentURL: originalURL,
                title: content.title,
                html: updatedSnippetHTML
            )
            XCTAssertTrue(didUpdate)

            let reloaded = try await ReaderContentLoader.load(
                url: originalURL,
                persist: false,
                countsAsHistoryVisit: false
            )
            let reloadedContent = try XCTUnwrap(reloaded)
            XCTAssertEqual(
                reloadedContent.title,
                ReaderContentLoader.generatedSnippetTitle(fromSourceHTML: updatedSnippetHTML)
            )
            XCTAssertTrue(reloadedContent.isTitlePrefixOfContent)
        }
    }

    @MainActor
    func testCapturedSnippetStorageUpdatesBookmarkAndHistoryAfterGlobalReplacement() async throws {
        try await withSnippetRealm { originalConfiguration in
            let loaded = try await ReaderContentLoader.load(html: self.snippetHTML(token: "captured-storage"))
            let snippet = try XCTUnwrap(loaded)
            let snippetURL = snippet.url
            try await snippet.addBookmark(realmConfiguration: originalConfiguration)
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: originalConfiguration
                )
                let secondHistory = HistoryRecord()
                secondHistory.compoundKey = UUID().uuidString
                secondHistory.url = snippetURL
                secondHistory.title = "Second history representation"
                secondHistory.html = "<p>Old duplicate body.</p>"
                try await realm.asyncWrite {
                    realm.add(secondHistory)
                    secondHistory.refreshChangeMetadata(explicitlyModified: true)
                }
            }()
            let replacementConfiguration = self.makeRealmConfiguration()
            ReaderContentLoader.bookmarkRealmConfiguration = replacementConfiguration
            ReaderContentLoader.historyRealmConfiguration = replacementConfiguration
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: snippet))

            let changed = try await ReaderContentLoader.updateSnippetContent(
                contentURL: snippetURL,
                title: "Original account edit",
                html: self.updatedSnippetHTML(token: "captured-storage"),
                storage: storage,
                permitsCommit: { true }
            )
            XCTAssertTrue(changed)

            let originalRealm = try await Realm(configuration: originalConfiguration)
            try await originalRealm.asyncRefresh()
            let histories = originalRealm.objects(HistoryRecord.self)
                .filter(NSPredicate(format: "url == %@", snippetURL.absoluteString))
            let bookmarks = originalRealm.objects(Bookmark.self)
                .filter(NSPredicate(format: "url == %@", snippetURL.absoluteString))
            XCTAssertEqual(histories.count, 2)
            XCTAssertEqual(bookmarks.count, 1)
            let objects: [any ReaderContentProtocol] = histories.map { $0 as any ReaderContentProtocol }
                + bookmarks.map { $0 as any ReaderContentProtocol }
            for object in objects {
                XCTAssertEqual(object.title, "Original account edit")
                XCTAssertTrue(object.html?.contains("Replacement bullet") == true)
                let recordName = object.objectSchema.className + "." + object.compoundKey
                XCTAssertNotNil(originalRealm.object(
                    ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
                ))
            }
            let replacementRealm = try await Realm(configuration: replacementConfiguration)
            XCTAssertEqual(replacementRealm.objects(HistoryRecord.self).count, 0)
            XCTAssertEqual(replacementRealm.objects(Bookmark.self).count, 0)
        }
    }

    @MainActor
    func testCapturedSnippetSaveNoOpAndExpiredFenceDoNotAdvanceJournal() async throws {
        try await withSnippetRealm { configuration in
            let loaded = try await ReaderContentLoader.load(html: self.snippetHTML(token: "save-no-op"))
            let snippet = try XCTUnwrap(loaded)
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: snippet))
            let html = self.updatedSnippetHTML(token: "save-no-op")
            let first = try await ReaderContentLoader.updateSnippetContent(
                contentURL: snippet.url, title: "Manual title", html: html,
                storage: storage, permitsCommit: { true }
            )
            XCTAssertTrue(first)
            let realm = try await Realm(configuration: configuration)
            try await realm.asyncRefresh()
            let recordName = snippet.objectSchema.className + "." + snippet.compoundKey
            let generation = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
            )?.generation)

            let repeated = try await ReaderContentLoader.updateSnippetContent(
                contentURL: snippet.url, title: "Manual title", html: html,
                storage: storage, permitsCommit: { true }
            )
            let expired = try await ReaderContentLoader.updateSnippetContent(
                contentURL: snippet.url, title: "Rejected title", html: html,
                storage: storage, permitsCommit: { false }
            )
            try await realm.asyncRefresh()
            XCTAssertFalse(repeated)
            XCTAssertFalse(expired)
            XCTAssertEqual(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
            )?.generation, generation)
            XCTAssertEqual(realm.object(
                ofType: HistoryRecord.self, forPrimaryKey: snippet.compoundKey
            )?.title, "Manual title")
        }
    }

    @MainActor
    func testSnippetSaveLosingAdmissionAfterMutationRollsBackBodyTitleAndJournal() async throws {
        try await withSnippetRealm { configuration in
            let loaded = try await ReaderContentLoader.load(html: self.snippetHTML(token: "rollback-save"))
            let snippet = try XCTUnwrap(loaded)
            let originalTitle = snippet.title
            let originalHTML = snippet.html
            let key = snippet.compoundKey
            let recordName = snippet.objectSchema.className + "." + key
            let realm = try await Realm(configuration: configuration)
            let generation = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
            )?.generation)
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: snippet))
            let fence = SnippetSaveAdmissionFence(allowedChecks: 2)
            do {
                _ = try await ReaderContentLoader.updateSnippetContent(
                    contentURL: snippet.url, title: "Must roll back",
                    html: self.updatedSnippetHTML(token: "rollback-save"), storage: storage,
                    permitsCommit: { fence.permitsCommit() }
                )
                XCTFail("Admission lost after provisional mutation must reject the transaction")
            } catch is CancellationError {
                // The final transaction fence rejects after provisional fields
                // and metadata changed, rather than only at entry admission.
            }
            try await realm.asyncRefresh()
            let persisted = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            XCTAssertEqual(persisted.title, originalTitle)
            XCTAssertEqual(persisted.html, originalHTML)
            XCTAssertEqual(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
            )?.generation, generation)
        }
    }

    @MainActor
    func testCapturedSnippetRepresentationsRollBackTogetherAtFinalFence() async throws {
        try await withSnippetRealm { configuration in
            let loaded = try await ReaderContentLoader.load(html: "<p>Atomic original.</p>")
            let snippet = try XCTUnwrap(loaded)
            let url = snippet.url
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: snippet))
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                try Self.seedSnippetRepresentations(url: url, in: realm)
                let before = Self.snippetWriteSnapshot(in: realm)
                let probe = SnippetAtomicWriteProbe(realm: realm, url: url)
                do {
                    _ = try await ReaderContentLoader.updateCapturedSnippetRecords(
                        contentURL: url, storage: storage,
                        permitsCommit: { probe.permitsCommitBeforeHistoryChanges() },
                        mutate: { Self.writeSnippetTestContent($0) }
                    )
                    XCTFail("A rejected final fence must roll back every representation")
                } catch is CancellationError {}
                XCTAssertTrue(probe.observedProvisionalBookmark)
                XCTAssertTrue(probe.observedProvisionalHistory)
                XCTAssertEqual(Self.snippetWriteSnapshot(in: realm), before)

                let changed = try await ReaderContentLoader.updateCapturedSnippetRecords(
                    contentURL: url, storage: storage, permitsCommit: { true },
                    mutate: { Self.writeSnippetTestContent($0) }
                )
                XCTAssertTrue(changed)
                let committed = Self.snippetWriteSnapshot(in: realm)
                XCTAssertTrue(realm.objects(Bookmark.self).allSatisfy { $0.title == "Atomic saved" })
                XCTAssertTrue(HistoryRecord.openedRecords(matching: url, in: realm).allSatisfy {
                    $0.title == "Atomic saved"
                })
                let dates = Set(realm.objects(Bookmark.self).map(\.modifiedAt)
                    + HistoryRecord.openedRecords(matching: url, in: realm).map(\.modifiedAt))
                XCTAssertEqual(dates.count, 1)
                let repeated = try await ReaderContentLoader.updateCapturedSnippetRecords(
                    contentURL: url, storage: storage, permitsCommit: { true },
                    mutate: { Self.writeSnippetTestContent($0) }
                )
                XCTAssertFalse(repeated)
                XCTAssertEqual(Self.snippetWriteSnapshot(in: realm), committed)
            }()
        }
    }

    @MainActor
    func testCapturedSnippetWriterRequeriesLiveRowsAfterWriteAdmission() async throws {
        try await withSnippetRealm { configuration in
            let loaded = try await ReaderContentLoader.load(html: "<p>Live selection.</p>")
            let snippet = try XCTUnwrap(loaded)
            let url = snippet.url
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: snippet))
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                try Self.seedSnippetRepresentations(url: url, in: realm)
                let probe = SnippetAtomicWriteProbe(realm: realm, url: url)
                let changed = try await ReaderContentLoader.updateCapturedSnippetRecords(
                    contentURL: url, storage: storage,
                    permitsCommit: { probe.deleteBookmarkAtWriteAdmission() },
                    mutate: { Self.writeSnippetTestContent($0) }
                )
                XCTAssertTrue(changed)
                XCTAssertTrue(probe.didDeleteBookmark)
                let bookmark = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: "atomic-bookmark"))
                XCTAssertTrue(bookmark.isDeleted)
                XCTAssertEqual(bookmark.title, "Original bookmark")
                XCTAssertEqual(bookmark.html, "<p>Original bookmark.</p>")
                XCTAssertTrue(HistoryRecord.openedRecords(matching: url, in: realm).allSatisfy {
                    $0.title == "Atomic saved"
                })
            }()
        }
    }

    @MainActor
    func testSeparateCapturedStoresDoNotClaimWholeSaveAfterLaterFenceWithdraws() async throws {
        try await withSnippetRealm { bookmarkConfiguration in
            let historyConfiguration = self.makeRealmConfiguration()
            ReaderContentLoader.historyRealmConfiguration = historyConfiguration
            let storage = ReaderContentLoader.SnippetStorage.capture()
            let url = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "separate-store-change"))
            try await { @RealmBackgroundActor in
                let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkConfiguration)
                let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyConfiguration)
                let bookmark = Bookmark()
                bookmark.compoundKey = "separate-bookmark"
                bookmark.url = url
                bookmark.title = "Original bookmark"
                let history = HistoryRecord()
                history.compoundKey = "separate-history"
                history.url = url
                history.title = "Original history"
                try bookmarkRealm.write { bookmarkRealm.add(bookmark) }
                try historyRealm.write { historyRealm.add(history) }
                let historyBefore = Self.snippetWriteSnapshot(in: historyRealm)
                let probe = SnippetCommittedStoreProbe(bookmarkRealm: bookmarkRealm)
                do {
                    _ = try await ReaderContentLoader.updateCapturedSnippetRecords(
                        contentURL: url, storage: storage, permitsCommit: { probe.permitsCommit() },
                        mutate: { Self.writeSnippetTestContent($0) }
                    )
                    XCTFail("Separate stores cannot claim the whole edit completed after ownership leaves")
                } catch is CancellationError {
                    // Compatibility is atomic per store. The prior committed
                    // bookmark is retained; the later history was not changed.
                }
                XCTAssertTrue(probe.observedCommittedStore)
                XCTAssertEqual(bookmark.title, "Atomic saved")
                XCTAssertEqual(Self.snippetWriteSnapshot(in: historyRealm), historyBefore)
            }()
        }
    }

    @MainActor
    func testOwnedFreshImportRejectsExpiredAndFinalFencesWithoutRowsOrJournal() async throws {
        try await withSnippetRealm { configuration in
            let storage = ReaderContentLoader.ImportStorage.capture()
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                for payload in [ReaderContentLoader.ImportPayload.html("<p>Rejected text</p>", fromClipboard: true),
                                .url(URL(string: "https://example.com/rejected-import")!)] {
                    do {
                        _ = try await ReaderContentLoader.importContent(payload, storage: storage, permitsCommit: { false })
                        XCTFail("Expired input must not start an import")
                    } catch is CancellationError {}
                    let probe = OwnedImportWriteProbe(realm: realm, mode: .rejectNewHistory)
                    do {
                        _ = try await ReaderContentLoader.importContent(
                            payload, storage: storage, permitsCommit: { probe.permitsCommit() }
                        )
                        XCTFail("The final fence must reject provisional rows and metadata")
                    } catch is CancellationError {}
                    XCTAssertTrue(probe.observedMutation)
                    XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
                    XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
                }
            }()
        }
    }

    @MainActor
    func testOwnedImportFinalTaskCancellationRollsBackProvisionalCreation() async throws {
        try await withSnippetRealm { configuration in
            let storage = ReaderContentLoader.ImportStorage.capture()
            let task = Task { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let probe = OwnedImportWriteProbe(realm: realm, mode: .cancelNewHistory)
                do {
                    _ = try await ReaderContentLoader.importContent(
                        .html("<p>Cancelled final write</p>", fromClipboard: false),
                        storage: storage, permitsCommit: { probe.permitsCommit() }
                    )
                    XCTFail("Cancellation during the final fence must still roll back")
                } catch is CancellationError {}
                return probe.observedMutation && realm.objects(HistoryRecord.self).isEmpty
                    && realm.objects(BigSyncPendingMutation.self).isEmpty
            }
            let rolledBack = try await task.value
            XCTAssertTrue(rolledBack)
        }
    }

    @MainActor
    func testOwnedImportUsesCapturedStorageAndReturnsCommittedReferenceBeforeCancellation() async throws {
        try await withSnippetRealm { originalConfiguration in
            let storage = ReaderContentLoader.ImportStorage.capture()
            let replacement = self.makeRealmConfiguration()
            ReaderContentLoader.bookmarkRealmConfiguration = replacement
            ReaderContentLoader.historyRealmConfiguration = replacement
            ReaderContentLoader.feedEntryRealmConfiguration = replacement
            let task = Task { @MainActor in
                let reference = try await ReaderContentLoader.importContent(
                    .html("<p>Original captured import</p>", fromClipboard: true),
                    storage: storage, permitsCommit: { true }
                )
                let key = try XCTUnwrap(reference).contentKey
                // The caller can be cancelled after the real write joined.
                // Its durable reference remains a success, with UI separate.
                withUnsafeCurrentTask { $0?.cancel() }
                return key
            }
            let key = try await task.value
            let realm = try await Realm(configuration: originalConfiguration)
            let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            XCTAssertTrue(record.isFromClipboard)
            XCTAssertTrue(record.isReaderModeByDefault)
            XCTAssertTrue(record.rssContainsFullContent)
            XCTAssertEqual(record.isDemoted, false)
            XCTAssertEqual(record.createdAt, record.explicitlyModifiedAt)
            XCTAssertEqual(record.lastVisitedAt, record.explicitlyModifiedAt)
            XCTAssertTrue(record.html?.contains("Original captured import") == true)
            let mutation = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: HistoryRecord.className() + "." + key
            ))
            XCTAssertEqual(mutation.changedAt, record.explicitlyModifiedAt)
            let other = try await Realm(configuration: replacement)
            XCTAssertTrue(other.objects(HistoryRecord.self).isEmpty)
        }
    }

    @MainActor
    func testOwnedURLImportRollsBackVisitMetadataAndBookmarkLinksTogether() async throws {
        try await withSnippetRealm { configuration in
            let storage = ReaderContentLoader.ImportStorage.capture()
            let url = URL(string: "https://example.com/owned-bookmark-import")!
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                try Self.seedSnippetRepresentations(url: url, in: realm)
                try realm.write {
                    realm.objects(Bookmark.self).first!.createdAt = .distantFuture
                    for history in realm.objects(HistoryRecord.self) { history.lastVisitedAt = .distantPast }
                }
                let before = Self.snippetWriteSnapshot(in: realm)
                let oldVisit = realm.objects(HistoryRecord.self).first!.lastVisitedAt
                let probe = OwnedImportWriteProbe(realm: realm, mode: .rejectBookmarkLink)
                do {
                    _ = try await ReaderContentLoader.importContent(
                        .url(url), storage: storage, permitsCommit: { probe.permitsCommit() }
                    )
                    XCTFail("Visit, copied title, demotion and bookmark links must roll back together")
                } catch is CancellationError {}
                XCTAssertTrue(probe.observedMutation)
                XCTAssertEqual(Self.snippetWriteSnapshot(in: realm), before)
                XCTAssertEqual(realm.objects(HistoryRecord.self).first!.lastVisitedAt, oldVisit)
                XCTAssertNil(realm.objects(HistoryRecord.self).first!.bookmarkID)
                XCTAssertNil(realm.objects(HistoryRecord.self).first!.isDemoted)
            }()
        }
    }

    @MainActor
    func testOwnedURLImportWithSplitStoresKeepsSourcesReadOnlyAndRollsBackHistory() async throws {
        try await withSnippetRealm { historyConfiguration in
            let bookmarkConfiguration = self.makeRealmConfiguration()
            let feedConfiguration = self.makeRealmConfiguration()
            let replacementConfiguration = self.makeRealmConfiguration()
            ReaderContentLoader.bookmarkRealmConfiguration = bookmarkConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = feedConfiguration
            let storage = ReaderContentLoader.ImportStorage.capture()
            ReaderContentLoader.bookmarkRealmConfiguration = replacementConfiguration
            ReaderContentLoader.historyRealmConfiguration = replacementConfiguration
            ReaderContentLoader.feedEntryRealmConfiguration = replacementConfiguration
            let url = URL(string: "https://example.com/split-owned-import")!
            try await { @RealmBackgroundActor in
                let bookmarks = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkConfiguration)
                let history = try await RealmBackgroundActor.shared.cachedRealm(for: historyConfiguration)
                let feeds = try await RealmBackgroundActor.shared.cachedRealm(for: feedConfiguration)
                try bookmarks.write {
                    let bookmark = Bookmark()
                    bookmark.url = url
                    bookmark.title = "Captured bookmark"
                    bookmark.html = "<p>Captured body</p>"
                    // This historical field means full content for every source,
                    // not just RSS. A summary-only source must not become a body.
                    bookmark.rssContainsFullContent = true
                    bookmark.createdAt = .distantFuture
                    bookmark.updateCompoundKey()
                    bookmarks.add(bookmark)
                    bookmark.refreshChangeMetadata(explicitlyModified: true)
                }
                let sourceBefore = Self.snippetWriteSnapshot(in: bookmarks)
                let feedBefore = Self.snippetWriteSnapshot(in: feeds)
                let historyBefore = Self.snippetWriteSnapshot(in: history)
                let probe = OwnedImportWriteProbe(realm: history, mode: .rejectNewHistory)
                do {
                    _ = try await ReaderContentLoader.importContent(
                        .url(url), storage: storage, permitsCommit: { probe.permitsCommit() }
                    )
                    XCTFail("A rejected split-store visit must not leave a History row")
                } catch is CancellationError {}
                XCTAssertTrue(probe.observedMutation)
                XCTAssertEqual(Self.snippetWriteSnapshot(in: history), historyBefore)
                let savedReference = try await ReaderContentLoader.importContent(
                    .url(url), storage: storage, permitsCommit: { true }
                )
                let reference = try XCTUnwrap(savedReference)
                XCTAssertEqual(reference.realmConfiguration.fileURL, historyConfiguration.fileURL)
                let record = try XCTUnwrap(history.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
                XCTAssertEqual(record.title, "Captured bookmark")
                XCTAssertEqual(record.html, "<p>Captured body</p>")
                XCTAssertNotNil(record.bookmarkID)
                XCTAssertEqual(Self.snippetWriteSnapshot(in: bookmarks), sourceBefore)
                XCTAssertEqual(Self.snippetWriteSnapshot(in: feeds), feedBefore)
                let replacement = try await RealmBackgroundActor.shared.cachedRealm(for: replacementConfiguration)
                XCTAssertTrue(replacement.objects(HistoryRecord.self).isEmpty)
                XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
            }()
        }
    }

    @MainActor
    func testOwnedURLImportRevalidatesSourceAfterWriteAdmission() async throws {
        try await withSnippetRealm { configuration in
            let storage = ReaderContentLoader.ImportStorage.capture()
            let url = URL(string: "https://example.com/live-import-source")!
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                try Self.seedSnippetRepresentations(url: url, in: realm)
                let probe = OwnedImportWriteProbe(realm: realm, mode: .deleteBookmarkAtEntry)
                let reference = try await ReaderContentLoader.importContent(
                    .url(url), storage: storage, permitsCommit: { probe.permitsCommit() }
                )
                XCTAssertTrue(probe.observedMutation)
                let history = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: try XCTUnwrap(reference).contentKey))
                XCTAssertEqual(history.title, "Original second history")
                XCTAssertNil(history.bookmarkID)
                XCTAssertTrue(realm.objects(Bookmark.self).first!.isDeleted)
            }()
        }
    }

    @MainActor
    func testOwnedURLImportRevivesCanonicalHistoryWithoutErasingRetainedBody() async throws {
        try await withSnippetRealm { configuration in
            let storage = ReaderContentLoader.ImportStorage.capture()
            let url = URL(string: "https://example.com/canonical-import")!
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let canonical = HistoryRecord()
                canonical.url = url
                canonical.updateCompoundKey()
                canonical.html = "<p>Keep downloaded body bytes.</p>"
                canonical.isDeleted = true
                let alias = HistoryRecord()
                alias.compoundKey = "deleted-alias"
                alias.url = ReaderContentLoader.readerLoaderURL(for: url)!
                alias.lastVisitedAt = .distantFuture
                alias.isDeleted = true
                let bookmark = Bookmark()
                bookmark.compoundKey = "canonical-import-bookmark"
                bookmark.url = url
                bookmark.title = "Imported bookmark title"
                bookmark.rssContainsFullContent = false
                bookmark.voiceAudioURLs.append(URL(string: "https://example.com/audio.mp3")!)
                bookmark.audioSubtitlesURL = URL(string: "https://example.com/audio.vtt")!
                bookmark.readerContentKind = .readerContent
                bookmark.feedEntryCollectionTitle = "Collection title"
                try realm.write { realm.add(canonical); realm.add(alias); realm.add(bookmark) }
                let reference = try await ReaderContentLoader.importContent(.url(url), storage: storage, permitsCommit: { true })
                XCTAssertEqual(reference?.contentKey, canonical.compoundKey)
                XCTAssertFalse(canonical.isDeleted)
                XCTAssertTrue(alias.isDeleted)
                XCTAssertEqual(canonical.html, "<p>Keep downloaded body bytes.</p>")
                XCTAssertEqual(canonical.title, bookmark.title)
                XCTAssertEqual(canonical.bookmarkID, bookmark.compoundKey)
                XCTAssertEqual(canonical.voiceAudioURLs.first, bookmark.voiceAudioURLs.first)
                XCTAssertEqual(canonical.audioSubtitlesURL, bookmark.audioSubtitlesURL)
                XCTAssertEqual(canonical.audioSubtitlesRole, .content)
                XCTAssertEqual(canonical.feedEntryCollectionTitle, bookmark.feedEntryCollectionTitle)
                XCTAssertEqual(canonical.isDemoted, false)
                XCTAssertEqual(realm.objects(HistoryRecord.self).count, 2)
            }()
        }
    }

    @MainActor
    func testOwnedHTTPSImportUsesHTTPFeedWithoutWritingLazyImageCache() async throws {
        try await withSnippetRealm { configuration in
            let storage = ReaderContentLoader.ImportStorage.capture()
            let url = URL(string: "https://example.com/feed-import")!
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let feed = Feed()
                feed.extractImageFromContent = true
                feed.rssContainsFullContent = true
                let entry = FeedEntry()
                entry.compoundKey = "http-feed-import"
                entry.feedID = feed.id
                entry.url = URL(string: "http://example.com/feed-import")!
                entry.title = "HTTPS fallback title"
                entry.html = "<html><body><img src='https://example.com/photo.jpg'><p>Full feed body.</p></body></html>"
                try realm.write { realm.add(feed); realm.add(entry) }
                let beforeImage = entry.imageUrl
                let beforeModified = entry.modifiedAt
                let feedRecordName = FeedEntry.className() + "." + entry.compoundKey
                let beforeGeneration = realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: feedRecordName)?.generation
                let reference = try await ReaderContentLoader.importContent(.url(url), storage: storage, permitsCommit: { true })
                let history = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: try XCTUnwrap(reference).contentKey))
                XCTAssertEqual(history.url, url)
                XCTAssertEqual(history.title, entry.title)
                XCTAssertEqual(history.content, entry.content)
                XCTAssertEqual(history.imageUrl, URL(string: "https://example.com/photo.jpg"))
                XCTAssertEqual(entry.imageUrl, beforeImage)
                XCTAssertEqual(entry.modifiedAt, beforeModified)
                XCTAssertEqual(realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: feedRecordName)?.generation, beforeGeneration)
            }()
        }
    }

    @RealmBackgroundActor
    private static func seedSnippetRepresentations(url: URL, in realm: Realm) throws {
        let bookmark = Bookmark()
        bookmark.compoundKey = "atomic-bookmark"
        bookmark.url = url
        bookmark.title = "Original bookmark"
        bookmark.html = "<p>Original bookmark.</p>"
        let history = HistoryRecord()
        history.compoundKey = "atomic-second-history"
        history.url = url
        history.title = "Original second history"
        history.html = "<p>Original second history.</p>"
        try realm.write { realm.add(bookmark); realm.add(history) }
    }

    @RealmBackgroundActor
    private static func writeSnippetTestContent(_ object: any ReaderContentProtocol) -> Bool {
        guard object.title != "Atomic saved" else { return false }
        object.title = "Atomic saved"
        object.html = "<p>Atomic replacement body.</p>"
        return true
    }

    @RealmBackgroundActor
    private static func snippetWriteSnapshot(in realm: Realm) -> [String: String] {
        var snapshot = [String: String]()
        let objects: [any ReaderContentProtocol] = realm.objects(Bookmark.self).map { $0 as any ReaderContentProtocol }
            + realm.objects(HistoryRecord.self).map { $0 as any ReaderContentProtocol }
        for object in objects {
            snapshot[object.objectSchema.className + "." + object.compoundKey] =
                "\(object.title)|\(object.html ?? "")|\(object.modifiedAt)|\(object.explicitlyModifiedAt?.description ?? "nil")|\(object.isDeleted)"
        }
        for journal in realm.objects(BigSyncPendingMutation.self) {
            snapshot["journal." + journal.recordName] = journal.generation
        }
        return snapshot
    }

    @MainActor
    func testTitleOnlySnippetSavePreservesPersistedHTMLBytes() async throws {
        try await withSnippetRealm { configuration in
            let loaded = try await ReaderContentLoader.load(html: self.snippetHTML(token: "title-only"))
            let snippet = try XCTUnwrap(loaded)
            let rawHTML = "<html><head></head><body><div class='mnb-snippet'><p>Keep body bytes.</p></div></body></html>\n"
            let editorHTML = ReaderContentLoader.snippetHTML(fromHTML: rawHTML)
            XCTAssertNotEqual(rawHTML, editorHTML)
            let snippetKey = snippet.compoundKey
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let record = try XCTUnwrap(realm.object(
                    ofType: HistoryRecord.self, forPrimaryKey: snippetKey
                ))
                try await realm.asyncWrite {
                    record.html = rawHTML
                    record.refreshChangeMetadata(explicitlyModified: true)
                }
            }()

            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: snippet))
            let changed = try await ReaderContentLoader.updateSnippetContent(
                contentURL: snippet.url, title: "Title only", html: editorHTML,
                originalEditorHTML: editorHTML, storage: storage, permitsCommit: { true }
            )
            XCTAssertTrue(changed)
            let realm = try await Realm(configuration: configuration)
            try await realm.asyncRefresh()
            let updated = try XCTUnwrap(realm.object(
                ofType: HistoryRecord.self, forPrimaryKey: snippetKey
            ))
            XCTAssertEqual(updated.title, "Title only")
            XCTAssertEqual(updated.html, rawHTML)
        }
    }

    @MainActor
    func testTitleOnlySnippetSavePreservesConcurrentBodiesAndJournalsEachRepresentation() async throws {
        try await withSnippetRealm { configuration in
            let loaded = try await ReaderContentLoader.load(html: self.snippetHTML(token: "concurrent-title"))
            let snippet = try XCTUnwrap(loaded)
            let snippetURL = snippet.url
            let historyKey = snippet.compoundKey
            let bookmarkKey = UUID().uuidString
            let originalTitle = snippet.title
            let editorHTML = try await ReaderContentLoader.snippetEditorHTML(for: snippet)
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: snippet))
            let historyHTML = """
            <html><head></head><body><div class='mnb-snippet'><p>New history body.</p>
            <p><ruby>漢<rt>かん</rt></ruby>語</p></div></body></html>

            """
            let bookmarkHTML = "<html><body><div class='mnb-snippet'><p>New bookmark body.</p></div></body></html>\n"
            XCTAssertNotEqual(editorHTML, ReaderContentLoader.snippetHTML(fromHTML: historyHTML))
            XCTAssertNotEqual(editorHTML, ReaderContentLoader.snippetHTML(fromHTML: bookmarkHTML))

            // Both representations receive newer bodies after the editor has
            // captured its draft, with deliberately different persisted bytes.
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let history = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: historyKey))
                let bookmark = Bookmark()
                bookmark.compoundKey = bookmarkKey
                bookmark.url = snippetURL
                bookmark.title = originalTitle
                bookmark.isTitlePrefixOfContent = true
                try await realm.asyncWrite {
                    realm.add(bookmark)
                    history.html = historyHTML
                    bookmark.html = bookmarkHTML
                    history.refreshChangeMetadata(explicitlyModified: true)
                    bookmark.refreshChangeMetadata(explicitlyModified: true)
                }
            }()

            let realm = try await Realm(configuration: configuration)
            try await realm.asyncRefresh()
            let history = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: historyKey))
            let bookmark = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: bookmarkKey))
            let objects: [any ReaderContentProtocol] = [history, bookmark]
            var previousGenerations = [String: String]()
            for object in objects {
                let recordName = object.objectSchema.className + "." + object.compoundKey
                previousGenerations[recordName] = try XCTUnwrap(realm.object(
                    ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
                )?.generation)
            }
            let requestedTitle = try XCTUnwrap(ReaderContentLoader.generatedSnippetTitle(fromSourceHTML: historyHTML))
            let changed = try await ReaderContentLoader.updateSnippetContent(
                contentURL: snippetURL, title: requestedTitle, html: editorHTML,
                originalEditorHTML: editorHTML, storage: storage, permitsCommit: { true }
            )
            XCTAssertTrue(changed)
            try await realm.asyncRefresh()
            XCTAssertEqual(history.html, historyHTML)
            XCTAssertEqual(bookmark.html, bookmarkHTML)
            XCTAssertTrue(history.isTitlePrefixOfContent)
            XCTAssertFalse(bookmark.isTitlePrefixOfContent)
            XCTAssertEqual(history.explicitlyModifiedAt, bookmark.explicitlyModifiedAt)

            var savedGenerations = [String: String]()
            for object in objects {
                XCTAssertEqual(object.title, requestedTitle)
                let recordName = object.objectSchema.className + "." + object.compoundKey
                let mutation = try XCTUnwrap(realm.object(
                    ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
                ))
                XCTAssertNotEqual(mutation.generation, previousGenerations[recordName])
                XCTAssertEqual(mutation.changedAt, object.explicitlyModifiedAt)
                savedGenerations[recordName] = mutation.generation
            }

            let repeated = try await ReaderContentLoader.updateSnippetContent(
                contentURL: snippetURL, title: requestedTitle, html: editorHTML,
                originalEditorHTML: editorHTML, storage: storage, permitsCommit: { true }
            )
            XCTAssertFalse(repeated)
            try await realm.asyncRefresh()
            XCTAssertEqual(history.html, historyHTML)
            XCTAssertEqual(bookmark.html, bookmarkHTML)
            for (recordName, generation) in savedGenerations {
                XCTAssertEqual(realm.object(
                    ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName
                )?.generation, generation)
            }
        }
    }

    @MainActor
    func testCapturedRenameAndAppendKeepOriginalStorageAfterGlobalReplacement() async throws {
        try await withSnippetRealm { originalConfiguration in
            let loaded = try await ReaderContentLoader.load(html: self.snippetHTML(token: "captured-actions"))
            let snippet = try XCTUnwrap(loaded)
            let replacementConfiguration = self.makeRealmConfiguration()
            ReaderContentLoader.bookmarkRealmConfiguration = replacementConfiguration
            ReaderContentLoader.historyRealmConfiguration = replacementConfiguration
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: snippet))

            let renamed = try await ReaderContentLoader.updateSnippetTitle(
                contentURL: snippet.url, title: "Original account note",
                storage: storage, permitsCommit: { true }
            )
            let appended = try await ReaderContentLoader.appendSnippetHTML(
                "<p>Captured append.</p>", toContentURL: snippet.url,
                storage: storage, permitsCommit: { true }
            )
            XCTAssertTrue(renamed)
            XCTAssertTrue(appended)

            let originalRealm = try await Realm(configuration: originalConfiguration)
            try await originalRealm.asyncRefresh()
            let originalRecord = try XCTUnwrap(originalRealm.object(
                ofType: HistoryRecord.self, forPrimaryKey: snippet.compoundKey
            ))
            XCTAssertEqual(originalRecord.title, "Original account note")
            XCTAssertTrue(originalRecord.html?.contains("Captured append.") == true)
            let replacementRealm = try await Realm(configuration: replacementConfiguration)
            XCTAssertEqual(replacementRealm.objects(HistoryRecord.self).count, 0)
        }
    }

    @MainActor
    func testUpdateSnippetContentPreservesManualTitlesAndClearsPrefixFlag() async throws {
        let snippetHTML = self.snippetHTML(token: "manual-title")
        let updatedSnippetHTML = self.updatedSnippetHTML(token: "manual-title")
        try await withSnippetRealm { _ in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let content = try XCTUnwrap(loadedContent)
            let originalURL = content.url

            let didUpdate = try await ReaderContentLoader.updateSnippetContent(
                contentURL: originalURL,
                title: "Manual Snippet Title",
                html: updatedSnippetHTML
            )
            XCTAssertTrue(didUpdate)

            let reloaded = try await ReaderContentLoader.load(
                url: originalURL,
                persist: false,
                countsAsHistoryVisit: false
            )
            let reloadedContent = try XCTUnwrap(reloaded)
            XCTAssertEqual(reloadedContent.title, "Manual Snippet Title")
            XCTAssertFalse(reloadedContent.isTitlePrefixOfContent)
        }
    }

    @MainActor
    func testReaderContentUsesSnippetChromeTitleOnlyForPrefixTitles() async throws {
        let snippetHTML = self.snippetHTML(token: "chrome-title")
        try await withSnippetRealm { _ in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let autoTitledContent = try XCTUnwrap(loadedContent)

            let readerContent = ReaderContent()
            readerContent.content = autoTitledContent
            readerContent.pageURL = autoTitledContent.url

            XCTAssertEqual(readerContent.locationBarTitle, autoTitledContent.defaultSnippetChromeTitle)
            XCTAssertTrue(readerContent.snippetTitleIsGeneratedFromPrefix)

            let didUpdate = try await ReaderContentLoader.updateSnippetContent(
                contentURL: autoTitledContent.url,
                title: "Manual Snippet Title",
                html: snippetHTML
            )
            XCTAssertTrue(didUpdate)
            let reloaded = try await ReaderContentLoader.load(
                url: autoTitledContent.url,
                persist: false,
                countsAsHistoryVisit: false
            )
            let manualContent = try XCTUnwrap(reloaded)

            readerContent.content = manualContent
            readerContent.pageURL = manualContent.url

            XCTAssertEqual(readerContent.locationBarTitle, "Manual Snippet Title")
            XCTAssertFalse(readerContent.snippetTitleIsGeneratedFromPrefix)
        }
    }

    @MainActor
    func testReaderContentRenameCommitsManagedSnippetAndJournalsOnlyChanges() async throws {
        let html = snippetHTML(token: "managed-rename")
        try await withSnippetRealm { _ in
            let loaded = try await ReaderContentLoader.load(html: html)
            let snippet = try XCTUnwrap(loaded)
            let realm = try XCTUnwrap(snippet.realm)
            let originalHTML = snippet.html
            let recordName = snippet.objectSchema.className + "." + snippet.compoundKey
            let originalGeneration = try XCTUnwrap(
                realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName)?.generation
            )
            let reader = ReaderContent()
            reader.content = snippet
            reader.pageURL = snippet.url

            let renamed = try await reader.updateContentTitle("  My library notes  ")

            XCTAssertTrue(renamed)
            XCTAssertEqual(reader.content?.title, "My library notes")
            XCTAssertEqual(reader.contentTitle, "My library notes")
            XCTAssertEqual(reader.locationBarTitle, "My library notes")
            XCTAssertFalse(reader.snippetTitleIsGeneratedFromPrefix)
            XCTAssertEqual(reader.content?.html, originalHTML)
            let generation = try XCTUnwrap(
                realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName)?.generation
            )
            XCTAssertNotEqual(generation, originalGeneration)
            let modifiedAt = snippet.explicitlyModifiedAt

            let repeated = try await reader.updateContentTitle("My library notes")
            let empty = try await reader.updateContentTitle(" \n ")

            XCTAssertFalse(repeated)
            XCTAssertFalse(empty)
            XCTAssertEqual(snippet.explicitlyModifiedAt, modifiedAt)
            XCTAssertEqual(
                realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: recordName)?.generation,
                generation
            )
        }
    }

    @MainActor
    func testReaderContentRenameRefreshesFrozenSnippetAfterCommit() async throws {
        let html = snippetHTML(token: "frozen-rename")
        try await withSnippetRealm { _ in
            let loaded = try await ReaderContentLoader.load(html: html)
            let snippet = try XCTUnwrap(loaded as? HistoryRecord)
            let frozen = snippet.freeze()
            let reader = ReaderContent()
            reader.content = frozen
            reader.pageURL = frozen.url

            let renamed = try await reader.updateContentTitle("Frozen snippet renamed")

            XCTAssertTrue(renamed)
            XCTAssertEqual(reader.content?.title, "Frozen snippet renamed")
            XCTAssertEqual(reader.locationBarTitle, "Frozen snippet renamed")
            XCTAssertFalse(try XCTUnwrap(reader.content).isFrozen)
            XCTAssertNotEqual(frozen.title, "Frozen snippet renamed")
        }
    }

    @MainActor
    func testRenameUsesPersistedHTMLToRestoreGeneratedTitle() async throws {
        let html = snippetHTML(token: "rename-current-html")
        let updatedHTML = updatedSnippetHTML(token: "rename-current-html")
        try await withSnippetRealm { _ in
            let loaded = try await ReaderContentLoader.load(html: html)
            let snippet = try XCTUnwrap(loaded as? HistoryRecord)
            let frozen = snippet.freeze()
            let reader = ReaderContent()
            reader.content = frozen
            reader.pageURL = frozen.url
            let updated = try await ReaderContentLoader.updateSnippetContent(
                contentURL: frozen.url,
                title: "Manual title",
                html: updatedHTML
            )
            XCTAssertTrue(updated)
            let generatedTitle = try XCTUnwrap(
                ReaderContentLoader.generatedSnippetTitle(fromSourceHTML: updatedHTML)
            )

            let renamed = try await reader.updateContentTitle(generatedTitle)

            XCTAssertTrue(renamed)
            XCTAssertEqual(reader.content?.title, generatedTitle)
            XCTAssertTrue(reader.snippetTitleIsGeneratedFromPrefix)
            XCTAssertEqual(reader.locationBarTitle, reader.content?.defaultSnippetChromeTitle)
            XCTAssertNotEqual(reader.content?.html, frozen.html)
            XCTAssertTrue(ReaderContentLoader.snippetTitleMatchesGeneratedPrefix(
                generatedTitle,
                sourceHTML: reader.content?.html
            ))
        }
    }

    @MainActor
    func testRenameKeepsCapturedSnippetTargetAfterDisplayedContentChanges() async throws {
        let firstHTML = snippetHTML(token: "rename-first")
        let secondHTML = snippetHTML(token: "rename-second")
        try await withSnippetRealm { _ in
            let firstLoad = try await ReaderContentLoader.load(html: firstHTML)
            let first = try XCTUnwrap(firstLoad)
            let targetURL = first.url
            let secondLoad = try await ReaderContentLoader.load(html: secondHTML)
            let second = try XCTUnwrap(secondLoad)
            let reader = ReaderContent()
            reader.content = second
            reader.pageURL = second.url
            let secondTitle = second.title
            let secondChromeTitle = reader.locationBarTitle

            let renamed = try await reader.updateContentTitle("First snippet renamed", for: targetURL)

            XCTAssertTrue(renamed)
            XCTAssertTrue(reader.content === second)
            XCTAssertEqual(reader.content?.title, secondTitle)
            XCTAssertEqual(reader.locationBarTitle, secondChromeTitle)
            let reloaded = try await ReaderContentLoader.lookupStoredContent(url: targetURL)
            XCTAssertEqual(reloaded?.title, "First snippet renamed")
        }
    }

    @MainActor
    func testNewURLIsImmediatelyVisibleToContentUpdatesAndReads() async throws {
        try await withSnippetRealm { _ in
            let url = URL(string: "https://example.com/new-reader-record")!
            let loaded = try await ReaderContentLoader.load(url: url)
            let original = try XCTUnwrap(loaded)
            let key = original.compoundKey
            let updatedKeys = try await { @RealmBackgroundActor in
                var keys = [String]()
                try await ReaderContentLoader.updateContent(url: url) { object in
                    keys.append(object.compoundKey)
                    object.title = "Discovered feed"
                    object.rssURLs.append(URL(string: "https://example.com/feed.xml")!)
                    object.isRSSAvailable = true
                    return true
                }
                return keys
            }()

            XCTAssertEqual(updatedKeys, [key])
            let reloaded = try await ReaderContentLoader.lookupStoredContent(url: url)
            XCTAssertEqual(reloaded?.title, "Discovered feed")
            XCTAssertEqual(reloaded?.rssURLs.count, 1)
            XCTAssertEqual(reloaded?.isRSSAvailable, true)
        }
    }

    @MainActor
    func testIndependentRepeatedLoadPreservesExistingHistoryMetadata() async throws {
        try await withSnippetRealm { _ in
            let url = URL(string: "https://example.com/repeated-reader-load")!
            let loaded = try await ReaderContentLoader.load(url: url)
            let original = try XCTUnwrap(loaded as? HistoryRecord)
            let realm = try XCTUnwrap(original.realm)
            let originalKey = original.compoundKey
            let originalCreatedAt = original.createdAt
            try await realm.asyncWrite {
                original.title = "Keep this title"
                original.html = "<p>Keep this article body.</p>"
                original.isReaderModeByDefault = true
                original.refreshChangeMetadata(explicitlyModified: true)
            }

            // A separate loader call must query the record created by the first
            // call, rather than upserting a fresh default-valued history object.
            let reloaded = try await ReaderContentLoader.load(url: url)
            let repeated = try XCTUnwrap(reloaded)

            XCTAssertEqual(repeated.compoundKey, originalKey)
            XCTAssertEqual(repeated.createdAt, originalCreatedAt)
            XCTAssertEqual(repeated.title, "Keep this title")
            XCTAssertEqual(repeated.html, "<p>Keep this article body.</p>")
            XCTAssertTrue(repeated.isReaderModeByDefault)
            XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
        }
    }

    @MainActor
    func testContentQueryMembershipIncludesNewBookmarkAndExcludesDeletedBookmark() async throws {
        let html = snippetHTML(token: "bookmark-membership")
        try await withSnippetRealm { configuration in
            let loaded = try await ReaderContentLoader.load(html: html)
            let snippet = try XCTUnwrap(loaded)
            let url = snippet.url
            let before = try await { @RealmBackgroundActor in
                try await ReaderContentLoader.loadAll(url: url).count
            }()
            XCTAssertEqual(before, 1)

            try await snippet.addBookmark(realmConfiguration: configuration)
            let changedTypes = try await { @RealmBackgroundActor in
                var types = Set<String>()
                try await ReaderContentLoader.updateContent(url: url) { object in
                    types.insert(object.objectSchema.className)
                    object.title = "Shared title"
                    return true
                }
                return types
            }()
            XCTAssertEqual(changedTypes, [Bookmark.className(), HistoryRecord.className()])

            let remainingTypes = try await { @RealmBackgroundActor in
                let storedBookmark = try await Bookmark.get(forURL: url)
                let bookmark = try XCTUnwrap(storedBookmark)
                let realm = try XCTUnwrap(bookmark.realm)
                try await realm.asyncWrite {
                    bookmark.isDeleted = true
                    bookmark.refreshChangeMetadata(explicitlyModified: true)
                }
                return Set(try await ReaderContentLoader.loadAll(url: url).map { $0.objectSchema.className })
            }()
            XCTAssertEqual(remainingTypes, [HistoryRecord.className()])
        }
    }

    @MainActor
    func testAddBookmarkCopiesSnippetPrefixFlag() async throws {
        let snippetHTML = self.snippetHTML(token: "bookmark-copy")
        try await withSnippetRealm { configuration in
            let loadedContent = try await ReaderContentLoader.load(html: snippetHTML)
            let content = try XCTUnwrap(loadedContent)

            try await content.addBookmark(realmConfiguration: configuration)

            let realm = try await Realm(configuration: configuration)
            try await realm.asyncRefresh()
            let bookmark = try XCTUnwrap(
                realm.objects(Bookmark.self)
                    .filter(NSPredicate(format: "url == %@", content.url.absoluteString))
                    .first
            )
            XCTAssertTrue(bookmark.isTitlePrefixOfContent)
            XCTAssertEqual(bookmark.locationBarTitle, bookmark.defaultSnippetChromeTitle)
        }
    }
}

private final class SnippetSaveAdmissionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingChecks: Int

    init(allowedChecks: Int) { remainingChecks = allowedChecks }

    func permitsCommit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remainingChecks > 0 else { return false }
        remainingChecks -= 1
        return true
    }
}

/// These probes are used only by the internal RealmBackgroundActor writer;
/// unlike public admission callbacks, they are never called on MainActor.
private final class SnippetAtomicWriteProbe: @unchecked Sendable {
    let realm: Realm
    let url: URL
    private(set) var observedProvisionalBookmark = false
    private(set) var observedProvisionalHistory = false
    private(set) var didDeleteBookmark = false

    init(realm: Realm, url: URL) { self.realm = realm; self.url = url }

    func permitsCommitBeforeHistoryChanges() -> Bool {
        precondition(realm.isInWriteTransaction)
        observedProvisionalBookmark = observedProvisionalBookmark
            || realm.objects(Bookmark.self).contains { $0.title == "Atomic saved" }
        observedProvisionalHistory = observedProvisionalHistory
            || HistoryRecord.openedRecords(matching: url, in: realm).contains { $0.title == "Atomic saved" }
        return !observedProvisionalHistory
    }

    func deleteBookmarkAtWriteAdmission() -> Bool {
        precondition(realm.isInWriteTransaction)
        if !didDeleteBookmark,
           let bookmark = realm.object(ofType: Bookmark.self, forPrimaryKey: "atomic-bookmark") {
            didDeleteBookmark = true
            bookmark.isDeleted = true
            bookmark.refreshChangeMetadata(explicitlyModified: true)
        }
        return true
    }
}

private final class SnippetCommittedStoreProbe: @unchecked Sendable {
    let bookmarkRealm: Realm
    private(set) var observedCommittedStore = false
    init(bookmarkRealm: Realm) { self.bookmarkRealm = bookmarkRealm }
    func permitsCommit() -> Bool {
        let priorCommit = !bookmarkRealm.isInWriteTransaction
            && bookmarkRealm.objects(Bookmark.self).contains { $0.title == "Atomic saved" }
        observedCommittedStore = observedCommittedStore || priorCommit
        return !priorCommit
    }
}

private extension RealmBackgroundActor {
    /// Runs on the owning actor instance after the fixture's awaited work.
    func releaseSnippetTitleFixture(_ configuration: Realm.Configuration) -> Bool {
        let key = realmCacheKey(for: configuration)
        guard let realm = cachedRealms[key] else { return true }
        guard !realm.isInWriteTransaction else { return false }
        return removeCachedRealm(for: configuration)
    }
}

/// The owned import API invokes this only on RealmBackgroundActor. It observes
/// actual provisional rows/links instead of assuming a number of fence calls.
private final class OwnedImportWriteProbe: @unchecked Sendable {
    enum Mode { case rejectNewHistory, cancelNewHistory, rejectBookmarkLink, deleteBookmarkAtEntry }
    let realm: Realm
    let mode: Mode
    private(set) var observedMutation = false
    init(realm: Realm, mode: Mode) { self.realm = realm; self.mode = mode }
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
            observedMutation = observedMutation || realm.objects(HistoryRecord.self).contains { $0.bookmarkID != nil }
            return !observedMutation
        case .deleteBookmarkAtEntry:
            if !observedMutation, let bookmark = realm.objects(Bookmark.self).first {
                observedMutation = true
                bookmark.isDeleted = true
                bookmark.refreshChangeMetadata(explicitlyModified: true)
            }
            return true
        }
    }
}
