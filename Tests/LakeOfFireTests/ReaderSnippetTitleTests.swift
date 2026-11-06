import XCTest
import Combine
import LakeKit
import BigSyncKit
import RealmSwift
@testable import RealmSwiftGaps
@testable import LakeOfFireContent
import LakeOfFireCore
@testable import LakeOfFireReader
@testable import SwiftUIWebView
import SwiftSoup

final class ReaderSnippetTitleTests: XCTestCase {
    func testReaderLoaderBuilderProducesOnlyRecoverableContentURLs() throws {
        let webURL = try XCTUnwrap(URL(
            string: "https://example.org/read?chapter=1&source=a%26b#part"
        ))
        let snippetURL = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "alpha%2Fbeta"))
        let readerFileURL = try XCTUnwrap(URL(string: "reader-file://file/load/local/book.html"))
        for source in [webURL, snippetURL, readerFileURL] {
            let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: source))
            XCTAssertEqual(loaderURL.readerLoaderContentURL, source)
        }

        let nestedLoader = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: webURL))
        let executableURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        let dataURL = try XCTUnwrap(URL(string: "data:text/html,hello"))
        XCTAssertEqual(ReaderContentLoader.readerLoaderURL(for: nestedLoader), nestedLoader)
        XCTAssertNil(ReaderContentLoader.readerLoaderURL(for: executableURL))
        XCTAssertNil(ReaderContentLoader.readerLoaderURL(for: dataURL))
    }

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

    // Exact input from ManabiReaderUITestFixtures.paragraphLookupSnippet.
    // Keep the single paragraph and absent viewport metadata: both distinguish
    // this startup input from the passing retarget/dismiss fixture.
    private var paragraphLookupHTML: String {
        """
        <!doctype html>
        <html lang="ja">
          <head>
            <meta charset="utf-8">
            <title>Reader Paragraph Lookup Fixture</title>
            <style>body { font-size: 28px; line-height: 1.8; min-height: 900px; }</style>
          </head>
          <body>
            <p>大きな犬が歩いています。桃を食べました。</p>
          </body>
        </html>
        """
    }

    @MainActor
    func testParagraphLookupStartupIngestionReloadsPersistedSourceAndNativeContent() async throws {
        try await withSnippetRealm { configuration in
            let ingestionID = UUID()
            let loaded = try await ReaderContentLoader.load(
                html: self.paragraphLookupHTML,
                allowContentMatch: false,
                snippetIdentifier: ingestionID
            )
            let imported = try XCTUnwrap(loaded)
            let key = imported.compoundKey
            let canonicalURL = imported.url
            let sourceHTML = try XCTUnwrap(imported.html)
            let sourceData = try XCTUnwrap(imported.content)
            XCTAssertEqual(key, ingestionID.uuidString.uppercased())
            XCTAssertEqual(canonicalURL, ReaderContentLoader.snippetURL(key: key))
            XCTAssertTrue(imported.isReaderModeByDefault)
            XCTAssertTrue(imported.rssContainsFullContent)
            XCTAssertTrue(imported.hasHTML)
            XCTAssertFalse(imported.isDeleted)

            // Inspect persisted HTML as a document, rather than relying on a
            // source-text match or reproducing the normalizer in this test.
            let document = try SwiftSoup.parse(sourceHTML)
            XCTAssertEqual(try document.select("html").attr("lang"), "ja")
            XCTAssertEqual(try document.title(), "Reader Paragraph Lookup Fixture")
            XCTAssertEqual(try document.select("meta[charset]").attr("charset"), "utf-8")
            XCTAssertTrue(try document.select("meta[name=viewport]").isEmpty())
            XCTAssertEqual(try document.select("style").html(),
                           "body { font-size: 28px; line-height: 1.8; min-height: 900px; }")
            XCTAssertEqual(try document.select("body > div.mnb-snippet > p").count, 1)
            XCTAssertEqual(try document.select("body p").text(), "大きな犬が歩いています。桃を食べました。")

            let realm = try await Realm(configuration: configuration)
            try await realm.asyncRefresh()
            let persisted = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            XCTAssertEqual(persisted.url, canonicalURL)
            XCTAssertEqual(persisted.content, sourceData)
            XCTAssertEqual(persisted.html, sourceHTML)
            XCTAssertTrue(persisted.isReaderModeByDefault)
            XCTAssertTrue(persisted.rssContainsFullContent)
            XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
            XCTAssertEqual(persisted.isDemoted, false)
            let mutationKey = persisted.objectSchema.className + "." + key
            XCTAssertNotNil(realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: mutationKey))

            let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: canonicalURL))
            XCTAssertEqual(ReaderContentLoader.getContentURL(fromLoaderURL: loaderURL), canonicalURL)
            await ReaderContentLoader.resetTransientCachesForTesting()
            let resolved = try await ReaderContentLoader.getContent(forURL: loaderURL)
            let reloaded = try XCTUnwrap(resolved)
            XCTAssertEqual(reloaded.compoundKey, key)
            XCTAssertEqual(reloaded.url, canonicalURL)
            XCTAssertEqual(reloaded.content, sourceData)
            XCTAssertEqual(reloaded.html, sourceHTML)
            XCTAssertTrue(reloaded.isReaderModeByDefault)
            XCTAssertTrue(reloaded.rssContainsFullContent)

            // Exercise the same native preload/load boundary as startup,
            // without creating a WebView or manufacturing a readiness signal.
            let reader = ReaderContent()
            reader.preloadResolvedContent(reloaded, for: loaderURL)
            try await reader.load(url: loaderURL)
            XCTAssertEqual(reader.pageURL, canonicalURL)
            XCTAssertEqual(reader.validCachedContent?.compoundKey, key)
            XCTAssertEqual(reader.validCachedContent?.html, sourceHTML)
            XCTAssertTrue(reader.validCachedContent?.isReaderModeByDefault == true)
            XCTAssertNotNil(reader.currentSelectionID)
        }
    }

    @MainActor
    func testParagraphLookupStartupRetryPreservesIdentitySourceAndJournalGeneration() async throws {
        try await withSnippetRealm { configuration in
            let ingestionID = UUID()
            let initial = try await ReaderContentLoader.load(
                html: self.paragraphLookupHTML,
                allowContentMatch: false,
                snippetIdentifier: ingestionID
            )
            let first = try XCTUnwrap(initial)
            let key = first.compoundKey
            let url = first.url
            let sourceData = try XCTUnwrap(first.content)
            let sourceHTML = try XCTUnwrap(first.html)
            let realm = try await Realm(configuration: configuration)
            try await realm.asyncRefresh()
            let mutationKey = first.objectSchema.className + "." + key
            let generation = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: mutationKey)?.generation)

            await ReaderContentLoader.resetTransientCachesForTesting()
            let retry = try await ReaderContentLoader.load(
                html: self.paragraphLookupHTML,
                allowContentMatch: false,
                snippetIdentifier: ingestionID
            )
            let second = try XCTUnwrap(retry)
            XCTAssertEqual(second.compoundKey, key)
            XCTAssertEqual(second.url, url)
            XCTAssertEqual(second.content, sourceData)
            XCTAssertEqual(second.html, sourceHTML)
            XCTAssertTrue(second.isReaderModeByDefault)
            try await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
            XCTAssertEqual(realm.object(ofType: BigSyncPendingMutation.self,
                                        forPrimaryKey: mutationKey)?.generation, generation)
        }
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
    func testStartupImportRetryReusesCommittedRecordWithoutAdvancingJournal() async throws {
        try await withSnippetRealm { configuration in
            let ingestionID = UUID()
            let html = self.snippetHTML(token: "startup-retry")
            let loaded = try await ReaderContentLoader.load(
                html: html, allowContentMatch: false, snippetIdentifier: ingestionID)
            let first = try XCTUnwrap(loaded)
            let realm = try await Realm(configuration: configuration)
            try await realm.asyncRefresh()
            let name = first.objectSchema.className + "." + first.compoundKey
            let generation = try XCTUnwrap(realm.object(ofType: BigSyncPendingMutation.self,
                forPrimaryKey: name)?.generation)
            let retried = try await ReaderContentLoader.load(
                html: html, allowContentMatch: false, snippetIdentifier: ingestionID)
            let second = try XCTUnwrap(retried)
            try await realm.asyncRefresh()
            XCTAssertEqual(second.compoundKey, first.compoundKey)
            XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
            XCTAssertEqual(realm.object(ofType: BigSyncPendingMutation.self,
                forPrimaryKey: name)?.generation, generation)
        }
    }

    @MainActor
    func testConcurrentStartupImportRetriesProduceOneRecordAndDurableJournal() async throws {
        try await withSnippetRealm { configuration in
            let ingestionID = UUID()
            let html = self.snippetHTML(token: "startup-concurrent-retry")
            let imports = (0..<6).map { _ in Task { @MainActor in
                let loaded = try await ReaderContentLoader.load(
                    html: html, allowContentMatch: false, snippetIdentifier: ingestionID)
                return try XCTUnwrap(loaded).compoundKey
            } }
            defer { imports.forEach { $0.cancel() } }
            var keys = [String]()
            var firstError: Error?
            for operation in imports {
                do { keys.append(try await operation.value) }
                catch { if firstError == nil { firstError = error } }
            }
            // Join every writer before fixture teardown, including on failure.
            if let firstError { throw firstError }
            XCTAssertEqual(Set(keys).count, 1)
            let realm = try await Realm(configuration: configuration)
            try await realm.asyncRefresh()
            let record = try XCTUnwrap(realm.objects(HistoryRecord.self).first)
            XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
            let name = record.objectSchema.className + "." + record.compoundKey
            XCTAssertNotNil(realm.object(ofType: BigSyncPendingMutation.self,
                forPrimaryKey: name))
        }
    }

    @MainActor
    func testStartupImportReplayCannotOverwriteEditedOrDeletedRecord() async throws {
        for deletesRecord in [false, true] {
            try await withSnippetRealm { configuration in
                let ingestionID = UUID()
                let html = self.snippetHTML(token: "startup-retired-replay")
                let loaded = try await ReaderContentLoader.load(
                    html: html, allowContentMatch: false, snippetIdentifier: ingestionID)
                let first = try XCTUnwrap(loaded)
                let realm = try await Realm(configuration: configuration)
                let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self,
                    forPrimaryKey: first.compoundKey))
                try await realm.asyncWritePreservingOwnership {
                    if deletesRecord { record.isDeleted = true }
                    else { record.html = self.updatedSnippetHTML(token: "successor-edit") }
                    record.refreshChangeMetadata(explicitlyModified: true)
                }
                let retainedContent = record.content
                let name = record.objectSchema.className + "." + record.compoundKey
                let generation = try XCTUnwrap(realm.object(ofType: BigSyncPendingMutation.self,
                    forPrimaryKey: name)?.generation)
                do {
                    _ = try await ReaderContentLoader.load(
                        html: html, allowContentMatch: false, snippetIdentifier: ingestionID)
                    XCTFail("A retry must not overwrite a successor edit or revive deletion")
                } catch is CancellationError { }
                try await realm.asyncRefresh()
                XCTAssertEqual(record.isDeleted, deletesRecord)
                XCTAssertEqual(record.content, retainedContent)
                XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
                XCTAssertEqual(realm.object(ofType: BigSyncPendingMutation.self,
                    forPrimaryKey: name)?.generation, generation)
            }
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
        var dispatchCount = 0
        let task = Task { @MainActor in
            try await navigator.loadResolvedContent(
                content: original, readerModeViewModel: mode, shouldLoad: { true },
                willDispatchLoad: { dispatchCount += 1 },
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
        XCTAssertEqual(dispatchCount, 0)
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
        var dispatchCount = 0
        try await navigator.loadResolvedContent(
            content: content, readerModeViewModel: mode, shouldLoad: { true },
            willDispatchLoad: { dispatchCount += 1 },
            resolveURL: { content.url }
        )
        XCTAssertEqual(dispatchCount, 1)
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
            }()
            // Capture the seeded files so the writer fences their physical identities.
            let storage = ReaderContentLoader.SnippetStorage.capture()
            try await { @RealmBackgroundActor in
                let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkConfiguration)
                let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyConfiguration)
                let bookmark = try XCTUnwrap(bookmarkRealm.object(ofType: Bookmark.self, forPrimaryKey: "separate-bookmark"))
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

