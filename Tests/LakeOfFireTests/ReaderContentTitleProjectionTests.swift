#if DEBUG
import Combine
import Foundation
import XCTest
@testable import LakeOfFireContent

/// Uses real unmanaged HistoryRecords and the existing production load owner.
/// No user Realm, history persistence or global resolver is opened or replaced.
@MainActor
final class ReaderContentTitleProjectionTests: XCTestCase {
    private func record(_ path: String, title: String) -> HistoryRecord {
        let record = HistoryRecord()
        record.url = URL(string: "https://title-projection.test/\(path)")!
        record.title = title
        record.updateCompoundKey()
        return record
    }

    @MainActor
    private final class Gate {
        private let arrival = XCTestExpectation(description: "Title content resolver entered")
        private var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !entered else { XCTFail("One-shot title resolver entered twice"); return }
            entered = true
            arrival.fulfill()
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            let result = await XCTWaiter.fulfillment(of: [arrival], timeout: 5)
            if result != .completed { release(); XCTFail("Title resolver never entered") }
        }

        func release() {
            guard !released else { return }
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testMissingModelDoesNotBecomeAuthoritativeEmptyTitle() async throws {
        let reader = ReaderContent()
        XCTAssertNil(reader.captureTitleSnapshot())
        reader.pageURL = URL(string: "https://title-projection.test/not-loaded")!
        reader.refreshObservedContentState()
        XCTAssertNil(reader.captureTitleSnapshot())

        let empty = record("authoritative-empty", title: "")
        var snapshots = [ReaderContentTitleSnapshot?]()
        var legacy = [String]()
        let titleSubscription = reader.titleSnapshotSubject.sink { snapshots.append($0) }
        let legacySubscription = reader.contentTitleSubject.sink { legacy.append($0) }
        defer { titleSubscription.cancel(); legacySubscription.cancel() }
        try await reader.load(url: empty.url) { _ in empty }
        let snapshot = try XCTUnwrap(reader.captureTitleSnapshot())
        XCTAssertEqual(snapshot.rawTitle, "")
        XCTAssertEqual(snapshot.contentURL, empty.url)
        XCTAssertTrue(snapshot.isCurrent)
        XCTAssertEqual(snapshots.compactMap { $0 }.last?.rawTitle, "")
        XCTAssertTrue(legacy.isEmpty, "The legacy String subject retains its nonempty-event contract")
    }

    func testEmptyTitleChangePublishesTypedValueWhileMissingModelPublishesUnavailability() async throws {
        let reader = ReaderContent(), row = record("editable", title: "Original")
        var snapshots = [ReaderContentTitleSnapshot?]()
        var legacy = [String]()
        let typed = reader.titleSnapshotSubject.sink { snapshots.append($0) }
        let strings = reader.contentTitleSubject.sink { legacy.append($0) }
        defer { typed.cancel(); strings.cancel() }
        try await reader.load(url: row.url) { _ in row }
        let original = try XCTUnwrap(reader.captureTitleSnapshot())
        row.title = ""
        reader.refreshObservedContentState()
        let empty = try XCTUnwrap(reader.captureTitleSnapshot())
        XCTAssertFalse(original.isCurrent)
        XCTAssertEqual(original.rawTitle, "Original", "A captured event never rereads a later title")
        XCTAssertEqual(empty.rawTitle, "")
        XCTAssertTrue(empty.isCurrent)
        XCTAssertEqual(legacy, ["Original"])
        reader.content = nil
        reader.refreshObservedContentState()
        XCTAssertNil(reader.captureTitleSnapshot())
        XCTAssertFalse(empty.isCurrent)
        XCTAssertTrue(snapshots.last.map { $0 == nil } ?? false,
            "Unavailable source is a separate typed event, not an empty-title instruction")
        XCTAssertEqual(legacy, ["Original"])
    }

    func testLoadingRetiresOriginalSnapshotAndCannotBorrowItsTitle() async throws {
        let reader = ReaderContent(), gate = Gate()
        let first = record("first", title: "First")
        let second = record("second", title: "")
        try await reader.load(url: first.url) { _ in first }
        let original = try XCTUnwrap(reader.captureTitleSnapshot())
        let loading = Task { @MainActor in
            try await reader.load(url: second.url) { _ in
                await gate.wait()
                return second
            }
        }
        await gate.waitUntilEntered()
        XCTAssertNil(reader.captureTitleSnapshot(), "Loading has no authoritative title to send")
        XCTAssertFalse(original.isCurrent)
        gate.release()
        try await loading.value
        let loaded = try XCTUnwrap(reader.captureTitleSnapshot())
        XCTAssertEqual(loaded.rawTitle, "")
        XCTAssertEqual(loaded.contentURL, second.url)
        XCTAssertNotEqual(loaded.identity.selectionID, original.identity.selectionID)
        XCTAssertTrue(loaded.isCurrent)
    }

    func testClipboardFlagChangePublishesWithoutChangingTitleOrLegacyEvents() async throws {
        let reader = ReaderContent(), row = record("clipboard", title: "Shared title")
        var typedEvents = [ReaderContentTitleSnapshot?]()
        var legacyEvents = [String]()
        let typed = reader.titleSnapshotSubject.sink { typedEvents.append($0) }
        let legacy = reader.contentTitleSubject.sink { legacyEvents.append($0) }
        defer { typed.cancel(); legacy.cancel() }
        try await reader.load(url: row.url) { _ in row }
        let original = try XCTUnwrap(reader.captureTitleSnapshot())
        row.isFromClipboard = true
        reader.refreshObservedContentState()
        let changed = try XCTUnwrap(reader.captureTitleSnapshot())
        XCTAssertFalse(original.needsClipboardIndicator)
        XCTAssertTrue(changed.needsClipboardIndicator)
        XCTAssertEqual(changed.rawTitle, original.rawTitle)
        XCTAssertNotEqual(changed.identity, original.identity)
        XCTAssertFalse(original.isCurrent)
        XCTAssertEqual(legacyEvents, ["Shared title"])
        XCTAssertEqual(typedEvents.compactMap { $0 }.count, 2)
    }

    func testSnippetPrefixSuppressionChangesIndependentlyOfTitleString() async throws {
        let reader = ReaderContent(), row = record("snippet-placeholder", title: "Generated prefix")
        row.url = try XCTUnwrap(ReaderContentLoader.snippetURL(key: UUID().uuidString))
        row.isTitlePrefixOfContent = true
        row.updateCompoundKey()
        try await reader.load(url: row.url) { _ in row }
        let generated = try XCTUnwrap(reader.captureTitleSnapshot())
        XCTAssertTrue(generated.hidesReaderTitle)
        XCTAssertTrue(generated.needsClipboardIndicator)
        row.isTitlePrefixOfContent = false
        reader.refreshObservedContentState()
        let authored = try XCTUnwrap(reader.captureTitleSnapshot())
        XCTAssertFalse(authored.hidesReaderTitle)
        XCTAssertTrue(authored.needsClipboardIndicator)
        XCTAssertEqual(authored.rawTitle, generated.rawTitle)
        XCTAssertNotEqual(authored.identity, generated.identity)
        XCTAssertFalse(generated.isCurrent)
    }

    func testPageMismatchAndSameURLPhysicalReplacementCannotReuseOldSnapshot() async throws {
        let reader = ReaderContent(), row = record("original", title: "Original")
        try await reader.load(url: row.url) { _ in row }
        let original = try XCTUnwrap(reader.captureTitleSnapshot())
        let replacement = record("original", title: "Original")
        reader.content = replacement
        let replaced = try XCTUnwrap(reader.captureTitleSnapshot())
        XCTAssertFalse(original.isCurrent)
        XCTAssertTrue(replaced.isCurrent)
        XCTAssertNotEqual(original.identity, replaced.identity,
            "Same URL/title cannot grant a different model the old source's authority")
        reader.pageURL = URL(string: "https://title-projection.test/different")!
        XCTAssertNil(reader.captureTitleSnapshot())
        XCTAssertFalse(replaced.isCurrent)
        reader.pageURL = replacement.url
        XCTAssertTrue(try XCTUnwrap(reader.captureTitleSnapshot()).isCurrent)
        XCTAssertFalse(original.isCurrent)
    }

    func testExactTitleBytesAndPureCapturePreserveSourceIdentity() async throws {
        let reader = ReaderContent(), row = record("unicode", title: "é")
        try await reader.load(url: row.url) { _ in row }
        let first = try XCTUnwrap(reader.captureTitleSnapshot())
        let repeated = try XCTUnwrap(reader.captureTitleSnapshot())
        XCTAssertEqual(first.identity, repeated.identity, "Recovery capture does not invent another generation")
        row.title = "e\u{301}"
        reader.refreshObservedContentState()
        let changed = try XCTUnwrap(reader.captureTitleSnapshot())
        XCTAssertEqual(Array(changed.rawTitle.utf8), Array("e\u{301}".utf8))
        XCTAssertNotEqual(first.identity, changed.identity)
        XCTAssertFalse(first.isCurrent)
        XCTAssertTrue(changed.isCurrent)
    }
}
#endif
