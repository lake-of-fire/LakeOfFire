import XCTest
import BigSyncKit
import RealmSwift
import RealmSwiftGaps
@testable import LakeOfFireContent
import LakeOfFireReader
import SwiftUIWebView

final class ReaderSnippetTitleTests: XCTestCase {
    private func makeRealmConfiguration(name: String = UUID().uuidString) -> Realm.Configuration {
        let realmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("realm")
        addTeardownBlock {
            let sidecarExtensions = ["realm", "realm.lock", "realm.management", "realm.note"]
            for ext in sidecarExtensions {
                try? FileManager.default.removeItem(
                    at: realmURL.deletingPathExtension().appendingPathExtension(ext)
                )
            }
        }
        var configuration = Realm.Configuration(fileURL: realmURL)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
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
                storage: storage, permitsCommit: { true }
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