@MainActor
private extension ReaderSnippetTitleTests {
    func nativeSnippet(_ key: String, title: String = "Original") -> HistoryRecord {
        let row = HistoryRecord()
        row.url = ReaderContentLoader.snippetURL(key: key)!
        row.title = title
        row.updateCompoundKey()
        return row
    }

    func nativeIntent(from source: URL, to target: URL) throws -> WebViewURLTransitionIntent {
        let caller = WebViewScriptCaller()
        caller.installBinding(ownedBy: UUID(), asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        let sequencer = WebViewURLPublicationReceiptSequencer()
        sequencer.configure(webViewID: ObjectIdentifier(caller),
            binding: try XCTUnwrap(caller.currentJavaScriptBindingToken), url: source)
        // Intent retains its monotonic lifetime independently of the sequencer.
        return try XCTUnwrap(sequencer.observe(target, from: ObjectIdentifier(caller)).intent)
    }
}

extension ReaderSnippetTitleTests {
    @MainActor
    func testNativeSnippetOwnerSurvivesLoaderSelectionAndRendererReplacement() async throws {
        let reader = ReaderContent()
        let row = nativeSnippet("native-handoff")
        try await reader.load(url: row.url) { _ in row }
        let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: row.url))
        let oldSelection = reader.currentSelectionID
        let loader = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: row.url))
        let intent = try nativeIntent(from: row.url, to: loader)
        XCTAssertNotNil(reader.receiveSelectionIntent(intent))
        XCTAssertTrue(fence())
        try await reader.load(url: loader, consuming: intent) { _ in
            XCTFail("Same-content handoff should retain its native model")
            return nil
        }
        XCTAssertNotEqual(reader.currentSelectionID, oldSelection)
        XCTAssertTrue(fence(), "A selection replacement is not a logical content replacement")
        let fragment = URL(string: row.url.absoluteString + "#paragraph")!
        try await reader.load(url: fragment) { _ in row }
        XCTAssertTrue(fence())
    }

    @MainActor
    func testNativeSnippetIntentRevokesBeforeSemanticResolutionAndNeverRevives() async throws {
        let reader = ReaderContent()
        let first = nativeSnippet("native-first"), second = nativeSnippet("native-second")
        try await reader.load(url: first.url) { _ in first }
        let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: first.url))
        let selectionFence = reader.makeSelectionCommitFence(requiring: reader.currentSelectionID)
        let intent = try nativeIntent(from: first.url, to: second.url)
        XCTAssertNotNil(reader.receiveSelectionIntent(intent))
        XCTAssertFalse(fence(), "Native intent retires edits before semantic work or resolver starts")
        XCTAssertTrue(selectionFence(), "Do not break the predecessor selection handoff")
        XCTAssertNil(reader.makeNativeContentCommitFence(for: first.url))
        reader.withdrawSelectionIntent(intent)
        try await reader.load(url: first.url) { _ in first }
        XCTAssertFalse(fence(), "Returning to the same URL cannot reopen an old edit")
        XCTAssertTrue(try XCTUnwrap(reader.makeNativeContentCommitFence(for: first.url))())
    }

    @MainActor
    func testDirectNativeSnippetLoadRevokesBeforeResolverAndAwayBackCannotRevive() async throws {
        let reader = ReaderContent()
        let first = nativeSnippet("native-direct-first"), second = nativeSnippet("native-direct-second")
        try await reader.load(url: first.url) { _ in first }
        let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: first.url))
        try await reader.load(url: second.url) { _ in
            XCTAssertFalse(fence())
            return second
        }
        try await reader.load(url: first.url) { _ in first }
        XCTAssertFalse(fence())
    }

    @MainActor
    func testNativeSnippetSavePublishesFreshTitleAndBodyOverFrozenCachedRow() async throws {
        try await withSnippetRealm { _ in
            let loaded = try await ReaderContentLoader.load(html: "<p>Original native body</p>")
            let row = try XCTUnwrap(loaded as? HistoryRecord)
            let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: row))
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: row))
            let frozen = row.freeze()
            let reader = ReaderContent()
            try await reader.load(url: row.url) { _ in frozen }
            let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: row.url))
            let changed = try await ReaderContentLoader.updateSnippetContent(
                contentURL: row.url, title: "Saved native title", html: "<p>Saved native body</p>",
                storage: storage, permitsCommit: fence)
            XCTAssertTrue(changed)
            let resolved = try await reference.resolveOnMainActor()
            let fresh = try XCTUnwrap(resolved)
            XCTAssertTrue(reader.publishUpdatedContent(fresh, permitsPublication: { fence() }))
            XCTAssertFalse(reader.content === frozen)
            XCTAssertEqual(reader.contentTitle, "Saved native title")
            XCTAssertEqual(reader.locationBarTitle, "Saved native title")
            XCTAssertTrue(reader.content?.html?.contains("Saved native body") == true)
            XCTAssertTrue(fence(), "Publishing a fresh row must not invalidate native ownership")
            try await reader.load(url: row.url) { _ in
                XCTFail("Same-URL reload reuses the freshly published row")
                return frozen
            }
            XCTAssertEqual(reader.cachedContentTitle, "Saved native title")
        }
    }

    @MainActor
    func testNativeSnippetPublicationCannotOverwriteReentrantContentSubscriberSuccessor() async throws {
        let reader = ReaderContent()
        let first = nativeSnippet("native-publish-first"), successor = nativeSnippet("native-publish-next", title: "Successor")
        let fresh = nativeSnippet("native-publish-first", title: "Saved")
        try await reader.load(url: first.url) { _ in first }
        let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: first.url))
        let intent = try nativeIntent(from: first.url, to: successor.url)
        let observer = reader.$content.sink { value in
            guard value === fresh else { return }
            reader.receiveSelectionIntent(intent)
            reader.content = successor
            reader.pageURL = successor.url
        }
        defer { observer.cancel() }
        XCTAssertFalse(reader.publishUpdatedContent(fresh, permitsPublication: { fence() }))
        XCTAssertTrue(reader.content === successor)
        XCTAssertEqual(reader.contentTitle, "Successor")
        XCTAssertEqual(reader.locationBarTitle, "Successor")
        XCTAssertFalse(fence())
    }

    @MainActor
    func testNativeSnippetTitlePublicationStopsBeforeRefreshingReentrantSuccessor() async throws {
        let reader = ReaderContent()
        let first = nativeSnippet("native-title-first"), successor = nativeSnippet("native-title-next", title: "Successor")
        let fresh = nativeSnippet("native-title-first", title: "Saved")
        try await reader.load(url: first.url) { _ in first }
        let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: first.url))
        let intent = try nativeIntent(from: first.url, to: successor.url)
        let observer = reader.contentTitleSubject.sink { title in
            guard title == "Saved" else { return }
            reader.receiveSelectionIntent(intent)
            reader.content = successor
            reader.pageURL = successor.url
        }
        defer { observer.cancel() }
        XCTAssertFalse(reader.publishUpdatedContent(fresh, permitsPublication: { fence() }))
        XCTAssertTrue(reader.content === successor)
        XCTAssertEqual(reader.contentTitle, "Successor")
        XCTAssertEqual(reader.locationBarTitle, "Successor")
    }
}

