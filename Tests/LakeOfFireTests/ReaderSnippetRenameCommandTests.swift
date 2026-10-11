import XCTest
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
@testable import LakeOfFireContent

/// Production ReaderContent and Realm writer; only temporary storage is configured.
final class ReaderSnippetRenameCommandTests: XCTestCase {
    private enum Failure: Error { case expected }

    @MainActor
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

    @MainActor
    private func snippetHTML(token: String = "") -> String {
        """
        <article>
            <h1>Updated via Snippet Helper</h1>
            <p>This snippet body is persisted in compressed storage.</p>
            <p>\(token)</p>
        </article>
        """
    }

    @MainActor
    private func withSnippetRealm<T>(
        _ body: @escaping (Realm.Configuration) async throws -> T
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
    private func updatedSnippetHTML(token: String) -> String {
        "<article><h1>Changed persisted heading</h1><p>\(token)</p></article>"
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

            let renamed = try await reader.updateContentTitle("  My library notes  ", for: snippet.url)

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

            let repeated = try await reader.updateContentTitle("My library notes", for: snippet.url)
            let empty = try await reader.updateContentTitle(" \n ", for: snippet.url)

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

            let renamed = try await reader.updateContentTitle("Frozen snippet renamed", for: frozen.url)

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

            let renamed = try await reader.updateContentTitle(generatedTitle, for: frozen.url)

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
    func testSameTitleRepairsPrefixMetadataFromPersistedHTML() async throws {
        try await withSnippetRealm { _ in
            let loaded = try await ReaderContentLoader.load(html: self.snippetHTML(token: "metadata-only"))
            let snippet = try XCTUnwrap(loaded)
            let realm = try XCTUnwrap(snippet.realm)
            let generatedTitle = snippet.title
            try await realm.asyncWrite { snippet.isTitlePrefixOfContent = false }
            let reader = ReaderContent()
            reader.content = snippet
            reader.pageURL = snippet.url
            // Legacy callers must not skip a same-title correction based on UI text.
            await reader.updateContentTitle(generatedTitle)
            XCTAssertTrue(try XCTUnwrap(reader.content).isTitlePrefixOfContent)
            XCTAssertTrue(reader.snippetTitleIsGeneratedFromPrefix)
        }
    }

    @MainActor
    func testFailedPersistenceLookupDoesNotPublishRequestedTitle() async throws {
        try await withSnippetRealm { _ in
            let loaded = try await ReaderContentLoader.load(html: self.snippetHTML(token: "failure"))
            let snippet = try XCTUnwrap(loaded)
            let reader = ReaderContent()
            reader.content = snippet
            reader.pageURL = snippet.url
            let oldTitle = snippet.title
            let oldPrefix = snippet.isTitlePrefixOfContent
            let oldChrome = reader.locationBarTitle
            let oldModifiedAt = snippet.explicitlyModifiedAt
            let previousProviders = ReaderContentLoader.additionalContentProviders
            defer { ReaderContentLoader.additionalContentProviders = previousProviders }
            ReaderContentLoader.additionalContentProviders = [
                ReaderContentAdditionalProvider(id: "rename-failure") { _ in throw Failure.expected }
            ]
            await ReaderContentLoader.resetTransientCachesForTesting()
            do {
                try await reader.updateContentTitle("Must not publish", for: snippet.url)
                XCTFail("Expected persisted lookup to fail")
            } catch Failure.expected {}
            XCTAssertTrue(reader.content === snippet)
            XCTAssertEqual(snippet.title, oldTitle)
            XCTAssertEqual(snippet.isTitlePrefixOfContent, oldPrefix)
            XCTAssertEqual(reader.contentTitle, oldTitle)
            XCTAssertEqual(reader.locationBarTitle, oldChrome)
            XCTAssertEqual(snippet.explicitlyModifiedAt, oldModifiedAt)
        }
    }
    @MainActor
    private final class LookupGate {
        private let entry = XCTestExpectation(description: "rename lookup entered")
        private let release = XCTestExpectation(description: "rename lookup released")
        private var entered = false
        private var released = false
        func wait() async {
            entered = true
            entry.fulfill()
            if !released {
                let status = await XCTWaiter.fulfillment(of: [release], timeout: 5)
                if status != .completed { open(); XCTFail("Rename release timed out") }
            }
        }
        func waitForEntry() async {
            if !entered {
                let status = await XCTWaiter.fulfillment(of: [entry], timeout: 5)
                if status != .completed { open(); XCTFail("Rename lookup timed out") }
            }
        }
        func open() { if !released { released = true; release.fulfill() } }
    }

    @MainActor
    func testSuspendedRenameCannotRefreshSuccessorDisplay() async throws {
        try await withSnippetRealm { _ in
            let firstLoad = try await ReaderContentLoader.load(html: self.snippetHTML(token: "suspended-first"))
            let first = try XCTUnwrap(firstLoad)
            let secondLoad = try await ReaderContentLoader.load(html: self.snippetHTML(token: "suspended-second"))
            let second = try XCTUnwrap(secondLoad)
            let reader = ReaderContent()
            reader.content = first
            reader.pageURL = first.url
            let gate = LookupGate()
            defer { gate.open() }
            let previousProviders = ReaderContentLoader.additionalContentProviders
            defer { ReaderContentLoader.additionalContentProviders = previousProviders }
            ReaderContentLoader.additionalContentProviders = [
                ReaderContentAdditionalProvider(id: "rename-suspension") { _ in
                    await gate.wait()
                    return []
                }
            ]
            await ReaderContentLoader.resetTransientCachesForTesting()
            let rename = Task { @MainActor in
                try await reader.updateContentTitle("Captured first title", for: first.url)
            }
            await gate.waitForEntry()
            reader.preloadResolvedContent(second, for: second.url)
            try await reader.load(url: second.url)
            let secondTitle = reader.contentTitle
            let secondChrome = reader.locationBarTitle
            gate.open()
            let changed = try await rename.value
            XCTAssertTrue(changed)
            XCTAssertTrue(reader.content === second)
            XCTAssertEqual(reader.contentTitle, secondTitle)
            XCTAssertEqual(reader.locationBarTitle, secondChrome)
            let realm = try XCTUnwrap(first.realm)
            await realm.asyncRefresh()
            XCTAssertEqual(first.title, "Captured first title")
        }
    }


}
