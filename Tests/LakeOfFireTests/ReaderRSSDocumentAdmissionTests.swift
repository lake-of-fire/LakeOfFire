import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader
@testable import SwiftUIWebView

private actor ReaderRSSLookupGate {
    private(set) var entered = false
    private var released = false
    let entrySignal: ReaderDocumentTestSignal
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(entrySignal: ReaderDocumentTestSignal) { self.entrySignal = entrySignal }

    func wait() async {
        entered = true
        entrySignal.signal()
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

@MainActor
final class ReaderRSSDocumentAdmissionTests: XCTestCase {
    private let targetURL = URL(string: "https://example.com/early-rss")!

    private func bind(_ caller: WebViewScriptCaller) {
        caller.installBinding(
            ownedBy: UUID(), asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil }
        )
    }

    private func capture(_ caller: WebViewScriptCaller) throws -> ReaderDocumentMutationAdmission {
        try XCTUnwrap(ReaderDocumentMutationAdmission.capture(
            targetURL: targetURL,
            requiring: try XCTUnwrap(caller.currentJavaScriptBindingToken),
            scriptCaller: caller
        ))
    }

    private func withLoaderRealm(
        _ body: (Realm, ReaderRSSLookupGate) async throws -> Void
    ) async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let oldBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let oldHistory = ReaderContentLoader.historyRealmConfiguration
        let oldFeed = ReaderContentLoader.feedEntryRealmConfiguration
        let oldProviders = ReaderContentLoader.additionalContentProviders
        let oldResolver = ReaderContent.contentResolver
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = oldBookmark
            ReaderContentLoader.historyRealmConfiguration = oldHistory
            ReaderContentLoader.feedEntryRealmConfiguration = oldFeed
            ReaderContentLoader.additionalContentProviders = oldProviders
            ReaderContent.contentResolver = oldResolver
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let gate = ReaderRSSLookupGate(entrySignal: ReaderDocumentTestSignal(
            expectation(description: "RSS lookup entered or completed")
        ))
        ReaderContentLoader.additionalContentProviders = [ReaderContentAdditionalProvider(
            id: "early-rss-suspension", load: { _ in await gate.wait(); return [] }
        )]
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        do {
            try await body(realm, gate)
        } catch {
            await gate.release()
            await ReaderContentLoader.resetTransientCachesForTesting()
            throw error
        }
        await gate.release()
        await ReaderContentLoader.resetTransientCachesForTesting()
    }

    private func boundedValue<Value>(
        _ task: Task<Value, Error>, completion: ReaderDocumentTestSignal
    ) async throws -> Value {
        await fulfillment(of: [completion.expectation], timeout: 2)
        guard completion.hasSignalled else {
            task.cancel()
            throw ReaderDocumentTestError.producerDidNotFinish
        }
        return try await task.value
    }

    private func requireEntry<Value>(
        _ gate: ReaderRSSLookupGate,
        producer: Task<Value, Error>,
        completion: ReaderDocumentTestSignal
    ) async throws {
        let entry = await gate.entrySignal
        await fulfillment(of: [entry.expectation], timeout: 2)
        guard await gate.entered else {
            producer.cancel()
            await gate.release()
            _ = try await boundedValue(producer, completion: completion)
            throw ReaderDocumentTestError.producerDidNotEnter
        }
    }

    func testReplacedReceiptCannotCreateEarlyHistory() async throws {
        try await withLoaderRealm { realm, gate in
            let caller = WebViewScriptCaller()
            bind(caller)
            let admission = try capture(caller)
            let completion = ReaderDocumentTestSignal(expectation(description: "RSS producer completed"))
            let entry = await gate.entrySignal
            let lookup = Task { @MainActor in
                defer { completion.signal(); entry.signal() }
                return try await ReaderContentLoader.getContent(
                    forURL: self.targetURL, source: "rss-regression",
                    admittingMutation: { admission.permitsMutation }
                )
            }
            try await requireEntry(gate, producer: lookup, completion: completion)
            bind(caller)
            await gate.release()
            do {
                _ = try await boundedValue(lookup, completion: completion)
                XCTFail("A replaced receipt must not publish content")
            } catch is CancellationError {}
            await realm.asyncRefresh()
            XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
        }
    }

    func testCancelledReceiptCannotCreateEarlyHistory() async throws {
        try await withLoaderRealm { realm, gate in
            let caller = WebViewScriptCaller()
            bind(caller)
            let admission = try capture(caller)
            let completion = ReaderDocumentTestSignal(expectation(description: "RSS producer completed"))
            let entry = await gate.entrySignal
            let lookup = Task { @MainActor in
                defer { completion.signal(); entry.signal() }
                return try await ReaderContentLoader.getContent(
                    forURL: self.targetURL, source: "rss-regression",
                    admittingMutation: { admission.permitsMutation }
                )
            }
            try await requireEntry(gate, producer: lookup, completion: completion)
            lookup.cancel()
            await gate.release()
            do {
                _ = try await boundedValue(lookup, completion: completion)
                XCTFail("A cancelled receipt must not publish content")
            } catch is CancellationError {}
            await realm.asyncRefresh()
            XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
        }
    }

    func testCurrentEarlyReceiptCreatesHistoryWithoutRecordingAnotherVisit() async throws {
        try await withLoaderRealm { realm, gate in
            let caller = WebViewScriptCaller()
            bind(caller)
            let admission = try capture(caller)
            let completion = ReaderDocumentTestSignal(expectation(description: "RSS producer completed"))
            let entry = await gate.entrySignal
            let lookup = Task { @MainActor in
                defer { completion.signal(); entry.signal() }
                return try await ReaderContentLoader.getContent(
                    forURL: self.targetURL, source: "rss-regression",
                    admittingMutation: { admission.permitsMutation }
                )
            }
            try await requireEntry(gate, producer: lookup, completion: completion)
            await gate.release()
            let deliveredContent = try await boundedValue(lookup, completion: completion)
            let content = try XCTUnwrap(deliveredContent)
            XCTAssertEqual(content.url, targetURL)
            await realm.asyncRefresh()
            let history = try XCTUnwrap(realm.objects(HistoryRecord.self).first)
            XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
            let lastVisitedAt = history.lastVisitedAt
            // The second lookup is no longer suspended and may use read caches.
            ReaderContentLoader.additionalContentProviders = []
            let secondCompletion = ReaderDocumentTestSignal(expectation(description: "second RSS producer completed"))
            let secondLookup = Task { @MainActor in
                defer { secondCompletion.signal() }
                return try await ReaderContentLoader.getContent(
                    forURL: self.targetURL, source: "rss-second-receipt",
                    admittingMutation: { admission.permitsMutation }
                )
            }
            _ = try await boundedValue(secondLookup, completion: secondCompletion)
            await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
            XCTAssertEqual(history.lastVisitedAt, lastVisitedAt)
        }
    }

    func testOverlappingSameURLReceiptsRetainIndependentMutationAuthority() async throws {
        try await withLoaderRealm { realm, gate in
            let oldCaller = WebViewScriptCaller()
            bind(oldCaller)
            let oldAdmission = try capture(oldCaller)
            let oldCompletion = ReaderDocumentTestSignal(expectation(description: "old RSS producer completed"))
            let entry = await gate.entrySignal
            let oldLookup = Task { @MainActor in
                defer { oldCompletion.signal(); entry.signal() }
                return try await ReaderContentLoader.getContent(
                    forURL: self.targetURL, source: "rss-old-window",
                    admittingMutation: { oldAdmission.permitsMutation }
                )
            }
            try await requireEntry(gate, producer: oldLookup, completion: oldCompletion)
            let freshCaller = WebViewScriptCaller()
            bind(freshCaller)
            let freshAdmission = try capture(freshCaller)
            let freshStarted = expectation(description: "fresh receipt checked its own admission")
            let signal = ReaderDocumentTestSignal(freshStarted)
            let freshCompletion = ReaderDocumentTestSignal(expectation(description: "fresh RSS producer completed"))
            let freshLookup = Task { @MainActor in
                defer { freshCompletion.signal(); signal.signal() }
                return try await ReaderContentLoader.getContent(
                    forURL: self.targetURL, source: "rss-fresh-window",
                    admittingMutation: {
                        signal.signal()
                        return freshAdmission.permitsMutation
                    }
                )
            }
            await fulfillment(of: [freshStarted], timeout: 2)
            bind(oldCaller)
            await gate.release()
            do {
                _ = try await boundedValue(oldLookup, completion: oldCompletion)
                XCTFail("The old receipt must remain revoked")
            } catch is CancellationError {}
            let deliveredContent = try await boundedValue(freshLookup, completion: freshCompletion)
            let content = try XCTUnwrap(deliveredContent)
            XCTAssertEqual(content.url, targetURL)
            await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
        }
    }

    func testNativeMetadataReadinessLagCannotBypassUnavailableDocumentIdentity() async throws {
        try await withLoaderRealm { realm, _ in
            let bookmark = Bookmark()
            bookmark.url = targetURL
            bookmark.title = "Original"
            bookmark.updateCompoundKey()
            try realm.write { realm.add(bookmark) }
            let viewModel = ReaderViewModel(
                realmConfiguration: realm.configuration, systemScripts: [], observeLibraryChanges: false
            )
            viewModel.state.pageURL = targetURL
            let completion = ReaderDocumentTestSignal(expectation(description: "unavailable identity rejected"))
            let update = Task { @MainActor in
                defer { completion.signal() }
                viewModel.scriptCaller.installBinding(
                    ownedBy: UUID(), asyncCaller: { _, _, _, _ in .init(nil) },
                    unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil },
                    documentGenerationProvider: { nil }
                )
                XCTAssertTrue(viewModel.scriptCaller.canEvaluateJavaScript)
                XCTAssertFalse(viewModel.scriptCaller.hasAsyncCaller)
                XCTAssertNil(viewModel.scriptCaller.currentJavaScriptBindingToken)
                try await viewModel.pageMetadataUpdated(title: "Must Not Persist")
            }
            try await boundedValue(update, completion: completion)
            await realm.asyncRefresh()
            XCTAssertEqual(bookmark.title, "Original")
            XCTAssertNil(bookmark.explicitlyModifiedAt)
        }
    }

    func testDeniedDemotionCannotChangeHistoryOrMutationMetadata() async throws {
        try await withLoaderRealm { realm, _ in
            let history = HistoryRecord()
            history.url = targetURL
            history.updateCompoundKey()
            try realm.write { realm.add(history) }
            let key = history.compoundKey
            let originalModifiedAt = history.modifiedAt
            let configuration = realm.configuration
            let completion = ReaderDocumentTestSignal(expectation(description: "denied demotion completed"))
            let refresh = Task { @RealmBackgroundActor in
                defer { completion.signal() }
                let writerRealm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let stored = try XCTUnwrap(writerRealm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
                try await stored.refreshDemotedStatus(admittingMutation: { false })
            }
            do {
                try await boundedValue(refresh, completion: completion)
                XCTFail("Denied demotion must be cancelled")
            } catch is CancellationError {}
            await realm.asyncRefresh()
            XCTAssertNil(history.isDemoted)
            XCTAssertEqual(history.modifiedAt, originalModifiedAt)
            XCTAssertNil(history.explicitlyModifiedAt)
        }
    }
}