extension ReaderSnippetTitleTests {
    @MainActor
    func testCapturedNativeSnippetSaveCannotReviveDeletedStorageRows() async throws {
        try await withSnippetRealm { _ in
            let loaded = try await ReaderContentLoader.load(html: "<p>Native delete fixture</p>")
            let row = try XCTUnwrap(loaded as? HistoryRecord)
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: row))
            let reader = ReaderContent()
            try await reader.load(url: row.url) { _ in row }
            let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: row.url))
            try await row.delete()
            let changed = try await ReaderContentLoader.updateSnippetContent(
                contentURL: row.url, title: "Must not revive", html: "<p>Must not revive</p>",
                storage: storage, permitsCommit: fence)
            XCTAssertFalse(changed)
            XCTAssertTrue(fence(), "Deletion is enforced by storage, independently of logical navigation")
            let live = try await ReaderContentLoader.loadAll(url: row.url)
            XCTAssertTrue(live.isEmpty)
        }
    }
}

extension ReaderSnippetTitleTests {
    @MainActor
    func testCapturedNativeSnippetSaveRejectsRecreatedPrimaryKey() async throws {
        try await withSnippetRealm { _ in
            let loaded = try await ReaderContentLoader.load(html: "<p>Original physical row</p>")
            let row = try XCTUnwrap(loaded as? HistoryRecord)
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: row))
            let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: row))
            let url = row.url
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: reference.realmConfiguration, storageAdmission: reference.storageAdmission)
                try await realm.asyncWrite {
                    let original = try XCTUnwrap(realm.object(ofType: HistoryRecord.self,
                        forPrimaryKey: reference.contentKey))
                    realm.delete(original) // Intentional physical replacement fixture.
                    let replacement = HistoryRecord()
                    replacement.compoundKey = reference.contentKey
                    replacement.url = url
                    replacement.title = "Successor row"
                    realm.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                }
            }()
            let changed = try await ReaderContentLoader.updateSnippetContent(
                contentURL: url, title: "Stale edit", html: "<p>Stale edit</p>",
                storage: storage, permitsCommit: { true })
            XCTAssertFalse(changed)
            let resolved = try await reference.resolveOnMainActor()
            XCTAssertEqual(resolved?.title, "Successor row")
        }
    }
}

