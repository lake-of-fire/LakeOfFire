import Foundation
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps
import SwiftUIWebView
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderContentURLLifetimeTests: XCTestCase {
    private enum Stage: CaseIterable, Equatable {
        case originalHTML
        case storedLookup
        case matchingHTML
    }

    private enum Retirement: CaseIterable {
        case removal
        case sameKeyRecreation
        case retarget
    }

    private enum ProducerError: Error, Equatable {
        case unavailable
    }

    @MainActor
    private final class Gate {
        let entered = XCTestExpectation(description: "URL producer suspended")
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }

        func open() {
            isOpen = true
            let continuation = continuation
            self.continuation = nil
            continuation?.resume()
        }
    }

    @MainActor
    private struct Fixture {
        let realm: Realm
        let original: HistoryRecord
        let matching: Bookmark
        let manager = ReaderFileManager()

        init() throws {
            realm = try Realm(configuration: Realm.Configuration(
                inMemoryIdentifier: "ReaderContentURLLifetime-\(UUID().uuidString)",
                objectTypes: [HistoryRecord.self, Bookmark.self]
            ))
            original = HistoryRecord()
            original.url = URL(string: "https://example.com/url-lifetime")!
            original.isReaderModeByDefault = false
            original.updateCompoundKey()
            matching = Bookmark()
            matching.url = original.url
            matching.isReaderModeByDefault = true
            matching.updateCompoundKey()
            try realm.write {
                realm.add(original)
                realm.add(matching)
            }
        }
    }

    @MainActor
    private final class ModeHandler: ReaderModeLoadHandling {
        var publications = 0

        func beginReaderModeLoad(for url: URL, suppressSpinner: Bool, reason: String?) {
            publications += 1
        }

        func cancelReaderModeLoad(for url: URL?) {
            publications += 1
        }
    }

    private func retire(
        _ record: Bookmark,
        in realm: Realm,
        by retirement: Retirement
    ) throws {
        let url = record.url
        let key = record.compoundKey
        let createdAt = record.createdAt
        let isHistory = record is HistoryRecord
        try realm.write {
            switch retirement {
            case .removal:
                realm.delete(record)
            case .sameKeyRecreation:
                realm.delete(record)
                let replacement: Bookmark = isHistory ? HistoryRecord() : Bookmark()
                replacement.url = url
                replacement.compoundKey = key
                replacement.createdAt = createdAt
                replacement.isReaderModeByDefault = true
                realm.add(replacement)
            case .retarget:
                record.url = URL(string: "https://example.com/replaced-url")!
            }
        }
    }

    private func assertCancelled(
        _ operation: @MainActor () async throws -> URL?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await operation()
            XCTFail("Retired URL resolution must throw CancellationError", file: file, line: line)
        } catch is CancellationError {
        }
    }

    private func verifyOriginalRetirement(
        at stage: Stage,
        retirement: Retirement,
        producerFails: Bool,
        cancelTask: Bool = false
    ) async throws {
        let fixture = try Fixture()
        let gate = Gate()
        let originalURL = fixture.original.url
        var originalProbes = 0
        var lookups = 0
        var matchingProbes = 0
        let task = Task { @MainActor in
            try await ReaderContentLoader.load(
                content: fixture.original,
                readerFileManager: fixture.manager,
                probeHTML: { candidate in
                    if ObjectIdentifier(candidate) == ObjectIdentifier(fixture.original) {
                        originalProbes += 1
                        if stage == .originalHTML {
                            await gate.wait()
                            if producerFails { throw ProducerError.unavailable }
                        }
                        return false
                    }
                    matchingProbes += 1
                    if stage == .matchingHTML {
                        await gate.wait()
                        if producerFails { throw ProducerError.unavailable }
                    }
                    return true
                },
                lookupStoredContent: { requestedURL in
                    XCTAssertEqual(requestedURL, originalURL)
                    lookups += 1
                    if stage == .storedLookup {
                        await gate.wait()
                        if producerFails { throw ProducerError.unavailable }
                    }
                    return fixture.matching
                }
            )
        }
        addTeardownBlock {
            task.cancel()
            await gate.open()
            _ = try? await task.value
        }
        await fulfillment(of: [gate.entered], timeout: 1)
        try retire(fixture.original, in: fixture.realm, by: retirement)
        if cancelTask { task.cancel() }
        gate.open()
        try await assertCancelled { try await task.value }
        XCTAssertEqual(originalProbes, 1)
        XCTAssertEqual(lookups, stage == .originalHTML ? 0 : 1)
        XCTAssertEqual(matchingProbes, stage == .matchingHTML ? 1 : 0)
    }

    func testOriginalRetirementDuringHTMLProbeRejectsSuccessAndFailure() async throws {
        for retirement in Retirement.allCases {
            for producerFails in [false, true] {
                try await verifyOriginalRetirement(
                    at: .originalHTML, retirement: retirement, producerFails: producerFails
                )
            }
        }
    }

    func testOriginalRetirementDuringStoredLookupRejectsSuccessAndFailure() async throws {
        for retirement in Retirement.allCases {
            for producerFails in [false, true] {
                try await verifyOriginalRetirement(
                    at: .storedLookup, retirement: retirement, producerFails: producerFails
                )
            }
        }
    }

    func testOriginalRetirementDuringMatchingHTMLProbeRejectsSuccessAndFailure() async throws {
        for retirement in Retirement.allCases {
            for producerFails in [false, true] {
                try await verifyOriginalRetirement(
                    at: .matchingHTML, retirement: retirement, producerFails: producerFails
                )
            }
        }
    }

    func testCancellationAtEveryProducerCannotReadADeletedOriginal() async throws {
        for stage in Stage.allCases {
            try await verifyOriginalRetirement(
                at: stage, retirement: .removal, producerFails: false, cancelTask: true
            )
        }
    }

    func testAlreadyInvalidatedOriginalDoesNotStartEitherProducer() async throws {
        let fixture = try Fixture()
        try fixture.realm.write { fixture.realm.delete(fixture.original) }
        try await assertCancelled {
            try await ReaderContentLoader.load(
                content: fixture.original,
                readerFileManager: fixture.manager,
                probeHTML: { _ in XCTFail("Invalidated row must not probe"); return false },
                lookupStoredContent: { _ in XCTFail("Invalidated row must not look up"); return nil }
            )
        }
    }

    func testPublicLoaderRejectsInvalidatedOriginalBeforeDefaultProducers() async throws {
        let fixture = try Fixture()
        try fixture.realm.write { fixture.realm.delete(fixture.original) }
        try await assertCancelled {
            try await ReaderContentLoader.load(
                content: fixture.original,
                readerFileManager: fixture.manager
            )
        }
    }

    func testAlreadyCancelledCallerDoesNotReadOrStartResolution() async throws {
        let fixture = try Fixture()
        let task = Task { @MainActor in
            try await ReaderContentLoader.load(
                content: fixture.original,
                readerFileManager: fixture.manager,
                probeHTML: { _ in XCTFail("Cancelled entry must not probe"); return false },
                lookupStoredContent: { _ in XCTFail("Cancelled entry must not look up"); return nil }
            )
        }
        task.cancel()
        try fixture.realm.write { fixture.realm.delete(fixture.original) }
        try await assertCancelled { try await task.value }
    }

    func testRetiredOptionalMatchFallsBackToOriginalCapturedURL() async throws {
        for retirement in Retirement.allCases {
            let fixture = try Fixture()
            let originalURL = fixture.original.url
            var probes = 0
            let result = try await ReaderContentLoader.load(
                content: fixture.original,
                readerFileManager: fixture.manager,
                probeHTML: { candidate in
                    probes += 1
                    guard ObjectIdentifier(candidate) == ObjectIdentifier(fixture.matching) else {
                        return false
                    }
                    try self.retire(fixture.matching, in: fixture.realm, by: retirement)
                    return true
                },
                lookupStoredContent: { _ in fixture.matching }
            )
            XCTAssertEqual(result, originalURL)
            XCTAssertEqual(probes, 2)
            XCTAssertFalse(fixture.original.isInvalidated)
            XCTAssertEqual(fixture.original.url, originalURL)
        }
    }

    func testInvalidatedOptionalMatchAtLookupDeliveryIsNotProbed() async throws {
        let fixture = try Fixture()
        let originalURL = fixture.original.url
        var probes = 0
        let result = try await ReaderContentLoader.load(
            content: fixture.original,
            readerFileManager: fixture.manager,
            probeHTML: { candidate in
                probes += 1
                XCTAssertEqual(ObjectIdentifier(candidate), ObjectIdentifier(fixture.original))
                return false
            },
            lookupStoredContent: { _ in
                try fixture.realm.write { fixture.realm.delete(fixture.matching) }
                return fixture.matching
            }
        )
        XCTAssertEqual(result, originalURL)
        XCTAssertEqual(probes, 1)
    }

    func testCurrentMatchingProbeFailurePreservesBestEffortOriginalFallback() async throws {
        let fixture = try Fixture()
        let originalURL = fixture.original.url
        let result = try await ReaderContentLoader.load(
            content: fixture.original,
            readerFileManager: fixture.manager,
            probeHTML: { candidate in
                if ObjectIdentifier(candidate) == ObjectIdentifier(fixture.matching) {
                    throw ProducerError.unavailable
                }
                return false
            },
            lookupStoredContent: { _ in fixture.matching }
        )
        XCTAssertEqual(result, originalURL)
    }

    func testCurrentOriginalProbeAndStoredLookupFailuresStillPropagate() async throws {
        for failedStage in [Stage.originalHTML, .storedLookup] {
            let fixture = try Fixture()
            do {
                _ = try await ReaderContentLoader.load(
                    content: fixture.original,
                    readerFileManager: fixture.manager,
                    probeHTML: { _ in
                        if failedStage == .originalHTML { throw ProducerError.unavailable }
                        return false
                    },
                    lookupStoredContent: { _ in throw ProducerError.unavailable }
                )
                XCTFail("A current producer failure must propagate")
            } catch {
                XCTAssertEqual(error as? ProducerError, .unavailable)
            }
        }
    }

    func testHealthyStoredMatchRetainsLoaderRoutingAndCanRetryAfterFailure() async throws {
        let fixture = try Fixture()
        let originalURL = fixture.original.url
        do {
            _ = try await ReaderContentLoader.load(
                content: fixture.original,
                readerFileManager: fixture.manager,
                probeHTML: { _ in false },
                lookupStoredContent: { _ in throw ProducerError.unavailable }
            )
            XCTFail("Expected first lookup to fail")
        } catch {
            XCTAssertEqual(error as? ProducerError, .unavailable)
        }
        let result = try await ReaderContentLoader.load(
            content: fixture.original,
            readerFileManager: fixture.manager,
            probeHTML: { candidate in
                ObjectIdentifier(candidate) == ObjectIdentifier(fixture.matching)
            },
            lookupStoredContent: { requestedURL in
                XCTAssertEqual(requestedURL, originalURL)
                return fixture.matching
            }
        )
        XCTAssertEqual(result, ReaderContentLoader.readerLoaderURL(for: originalURL))
    }

    func testCurrentRoutingKeepsSnippetHTTPReaderFileAndEBookPolicy() async throws {
        let cases: [(url: String, hasHTML: Bool, readerDefault: Bool, usesLoader: Bool)] = [
            ("internal://local/snippet?key=url-lifetime", true, false, true),
            ("internal://local/snippet?key=url-lifetime", false, false, false),
            ("https://example.com/current", true, true, true),
            ("https://example.com/current", false, false, false),
            ("reader-file://file/load/local/current.txt", true, false, true),
            ("reader-file://file/load/local/current.txt", false, false, false),
            ("ebook://local/current.epub", true, true, false),
            ("about:blank", false, false, false),
        ]
        for value in cases {
            let fixture = try Fixture()
            let url = try XCTUnwrap(URL(string: value.url))
            try fixture.realm.write {
                fixture.original.url = url
                fixture.original.isReaderModeByDefault = value.readerDefault
            }
            var lookups = 0
            let result = try await ReaderContentLoader.load(
                content: fixture.original,
                readerFileManager: fixture.manager,
                probeHTML: { _ in value.hasHTML },
                lookupStoredContent: { requestedURL in
                    XCTAssertEqual(requestedURL, url)
                    lookups += 1
                    return nil
                }
            )
            XCTAssertEqual(result, value.usesLoader ? ReaderContentLoader.readerLoaderURL(for: url) : url)
            XCTAssertEqual(lookups, value.url == "https://example.com/current" && !value.usesLoader ? 1 : 0)
        }
    }

    func testTtsuReaderBookFastPathDoesNotStartHTMLOrStoredLookup() async throws {
        let fixture = try Fixture()
        let url = URL(string: "ttsu://reader/current-book")!
        try fixture.realm.write { fixture.original.url = url }
        let result = try await ReaderContentLoader.load(
            content: fixture.original,
            readerFileManager: fixture.manager,
            probeHTML: { _ in XCTFail("Reader-book fast path must not probe"); return false },
            lookupStoredContent: { _ in XCTFail("Reader-book fast path must not look up"); return nil }
        )
        XCTAssertEqual(result, ReaderContentLoader.readerLoaderURL(for: url))
    }

    func testSoftDeletedOriginalRetainsCurrentPageURLPolicy() async throws {
        let fixture = try Fixture()
        let originalURL = fixture.original.url
        try fixture.realm.write { fixture.original.isDeleted = true }
        let result = try await ReaderContentLoader.load(
            content: fixture.original,
            readerFileManager: fixture.manager,
            probeHTML: { _ in false },
            lookupStoredContent: { _ in nil }
        )
        XCTAssertEqual(result, originalURL)
        XCTAssertFalse(fixture.original.isInvalidated)
    }

    func testRealLoaderRetirementIsQuietAtNavigatorInsteadOfReloadFallback() async throws {
        let fixture = try Fixture()
        let gate = Gate()
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        var dispatches = 0
        var callerFallbacks = 0
        let task = Task { @MainActor in
            do {
                try await navigator.loadResolvedContent(
                    content: fixture.original,
                    readerModeViewModel: handler,
                    willDispatchLoad: { dispatches += 1 },
                    resolveURL: {
                        try await ReaderContentLoader.load(
                            content: fixture.original,
                            readerFileManager: fixture.manager,
                            probeHTML: { _ in false },
                            lookupStoredContent: { _ in
                                await gate.wait()
                                return nil
                            }
                        )
                    },
                    resolvePreviousContent: { _ in
                        XCTFail("Retired URL producer must not prefetch")
                        return nil
                    }
                )
            } catch {
                callerFallbacks += 1
            }
        }
        addTeardownBlock {
            task.cancel()
            await gate.open()
            await task.value
        }
        await fulfillment(of: [gate.entered], timeout: 1)
        try fixture.realm.write { fixture.realm.delete(fixture.original) }
        gate.open()
        await task.value
        XCTAssertEqual(callerFallbacks, 0)
        XCTAssertEqual(handler.publications, 0)
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    @MainActor
    private struct StoredFixture {
        let configuration: Realm.Configuration
        let realm: Realm
        let original: HistoryRecord
        let matching: Bookmark?
        let manager = ReaderFileManager()
    }

    private actor DiscoveryRecorder {
        private(set) var count = 0

        func record() {
            count += 1
        }
    }

    private func makeStoredFixture(includeBookmark: Bool = true) async throws -> StoredFixture {
        let originalHistory = ReaderContentLoader.historyRealmConfiguration
        let originalBookmarks = ReaderContentLoader.bookmarkRealmConfiguration
        let originalFeeds = ReaderContentLoader.feedEntryRealmConfiguration
        let originalProviders = ReaderContentLoader.additionalContentProviders
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "ReaderStoredURLLifetime-\(UUID().uuidString)",
            objectTypes: [HistoryRecord.self, Bookmark.self, ContentFile.self,
                          FeedEntry.self, Feed.self, MediaTranscript.self]
        )
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let realm = try Realm(configuration: configuration)
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.additionalContentProviders = []
        addTeardownBlock {
            await ReaderContentLoader.resetTransientCachesForTesting()
            await MainActor.run {
                ReaderContentLoader.historyRealmConfiguration = originalHistory
                ReaderContentLoader.bookmarkRealmConfiguration = originalBookmarks
                ReaderContentLoader.feedEntryRealmConfiguration = originalFeeds
                ReaderContentLoader.additionalContentProviders = originalProviders
            }
        }
        await ReaderContentLoader.resetTransientCachesForTesting()

        let original = HistoryRecord()
        original.url = URL(string: "https://example.com/stored-url-lifetime")!
        original.createdAt = Date(timeIntervalSince1970: 100)
        original.lastVisitedAt = original.createdAt
        original.isDemoted = false
        original.isReaderModeByDefault = false
        original.updateCompoundKey()
        let matching: Bookmark?
        if includeBookmark {
            let bookmark = Bookmark()
            bookmark.url = original.url
            bookmark.createdAt = Date(timeIntervalSince1970: 200)
            bookmark.isReaderModeByDefault = true
            bookmark.rssContainsFullContent = true
            bookmark.html = "<html><body><p>Stored optional article</p></body></html>"
            bookmark.updateCompoundKey()
            matching = bookmark
        } else {
            matching = nil
        }
        try realm.write {
            realm.add(original)
            if let matching { realm.add(matching) }
        }
        return StoredFixture(configuration: configuration, realm: realm,
                             original: original, matching: matching)
    }

    func testPublicCachedMatchRetargetFallsBackAndFreshSourceCanRetry() async throws {
        let fixture = try await makeStoredFixture()
        let matching = try XCTUnwrap(fixture.matching)
        let originalURL = fixture.original.url
        let replacementURL = URL(string: "https://example.com/new-stored-source")!
        let recorder = DiscoveryRecorder()
        ReaderContentLoader.registerAdditionalContentProvider(.init(id: "cache-hit-control") { _ in
            await recorder.record()
            return []
        })
        let primed = try await ReaderContentLoader.lookupStoredContent(url: originalURL)
        XCTAssertTrue(primed is Bookmark && !(primed is HistoryRecord))
        XCTAssertEqual(primed?.url, originalURL)
        let originalKey = matching.compoundKey
        try fixture.realm.write { matching.url = replacementURL }

        let result = try await ReaderContentLoader.load(
            content: fixture.original, readerFileManager: fixture.manager
        )
        XCTAssertEqual(result, originalURL)
        XCTAssertEqual(matching.compoundKey, originalKey)
        XCTAssertEqual(matching.url, replacementURL)
        XCTAssertEqual(fixture.original.url, originalURL)
        let discoveries = await recorder.count
        XCTAssertEqual(discoveries, 1, "The regression must exercise the completed public cache, not rediscovery")

        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        var dispatches = 0
        try await navigator.load(
            content: fixture.original,
            readerFileManager: fixture.manager,
            readerModeViewModel: handler,
            willDispatchLoad: { dispatches += 1 }
        )
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, originalURL.absoluteString)
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(handler.publications, 1)

        let fresh = try await ReaderContentLoader.lookupStoredContent(url: replacementURL)
        XCTAssertEqual(fresh?.url, replacementURL)
        let retry = try await ReaderContentLoader.load(
            content: try XCTUnwrap(fresh), readerFileManager: fixture.manager
        )
        XCTAssertEqual(retry, ReaderContentLoader.readerLoaderURL(for: replacementURL))
    }

    func testPublicDiscoveryRetargetDuringProviderAwaitPreservesOriginalFallback() async throws {
        let fixture = try await makeStoredFixture()
        let matching = try XCTUnwrap(fixture.matching)
        let originalURL = fixture.original.url
        let gate = Gate()
        ReaderContentLoader.registerAdditionalContentProvider(.init(id: "held-after-built-in-discovery") { _ in
            await gate.wait()
            return []
        })
        let task = Task { @MainActor in
            try await ReaderContentLoader.load(content: fixture.original, readerFileManager: fixture.manager)
        }
        addTeardownBlock {
            task.cancel()
            await gate.open()
            _ = try? await task.value
        }
        await fulfillment(of: [gate.entered], timeout: 1)
        try fixture.realm.write { matching.url = URL(string: "https://example.com/retargeted-during-discovery")! }
        gate.open()
        let result = try await task.value
        XCTAssertEqual(result, originalURL)
        XCTAssertEqual(fixture.original.url, originalURL)
    }

    func testProviderReferenceRetargetDuringLaterProviderAwaitPreservesOriginalFallback() async throws {
        let fixture = try await makeStoredFixture()
        let matching = try XCTUnwrap(fixture.matching)
        let originalURL = fixture.original.url
        let aliasURL = URL(string: "https://example.com/provider-selected-alias")!
        try fixture.realm.write { matching.url = aliasURL }
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: matching))
        let gate = Gate()
        ReaderContentLoader.registerAdditionalContentProvider(.init(id: "alias-owner") { _ in [reference] })
        ReaderContentLoader.registerAdditionalContentProvider(.init(id: "held-after-alias-discovery") { _ in
            await gate.wait()
            return []
        })
        let task = Task { @MainActor in
            try await ReaderContentLoader.load(content: fixture.original, readerFileManager: fixture.manager)
        }
        addTeardownBlock {
            task.cancel()
            await gate.open()
            _ = try? await task.value
        }
        await fulfillment(of: [gate.entered], timeout: 1)
        try fixture.realm.write { matching.url = URL(string: "https://example.com/retired-provider-alias")! }
        gate.open()
        let result = try await task.value
        XCTAssertEqual(result, originalURL)
    }

    func testHealthyProviderAliasAndLoaderInputKeepSelectedSource() async throws {
        let fixture = try await makeStoredFixture()
        let matching = try XCTUnwrap(fixture.matching)
        let originalURL = fixture.original.url
        let aliasURL = URL(string: "https://example.com/provider-owned-source")!
        try fixture.realm.write { matching.url = aliasURL }
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: matching))
        ReaderContentLoader.registerAdditionalContentProvider(.init(id: "healthy-alias-owner") { requestedURL in
            requestedURL == originalURL ? [reference] : []
        })
        let wrapper = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: originalURL))
        let loaded = try await ReaderContentLoader.lookupStoredContent(url: wrapper)
        XCTAssertEqual(loaded?.url, aliasURL)
        let result = try await ReaderContentLoader.load(
            content: fixture.original, readerFileManager: fixture.manager
        )
        XCTAssertEqual(result, ReaderContentLoader.readerLoaderURL(for: aliasURL))
    }

    func testHealthyHTTPSLookupRetainsHTTPFeedFallback() async throws {
        let fixture = try await makeStoredFixture(includeBookmark: false)
        let httpURL = URL(string: "http://example.com/stored-url-lifetime")!
        let feed = Feed()
        feed.rssUrl = URL(string: "https://example.com/feed.xml")!
        feed.iconUrl = URL(string: "https://example.com/icon.png")!
        feed.isReaderModeByDefault = true
        feed.rssContainsFullContent = true
        let entry = FeedEntry()
        entry.feedID = feed.id
        entry.url = httpURL
        entry.createdAt = Date(timeIntervalSince1970: 300)
        entry.html = "<html><body><p>HTTP feed article</p></body></html>"
        entry.updateCompoundKey()
        try fixture.realm.write {
            fixture.realm.add(feed)
            fixture.realm.add(entry)
        }
        let loaded = try await ReaderContentLoader.lookupStoredContent(url: fixture.original.url)
        XCTAssertTrue(loaded is FeedEntry)
        XCTAssertEqual(loaded?.url, httpURL)
        let result = try await ReaderContentLoader.load(
            content: fixture.original, readerFileManager: fixture.manager
        )
        XCTAssertEqual(result, ReaderContentLoader.readerLoaderURL(for: httpURL))
    }

    func testBothReferenceResolversRejectRetargetAndPreserveSoftDeletedURLPolicy() async throws {
        let fixture = try await makeStoredFixture()
        let matching = try XCTUnwrap(fixture.matching)
        let originalURL = matching.url
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: matching))
        try fixture.realm.write { matching.url = URL(string: "https://example.com/reference-retarget")! }
        let mainResolved = try await reference.resolveOnMainActor()
        XCTAssertNil(mainResolved)
        let backgroundRejected = try await { @RealmBackgroundActor in
            try await reference.resolveOnBackgroundActor() == nil
        }()
        XCTAssertTrue(backgroundRejected)

        try fixture.realm.write {
            matching.url = originalURL
            matching.isDeleted = true
        }
        let tombstone = try await reference.resolveOnMainActor()
        XCTAssertEqual(tombstone?.url, originalURL)
        XCTAssertEqual(tombstone?.isDeleted, true)
        let backgroundPreserved = try await { @RealmBackgroundActor in
            let content = try await reference.resolveOnBackgroundActor()
            return content?.url == originalURL && content?.isDeleted == true
        }()
        XCTAssertTrue(backgroundPreserved)
    }

    func testLaterReferenceRefreshCannotRecaptureEarlierRetargetedCandidate() async throws {
        let fixture = try await makeStoredFixture()
        let matching = try XCTUnwrap(fixture.matching)
        let originalURL = fixture.original.url
        let matchingReference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: matching))
        let originalReference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: fixture.original))
        let gate = Gate()
        let task = Task { @RealmBackgroundActor in
            var earlierRealm: Realm?
            return try await ReaderContentLoader.selectStoredContentReference(
                [matchingReference, originalReference],
                resolveReference: { reference in
                    if reference.contentType == HistoryRecord.self {
                        await gate.wait()
                        await earlierRealm?.asyncRefresh()
                    }
                    let content = try await reference.resolveOnBackgroundActor()
                    if reference.contentType == Bookmark.self {
                        earlierRealm = content?.realm
                    }
                    return content
                }
            )
        }
        addTeardownBlock {
            task.cancel()
            await gate.open()
            _ = try? await task.value
        }
        await fulfillment(of: [gate.entered], timeout: 1)
        try fixture.realm.write { matching.url = URL(string: "https://example.com/retargeted-before-later-refresh")! }
        gate.open()
        let selectionResult = try await task.value
        let selected = try XCTUnwrap(selectionResult)
        XCTAssertTrue(selected.contentType == HistoryRecord.self)
        let delivered = try await selected.resolveOnMainActor()
        XCTAssertEqual(delivered?.url, originalURL)
    }
}
