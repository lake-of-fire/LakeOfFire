import Foundation
import LakeOfFireCore
import RealmSwift
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
}