extension ReaderSnippetTitleTests {
    @MainActor
    func testSuppressedBlankIntentAndLoadPreserveNativeOwnerUntilRealBlank() async throws {
        let reader = ReaderContent(), row = nativeSnippet("suppressed-native-blank")
        try await reader.load(url: row.url) { _ in row }
        let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: row.url))
        reader.suppressTransientAboutBlank(untilNextNonBlankLoad: row.url)
        let blank = URL(string: "about:blank")!
        let intent = try nativeIntent(from: row.url, to: blank)
        reader.receiveSelectionIntent(intent)
        XCTAssertTrue(fence())
        try await reader.load(url: blank, consuming: intent) { _ in
            XCTFail("Suppressed blank must not reach semantic resolution")
            return nil
        }
        XCTAssertEqual(reader.pageURL, row.url)
        reader.content = ReaderContentLoader.unsavedHome
        XCTAssertTrue(reader.content === row, "Ignored blank model publication must preserve native content")
        reader.pageURL = blank
        XCTAssertTrue(reader.isCurrentNativeContent(row.url))
        XCTAssertTrue(fence())
        reader.pageURL = row.url
        try await reader.load(url: row.url) { _ in row } // Consumes suppression.
        reader.content = ReaderContentLoader.unsavedHome
        XCTAssertFalse(fence(), "Unsuppressed direct blank model publication must retire the owner")
        try await reader.load(url: blank) { _ in ReaderContentLoader.unsavedHome }
        XCTAssertFalse(fence(), "A real blank must permanently retire the old native action")
    }

    @MainActor
    func testPendingPreProvisionalBlankIntentAndLoadPreserveNativeOwnerUntilRealBlank() async throws {
        let reader = ReaderContent(), row = nativeSnippet("pending-native-blank")
        try await reader.load(url: row.url) { _ in row }
        let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: row.url))
        let activity = WebViewReaderLoadActivity.shared, owner = NSObject(), id = UUID()
        activity.begin(id, owner: owner)
        defer { activity.end(id); withExtendedLifetime(owner) {} }
        let blank = URL(string: "about:blank")!
        let intent = try nativeIntent(from: row.url, to: blank)
        reader.receiveSelectionIntent(intent)
        XCTAssertTrue(fence())
        try await reader.load(url: blank, consuming: intent) { _ in
            XCTFail("Pending pre-provisional blank must not resolve content")
            return nil
        }
        XCTAssertEqual(reader.pageURL, row.url)
        reader.content = ReaderContentLoader.unsavedHome
        XCTAssertTrue(reader.content === row, "Ignored blank model publication must preserve native content")
        reader.pageURL = blank
        XCTAssertTrue(reader.isCurrentNativeContent(row.url))
        XCTAssertTrue(fence())
        reader.pageURL = row.url
        activity.end(id)
        let realIntent = try nativeIntent(from: row.url, to: blank)
        reader.receiveSelectionIntent(realIntent)
        XCTAssertFalse(fence(), "Without either suppression reason a blank intent retires immediately")
        try await reader.load(url: blank, consuming: realIntent) { _ in ReaderContentLoader.unsavedHome }
        try await reader.load(url: row.url) { _ in row }
        XCTAssertFalse(fence(), "Returning after real blank cannot revive the old owner")
    }

    @MainActor
    func testDirectContentAndPagePublicationsRetireNativeOwnerWithoutResolver() async throws {
        let reader = ReaderContent(), first = nativeSnippet("direct-public-first")
        let successor = nativeSnippet("direct-public-successor", title: "Successor")
        try await reader.load(url: first.url) { _ in first }
        let contentFence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: first.url))
        let contentObserver = reader.$content.sink { value in
            if value === successor { XCTAssertFalse(contentFence(), "Retire before public content delivery") }
        }
        reader.content = successor
        reader.pageURL = successor.url
        XCTAssertFalse(contentFence())
        reader.content = first
        reader.pageURL = first.url
        XCTAssertFalse(contentFence())
        let pageFence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: first.url))
        let pageObserver = reader.$pageURL.sink { url in
            if url == successor.url { XCTAssertFalse(pageFence(), "Retire before page URL delivery") }
        }
        reader.pageURL = successor.url
        reader.pageURL = first.url
        XCTAssertFalse(pageFence())
        XCTAssertTrue(reader.isCurrentNativeContent(first.url))
        contentObserver.cancel(); pageObserver.cancel()
    }

    @MainActor
    func testNilCacheEvictionAndSameContentReplacementPreserveNativeOwner() async throws {
        let reader = ReaderContent(), row = nativeSnippet("native-cache-eviction")
        try await reader.load(url: row.url) { _ in row }
        let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: row.url))
        reader.content = nil
        XCTAssertTrue(fence())
        XCTAssertTrue(reader.isCurrentNativeContent(row.url))
        let rehosted = nativeSnippet("native-cache-eviction", title: "Rehosted")
        reader.content = rehosted
        XCTAssertTrue(fence())
        XCTAssertTrue(reader.isCurrentNativeContent(row.url))
    }

    @MainActor
    private func assertReentrantNativeProjectionSuccessor(fromObjectWillChange: Bool) async throws {
        let reader = ReaderContent(), original = nativeSnippet("native-projection-first")
        let fresh = nativeSnippet("native-projection-first", title: "Saved")
        let successor = nativeSnippet("native-projection-second", title: "Successor")
        try await reader.load(url: original.url) { _ in original }
        let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: original.url))
        var selectedSuccessor = false
        func selectSuccessor() {
            guard !selectedSuccessor else { return }
            selectedSuccessor = true
            reader.content = successor
            reader.pageURL = successor.url
        }
        let observation: AnyCancellable
        if fromObjectWillChange {
            observation = reader.objectWillChange.sink {
                // Ignore the initial content notification: exercise the nested
                // projection's will-set notification after fresh backing commit.
                if reader.content === fresh { selectSuccessor() }
            }
        } else {
            observation = reader.$locationBarTitle.sink { title in
                if title == "Saved" { selectSuccessor() }
            }
        }
        defer { observation.cancel() }
        XCTAssertFalse(reader.publishUpdatedContent(fresh, permitsPublication: { fence() }))
        XCTAssertTrue(selectedSuccessor)
        XCTAssertTrue(reader.content === successor)
        XCTAssertEqual(reader.pageURL, successor.url)
        XCTAssertEqual(reader.locationBarTitle, "Successor")
        XCTAssertEqual(reader.contentTitle, "Successor")
        XCTAssertFalse(fence())
        XCTAssertTrue(reader.isCurrentNativeContent(successor.url))
    }

    @MainActor
    func testReentrantLocationBarTitleProjectionRepairsSuccessorState() async throws {
        try await assertReentrantNativeProjectionSuccessor(fromObjectWillChange: false)
    }

    @MainActor
    func testReentrantProjectionObjectWillChangeRepairsSuccessorState() async throws {
        try await assertReentrantNativeProjectionSuccessor(fromObjectWillChange: true)
    }

    @MainActor
    func testReentrantContentObjectWillChangeCannotStoreOlderPublication() async throws {
        let reader = ReaderContent(), original = nativeSnippet("native-object-first")
        let fresh = nativeSnippet("native-object-first", title: "Saved")
        let successor = nativeSnippet("native-object-second", title: "Successor")
        try await reader.load(url: original.url) { _ in original }
        let fence = try XCTUnwrap(reader.makeNativeContentCommitFence(for: original.url))
        var redirected = false
        let observer = reader.objectWillChange.sink {
            guard !redirected else { return }
            redirected = true
            reader.content = successor
            reader.pageURL = successor.url
        }
        defer { observer.cancel() }
        XCTAssertFalse(reader.publishUpdatedContent(fresh, permitsPublication: { fence() }))
        XCTAssertTrue(reader.content === successor)
        XCTAssertEqual(reader.pageURL, successor.url)
        XCTAssertEqual(reader.locationBarTitle, "Successor")
        XCTAssertEqual(reader.contentTitle, "Successor")
        var replayed: (any ReaderContentProtocol)?
        let replay = reader.$content.sink { replayed = $0 }
        defer { replay.cancel() }
        XCTAssertTrue(replayed === successor)
    }

    @MainActor
    private func assertPhysicalSnippetFileReplacement(atWritePermission: Bool, afterMutation: Bool = false) async throws {
        let replacement = makeRealmConfiguration(), retired = makeRealmConfiguration()
        try await withSnippetRealm { original in
            let loaded = try await ReaderContentLoader.load(html: "<p>Original file fixture</p>")
            let row = try XCTUnwrap(loaded as? HistoryRecord)
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: row))
            let url = row.url, key = row.compoundKey
            let originalURL = try XCTUnwrap(original.fileURL)
            let replacementURL = try XCTUnwrap(replacement.fileURL)
            let retiredURL = try XCTUnwrap(retired.fileURL)
            try await { @RealmBackgroundActor in
                let originalRealm = try await RealmBackgroundActor.shared.cachedRealm(for: original)
                let replacementRealm = try await RealmBackgroundActor.shared.cachedRealm(for: replacement)
                let replacementRow = HistoryRecord()
                replacementRow.compoundKey = key
                replacementRow.url = url
                replacementRow.title = "Replacement file row"
                replacementRow.html = "<p>Replacement bytes</p>"
                try await replacementRealm.asyncWrite {
                    replacementRealm.add(replacementRow)
                    replacementRow.refreshChangeMetadata(explicitlyModified: true)
                }
                let originalBefore = Self.snippetWriteSnapshot(in: originalRealm)
                let replacementBefore = Self.snippetWriteSnapshot(in: replacementRealm)
                let probe = SnippetPhysicalFileReplacementProbe(
                    realm: originalRealm, original: originalURL, replacement: replacementURL,
                    retired: retiredURL, afterMutation: afterMutation)
                defer {
                    // Restore fixture paths only after writer settlement so the
                    // existing canonical teardown releases the correct cache keys.
                    do { try probe.restoreFixturePaths() }
                    catch { XCTFail("Unable to restore physical-file fixture paths: \(error)") }
                }
                if !atWritePermission { try probe.replaceFile() }
                do {
                    _ = try await ReaderContentLoader.updateCapturedSnippetRecords(
                        contentURL: url, storage: storage,
                        permitsCommit: { atWritePermission ? probe.permitsCommit() : true }
                    ) { object in
                        object.title = "Stale file save"
                        object.html = "<p>Must roll back</p>"
                        return true
                    }
                    XCTFail("Captured snippet storage must reject physical file replacement at the same URL")
                } catch RealmBackgroundActorError.realmFileChangedDuringOpen {
                    // Expected: the captured inode, rather than the URL, owns this save.
                }
                XCTAssertNil(probe.failure)
                XCTAssertTrue(probe.didReplace)
                XCTAssertEqual(Self.snippetWriteSnapshot(in: replacementRealm), replacementBefore,
                               "Replacement rows and pending mutation generations must remain untouched")
                XCTAssertEqual(Self.snippetWriteSnapshot(in: originalRealm), originalBefore,
                               "This single original store must roll back provisional fields and journals")
            }()
        }
    }

    @MainActor
    func testCapturedSnippetStorageRejectsPhysicalFileReplacementAfterCapture() async throws {
        try await assertPhysicalSnippetFileReplacement(atWritePermission: false)
    }

    @MainActor
    func testCapturedSnippetStorageRejectsPhysicalFileReplacementAtWriterAdmission() async throws {
        try await assertPhysicalSnippetFileReplacement(atWritePermission: true)
    }

    @MainActor
    func testCapturedSnippetStorageRejectsPhysicalFileReplacementAtFinalPermission() async throws {
        try await assertPhysicalSnippetFileReplacement(atWritePermission: true, afterMutation: true)
    }
}

/// Called only on RealmBackgroundActor by the actual shared snippet writer.
/// Files are moved within unique fixture paths; existing fixture teardown owns
/// each path, including the retained original. No replacement data is copied.
private final class SnippetPhysicalFileReplacementProbe: @unchecked Sendable {
    let realm: Realm
    let original: URL, replacement: URL, retired: URL
    let afterMutation: Bool
    private(set) var didReplace = false
    private var retiredOriginal = false
    private(set) var failure: Error?
    init(realm: Realm, original: URL, replacement: URL, retired: URL, afterMutation: Bool) {
        self.realm = realm; self.original = original; self.replacement = replacement
        self.retired = retired; self.afterMutation = afterMutation
    }
    func replaceFile() throws {
        try FileManager.default.moveItem(at: original, to: retired)
        retiredOriginal = true
        try FileManager.default.moveItem(at: replacement, to: original)
        didReplace = true
    }
    func restoreFixturePaths() throws {
        if didReplace { try FileManager.default.moveItem(at: original, to: replacement) }
        if retiredOriginal { try FileManager.default.moveItem(at: retired, to: original) }
    }
    func permitsCommit() -> Bool {
        guard realm.isInWriteTransaction, !didReplace else { return true }
        if afterMutation, !realm.objects(HistoryRecord.self).contains(where: { $0.title == "Stale file save" }) {
            return true
        }
        do { try replaceFile(); return true }
        catch { failure = error; return false }
    }
}

/// Every held resolver is released and its task joined within its test, including
/// assertion-failure paths. Releasing before wait is also safe.
private actor NativeSnippetNegativeLoadGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

extension ReaderSnippetTitleTests {
    @MainActor
    func testHeldDirectPredecessorCannotRegainNativeOwnerAfterSuccessorIntent() async throws {
        let reader = ReaderContent()
        let first = nativeSnippet("held-native-predecessor")
        let successor = nativeSnippet("held-native-successor", title: "Successor")
        let intent = try nativeIntent(from: first.url, to: successor.url)
        let gate = NativeSnippetNegativeLoadGate()
        let entered = expectation(description: "direct predecessor resolver entered")
        let predecessor = Task { @MainActor in
            do {
                try await reader.load(url: first.url) { _ in
                    entered.fulfill()
                    await gate.wait()
                    return first
                }
            } catch is CancellationError {
                // A superseded predecessor may cancel or finish without publication.
            } catch { XCTFail("Unexpected predecessor error: \(error)") }
        }
        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(entry, .completed)
        // No throwing unwrap after starting the held task: all paths join it.
        let originalFence = reader.makeNativeContentCommitFence(for: first.url)
        XCTAssertNotNil(originalFence)
        let handoff = reader.receiveSelectionIntent(intent)
        XCTAssertNotNil(handoff)
        XCTAssertTrue(handoff?.permitsCapture == true)
        XCTAssertFalse(originalFence?() ?? true)
        await gate.release()
        await predecessor.value
        XCTAssertNil(reader.makeNativeContentCommitFence(for: first.url),
                     "A retired direct resolver must not mint a fresh native mutation owner")
        XCTAssertTrue(handoff?.permitsCapture == true,
                      "Retiring A's native result must preserve B's predecessor handoff")
        if handoff != nil {
            do {
                try await reader.load(url: successor.url, consuming: intent) { _ in successor }
            } catch { XCTFail("Current successor intent must still consume its handoff: \(error)") }
            XCTAssertTrue(reader.content === successor)
            XCTAssertEqual(reader.pageURL, successor.url)
            XCTAssertTrue(reader.makeNativeContentCommitFence(for: successor.url)?() == true)
        }
        XCTAssertFalse(originalFence?() ?? true)
    }

    @MainActor
    func testFreshDirectRoundTripCannotCoalesceWithNativeRetiredPredecessor() async throws {
        let reader = ReaderContent()
        let old = nativeSnippet("held-native-roundtrip", title: "Retired result")
        let fresh = nativeSnippet("held-native-roundtrip", title: "Fresh result")
        let other = nativeSnippet("held-native-roundtrip-other")
        let intent = try nativeIntent(from: old.url, to: other.url)
        let oldGate = NativeSnippetNegativeLoadGate(), freshGate = NativeSnippetNegativeLoadGate()
        let oldEntered = expectation(description: "old direct resolver entered")
        let freshEntered = expectation(description: "fresh direct resolver entered independently")
        let predecessor = Task { @MainActor in
            do {
                try await reader.load(url: old.url) { _ in
                    oldEntered.fulfill()
                    await oldGate.wait()
                    return old
                }
            } catch is CancellationError { }
            catch { XCTFail("Unexpected retired load error: \(error)") }
        }
        let oldEntry = await XCTWaiter.fulfillment(of: [oldEntered], timeout: 5)
        XCTAssertEqual(oldEntry, .completed)
        let oldFence = reader.makeNativeContentCommitFence(for: old.url)
        XCTAssertNotNil(oldFence)
        XCTAssertNotNil(reader.receiveSelectionIntent(intent))
        XCTAssertFalse(oldFence?() ?? true)
        let replacement = Task { @MainActor in
            do {
                try await reader.load(url: fresh.url) { _ in
                    freshEntered.fulfill()
                    await freshGate.wait()
                    return fresh
                }
            } catch { XCTFail("Explicit fresh round-trip request must succeed: \(error)") }
        }
        let independentEntry = await XCTWaiter.fulfillment(of: [freshEntered], timeout: 5)
        XCTAssertEqual(independentEntry, .completed,
                       "A fresh direct request must not join the resolver retired by another native intent")
        await freshGate.release()
        if independentEntry == .completed {
            // The real independent resolver can finish before the old result.
            await replacement.value
            XCTAssertTrue(reader.content === fresh)
            await oldGate.release()
            await predecessor.value
        } else {
            // Expected-red coalescing must fail assertions, not hang on oldGate.
            await oldGate.release()
            await predecessor.value
            await replacement.value
        }
        XCTAssertTrue(reader.content === fresh, "Late predecessor completion must not displace the fresh result")
        XCTAssertEqual(reader.contentTitle, "Fresh result")
        XCTAssertFalse(oldFence?() ?? true)
    }
}


extension ReaderSnippetTitleTests {
    @MainActor
    func testCapturedSnippetTargetURLChangeBeforeWriterRejectsAllRepresentations() async throws {
        try await withSnippetRealm { configuration in
            let loaded = try await ReaderContentLoader.load(html: "<p>Original retargeted snippet</p>")
            let original = try XCTUnwrap(loaded as? HistoryRecord)
            let url = original.url, key = original.compoundKey
            let successorURL = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "retargeted-before-writer"))
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: original))
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                try Self.seedSnippetRepresentations(url: url, in: realm)
                let target = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
                // Keep the same physical row while replacing its logical target.
                try realm.write { target.url = successorURL }
                let before = Self.snippetWriteSnapshot(in: realm)
                let changed = try await ReaderContentLoader.updateCapturedSnippetRecords(
                    contentURL: url, storage: storage, permitsCommit: { true },
                    mutate: { Self.writeSnippetTestContent($0) })
                XCTAssertFalse(changed, "A retargeted original row must not authorize edits to its old representations")
                XCTAssertEqual(target.url, successorURL)
                XCTAssertEqual(Self.snippetWriteSnapshot(in: realm), before)
            }()
        }
    }

    @MainActor
    func testCapturedSnippetTargetURLChangeAtFinalPermissionRollsBackAllRepresentations() async throws {
        try await withSnippetRealm { configuration in
            let loaded = try await ReaderContentLoader.load(html: "<p>Original final retarget snippet</p>")
            let original = try XCTUnwrap(loaded as? HistoryRecord)
            let url = original.url, key = original.compoundKey
            let successorURL = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "retargeted-at-final-permission"))
            let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: original))
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                try Self.seedSnippetRepresentations(url: url, in: realm)
                let target = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
                let before = Self.snippetWriteSnapshot(in: realm)
                let probe = SnippetTargetURLChangeProbe(row: target, destination: successorURL)
                var rejected = false
                do {
                    _ = try await ReaderContentLoader.updateCapturedSnippetRecords(
                        contentURL: url, storage: storage,
                        permitsCommit: { probe.permitsCommit() },
                        mutate: { Self.writeSnippetTestContent($0) })
                } catch is CancellationError { rejected = true }
                XCTAssertTrue(probe.changedTarget, "The final-permission fault must execute inside the actual writer")
                XCTAssertTrue(rejected, "A final target change must roll back the write")
                XCTAssertEqual(target.url, url)
                XCTAssertEqual(Self.snippetWriteSnapshot(in: realm), before)
            }()
        }
    }
}

/// Invoked synchronously by the shared Realm writer on RealmBackgroundActor.
private final class SnippetTargetURLChangeProbe: @unchecked Sendable {
    let row: HistoryRecord
    let destination: URL
    private(set) var changedTarget = false
    init(row: HistoryRecord, destination: URL) {
        self.row = row
        self.destination = destination
    }
    func permitsCommit() -> Bool {
        if !changedTarget, row.realm?.isInWriteTransaction == true, row.title == "Atomic saved" {
            row.url = destination
            changedTarget = true
        }
        return true
    }
}

#if DEBUG
extension ReaderSnippetTitleTests {
    @MainActor
    func testPropagatedReaderMetadataRejectsRetiredAccountAndJournalsCurrentSuccessor() async throws {
        try await withSnippetRealm { configuration in
            let realm = try await Realm(configuration: configuration)
            let row = HistoryRecord()
            row.url = URL(string: "https://example.com/account-owned-metadata")!
            row.title = ""
            row.updateCompoundKey()
            try realm.write { realm.add(row) }
            let session = Session.ephemeralForTesting()
            session.authenticated(authToken: "metadata-a", userID: 101)
            let access = AccountSessionAccess(session: session)
            let original = access.snapshot
            session.authenticated(authToken: "metadata-b", userID: 101)
            let before = realm.objects(BigSyncPendingMutation.self).count
            do {
                try await ReaderContentLoader.propagateReaderModeDefaults(
                    for: row.url, excludingPrimaryKey: "another-row", primaryClassName: "HistoryRecord",
                    readabilityHTML: "<p>Retired HTML</p>", resolvedTitle: "Retired title",
                    account: (access, original), permitsCommit: { true }
                )
                XCTFail("A renewed authorization must retire the queued metadata writer")
            } catch is CancellationError { }
            try await realm.asyncRefresh()
            XCTAssertEqual(row.title, "")
            XCTAssertNil(row.html)
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, before)

            try await ReaderContentLoader.propagateReaderModeDefaults(
                for: row.url, excludingPrimaryKey: "another-row", primaryClassName: "HistoryRecord",
                readabilityHTML: "<p>Current HTML</p>", resolvedTitle: "Current title",
                account: (access, access.snapshot), permitsCommit: { true }
            )
            try await realm.asyncRefresh()
            XCTAssertEqual(row.title, "Current title")
            XCTAssertEqual(row.html, "<p>Current HTML</p>")
            XCTAssertTrue(row.isReaderModeByDefault)
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, before + 1,
                           "The accepted managed-row mutation must journal in its transaction")
        }
    }
}
#endif

#if DEBUG
/// Uses the real Session on MainActor while a real Realm writer runs on its
/// owning actor. Semaphores coordinate only the test; no production lock/hook.
private final class ReaderWriteRenewalProbe: @unchecked Sendable {
    let session: Session
    let attempted = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let renewed = XCTestExpectation(description: "Same-user authorization renewed")

    init(session: Session) { self.session = session }

    func requestRenewal() {
        Task { @MainActor in
            self.attempted.signal()
            self.session.authenticated(authToken: "writer-renewed", userID: 101)
            self.completed.signal()
            self.renewed.fulfill()
        }
        XCTAssertEqual(attempted.wait(timeout: .now() + 5), .success)
    }
}

/// Captured Realm values remain on their owning actor; Sendable only carries
/// the synchronous permission closure through the writer API.
private final class ReaderProvisionalWriteRenewal: @unchecked Sendable {
    let realm: Realm
    let row: HistoryRecord
    let probe: ReaderWriteRenewalProbe
    let expectedMutations: Int

    init(realm: Realm, row: HistoryRecord, probe: ReaderWriteRenewalProbe, expectedMutations: Int) {
        self.realm = realm
        self.row = row
        self.probe = probe
        self.expectedMutations = expectedMutations
    }

    func permitsCommit() -> Bool {
        if row.title == "Provisional" {
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, expectedMutations)
            probe.requestRenewal()
            XCTAssertEqual(probe.completed.wait(timeout: .now() + 5), .success)
        }
        return true
    }
}

/// Token is created, used and invalidated only on RealmBackgroundActor.
private final class ReaderWriteCommitWitness: @unchecked Sendable {
    var token: NotificationToken?
    var observed = false
}

extension ReaderSnippetTitleTests {
    @MainActor
    func testCapturedWritersExcludeSameUserRenewalThroughDurableCommit() async throws {
        for writer in ["snippet", "secondary", "primary"] {
            try await withSnippetRealm { configuration in
                let realm = try await Realm(configuration: configuration)
                let row = HistoryRecord()
                row.url = writer == "snippet"
                    ? ReaderContentLoader.snippetURL(key: UUID().uuidString)!
                    : URL(string: "https://example.com/commit-\(writer)")!
                row.title = ""
                row.updateCompoundKey()
                let bookmark = Bookmark()
                bookmark.url = row.url
                bookmark.title = row.title
                bookmark.updateCompoundKey()
                try realm.write {
                    realm.add(row)
                    if writer == "snippet" { realm.add(bookmark) }
                }
                let expectedMutations = writer == "snippet" ? 2 : 1
                let key = row.compoundKey, url = row.url
                let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: row))
                let session = Session.ephemeralForTesting()
                session.authenticated(authToken: "writer-original", userID: 101)
                let access = AccountSessionAccess(session: session), probe = ReaderWriteRenewalProbe(session: session)
                let account = (access: access, snapshot: access.snapshot)
                let witness = ReaderWriteCommitWitness()
                try await { @RealmBackgroundActor in
                    let writerRealm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                    witness.token = writerRealm.observe { notification, committedRealm in
                        guard notification == .didChange, !witness.observed,
                              committedRealm.object(ofType: HistoryRecord.self, forPrimaryKey: key)?.title == "Committed" else { return }
                        witness.observed = true
                        XCTAssertFalse(committedRealm.isInWriteTransaction)
                        XCTAssertEqual(committedRealm.objects(BigSyncPendingMutation.self).count, expectedMutations)
                        // This notification is delivered by the SDK's actual
                        // commitWrite. Renewal must wait until it returns and the
                        // publication fence is released. No Session read here.
                        probe.requestRenewal()
                        XCTAssertEqual(probe.completed.wait(timeout: .now() + 0.1), .timedOut,
                                       "\(writer) released account exclusion before durable commit returned")
                    }
                }()
                do {
                    if writer == "primary" {
                        try await row.asyncWrite(account: account) { _, live in
                            live.title = "Committed"
                            live.refreshChangeMetadata(explicitlyModified: true)
                        }
                    } else if writer == "secondary" {
                        try await ReaderContentLoader.propagateReaderModeDefaults(
                            for: url, excludingPrimaryKey: "other", primaryClassName: "HistoryRecord",
                            readabilityHTML: "<p>Committed</p>", resolvedTitle: "Committed",
                            account: account, permitsCommit: { true })
                    } else {
                        let changed = try await ReaderContentLoader.updateSnippetTitle(
                            contentURL: url, title: "Committed", storage: storage,
                            account: account, permitsCommit: { true })
                        XCTAssertTrue(changed)
                    }
                } catch {
                    await { @RealmBackgroundActor in witness.token?.invalidate() }()
                    throw error
                }
                await { @RealmBackgroundActor in
                    witness.token?.invalidate()
                    XCTAssertTrue(witness.observed, "Must observe the actual \(writer) durable commit")
                }()
                await self.fulfillment(of: [probe.renewed], timeout: 5)
                await realm.asyncRefresh()
                XCTAssertEqual(row.title, "Committed")
                if writer == "snippet" { XCTAssertEqual(bookmark.title, "Committed") }
                XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, expectedMutations)
                XCTAssertNotEqual(access.snapshot, account.snapshot)
            }
        }
    }

    @MainActor
    func testSameUserRenewalAfterProvisionalMutationRollsBackRowsAndJournal() async throws {
        for writer in ["snippet", "secondary", "primary"] {
            try await withSnippetRealm { configuration in
                let realm = try await Realm(configuration: configuration)
                let row = HistoryRecord()
                row.url = writer == "snippet" ? ReaderContentLoader.snippetURL(key: UUID().uuidString)!
                    : URL(string: "https://example.com/rollback-\(writer)")!
                row.title = "Original"
                row.updateCompoundKey()
                let bookmark = Bookmark()
                bookmark.url = row.url
                bookmark.title = row.title
                bookmark.updateCompoundKey()
                try realm.write {
                    realm.add(row)
                    if writer == "snippet" { realm.add(bookmark) }
                }
                let expectedMutations = writer == "snippet" ? 2 : 1
                let key = row.compoundKey, url = row.url
                let storage = try XCTUnwrap(ReaderContentLoader.SnippetStorage(content: row))
                let session = Session.ephemeralForTesting()
                session.authenticated(authToken: "writer-original", userID: 101)
                let access = AccountSessionAccess(session: session), probe = ReaderWriteRenewalProbe(session: session)
                let account = (access: access, snapshot: access.snapshot)
                do {
                    if writer == "primary" {
                        try await row.asyncWrite(account: account) { _, live in
                            live.title = "Provisional"
                            live.refreshChangeMetadata(explicitlyModified: true)
                            probe.requestRenewal()
                            XCTAssertEqual(probe.completed.wait(timeout: .now() + 5), .success)
                        }
                    } else {
                        try await { @RealmBackgroundActor in
                            let writerRealm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                            let live = try XCTUnwrap(writerRealm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
                            // Permission is evaluated after provisional mutation
                            // and journal refresh at the actual shared boundary.
                            let permission = ReaderProvisionalWriteRenewal(
                                realm: writerRealm, row: live, probe: probe, expectedMutations: expectedMutations)
                            if writer == "snippet" {
                                _ = try await ReaderContentLoader.updateCapturedSnippetRecords(
                                    contentURL: url, storage: storage, account: account,
                                    permitsCommit: { permission.permitsCommit() }, mutate: { $0.title = "Provisional"; return true })
                            } else {
                                try await ReaderContentLoader.updateContent(
                                    url: url, account: account, permitsCommit: { permission.permitsCommit() },
                                    mutate: { $0.title = "Provisional"; return true })
                            }
                        }()
                    }
                    XCTFail("\(writer) must propagate failed account publication")
                } catch is CancellationError { }
                await self.fulfillment(of: [probe.renewed], timeout: 5)
                await realm.asyncRefresh()
                XCTAssertEqual(row.title, "Original")
                if writer == "snippet" { XCTAssertEqual(bookmark.title, "Original") }
                XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty,
                              "Rejected \(writer) metadata must not leave an upload generation")
            }
        }
    }

    @MainActor
    func testQueuedSecondaryReaderPropagationRejectsRetargetedPhysicalRow() async throws {
        try await assertQueuedSecondaryReaderPropagation(recreate: false)
    }

    @MainActor
    func testQueuedSecondaryReaderPropagationRejectsRecreatedPhysicalRow() async throws {
        try await assertQueuedSecondaryReaderPropagation(recreate: true)
    }

    @MainActor
    private func assertQueuedSecondaryReaderPropagation(recreate: Bool) async throws {
        try await withSnippetRealm { configuration in
            let realm = try await Realm(configuration: configuration)
            let row = HistoryRecord()
            row.url = URL(string: "https://example.com/queued-secondary")!
            row.title = ""
            row.updateCompoundKey()
            try realm.write { realm.add(row) }
            let key = row.compoundKey, url = row.url, created = row.createdAt
            let session = Session.ephemeralForTesting()
            session.authenticated(authToken: "queued-secondary", userID: 101)
            let access = AccountSessionAccess(session: session)
            let account = (access: access, snapshot: access.snapshot)
            let barrier = BookmarkWriterOwnerBarrier()
            let owner = Task {
                try await barrier.hold(configuration: configuration) { ownerRealm in
                    let original = try XCTUnwrap(ownerRealm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
                    if recreate {
                        ownerRealm.delete(original)
                        let successor = HistoryRecord()
                        successor.url = url
                        successor.createdAt = created
                        successor.compoundKey = key
                        successor.title = ""
                        ownerRealm.add(successor)
                    } else {
                        original.url = URL(string: "https://example.com/retargeted-secondary")!
                    }
                }
            }
            defer { barrier.release() }
            await self.fulfillment(of: [barrier.entered], timeout: 5)
            let submitted = self.expectation(description: "Secondary writer queued after physical row capture")
            submitted.assertForOverFulfill = false
            let propagation = Task {
                try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    try await ReaderContentLoader.propagateReaderModeDefaults(
                        for: url, excludingPrimaryKey: "other", primaryClassName: "HistoryRecord",
                        readabilityHTML: "<p>Old document</p>", resolvedTitle: "Old document",
                        account: account, permitsCommit: { true })
                }
            }
            self.addTeardownBlock {
                barrier.release()
                _ = await owner.result
                _ = await propagation.result
            }
            await self.fulfillment(of: [submitted], timeout: 5)
            barrier.release()
            try await owner.value
            try await propagation.value
            await realm.asyncRefresh()
            let successor = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            XCTAssertEqual(successor.title, "")
            XCTAssertNil(successor.html)
            XCTAssertFalse(successor.isReaderModeByDefault)
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
            XCTAssertEqual(access.snapshot, account.snapshot)
            if recreate {
                XCTAssertTrue(row.isInvalidated)
                XCTAssertEqual(successor.url, url)
                XCTAssertEqual(successor.createdAt, created)
            } else {
                XCTAssertNotEqual(successor.url, url)
            }
        }
    }

    @MainActor
    func testScopedPropagationPreservesCanonicalHistoryAndHTTPSFeedDiscovery() async throws {
        try await withSnippetRealm { configuration in
            let realm = try await Realm(configuration: configuration)
            let url = URL(string: "https://example.com/canonical-propagation")!
            let history = HistoryRecord()
            history.url = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: url))
            history.title = ""
            history.updateCompoundKey()
            let feed = FeedEntry()
            feed.url = URL(string: "http://example.com/canonical-propagation")!
            feed.compoundKey = "http-feed-propagation"
            let unrelated = FeedEntry()
            unrelated.url = URL(string: "https://example.com/unrelated")!
            unrelated.compoundKey = "unrelated-feed-propagation"
            try realm.write { realm.add([history]); realm.add([feed, unrelated]) }
            let session = Session.ephemeralForTesting()
            let access = AccountSessionAccess(session: session)
            try await ReaderContentLoader.propagateReaderModeDefaults(
                for: url, excludingPrimaryKey: "other", primaryClassName: "HistoryRecord",
                readabilityHTML: "<p>Canonical HTML</p>", resolvedTitle: "Canonical title",
                account: (access, access.snapshot), permitsCommit: { true })
            await realm.asyncRefresh()
            XCTAssertEqual(history.title, "Canonical title")
            XCTAssertEqual(feed.title, "Canonical title")
            XCTAssertEqual(history.html, "<p>Canonical HTML</p>")
            XCTAssertEqual(feed.html, "<p>Canonical HTML</p>")
            XCTAssertEqual(unrelated.title, "")
            XCTAssertNil(unrelated.html)
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 2)
        }
    }

    @MainActor
    func testPrimaryMetadataMutationFailurePropagatesAndRollsBackJournal() async throws {
        enum Failure: Error { case metadata }
        try await withSnippetRealm { configuration in
            let realm = try await Realm(configuration: configuration)
            let row = HistoryRecord()
            row.url = URL(string: "https://example.com/throwing-primary")!
            row.title = "Original"
            row.updateCompoundKey()
            try realm.write { realm.add(row) }
            let session = Session.ephemeralForTesting() // Guest is intentionally admitted.
            let access = AccountSessionAccess(session: session)
            do {
                try await row.asyncWrite(account: (access, access.snapshot)) { _, live in
                    live.title = "Provisional"
                    live.refreshChangeMetadata(explicitlyModified: true)
                    throw Failure.metadata
                }
                XCTFail("The owning metadata failure must escape the write callback")
            } catch Failure.metadata { }
            await realm.asyncRefresh()
            XCTAssertEqual(row.title, "Original")
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
            try await row.asyncWrite(account: (access, access.snapshot)) { _, live in
                live.title = "Guest saved"
                live.refreshChangeMetadata(explicitlyModified: true)
            }
            XCTAssertEqual(row.title, "Guest saved")
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
        }
    }
}
#endif
