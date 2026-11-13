import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

@MainActor
final class ReaderContentCellLoadOwnershipTests: XCTestCase {
    func testSameKeyMetadataRevisionChangesLoadIdentity() {
        let file = item("original")
        file.modifiedAt = Date(timeIntervalSince1970: 100)
        let before = ReaderContentCellLoadIdentity(item: file, includesSource: false)
        file.title = "revised"
        file.author = "new author"
        file.modifiedAt = Date(timeIntervalSince1970: 101)
        XCTAssertNotEqual(before, ReaderContentCellLoadIdentity(item: file, includesSource: false))
    }

    func testSameKeyBackingURLChangeChangesLoadIdentity() {
        let file = item("original")
        let before = ReaderContentCellLoadIdentity(item: file, includesSource: false)
        file.url = URL(string: "reader-file://file/load/local/rebound.txt")!
        XCTAssertNotEqual(before, ReaderContentCellLoadIdentity(item: file, includesSource: false))
    }

    func testImageChangeWithoutTimestampChangeChangesLoadIdentity() {
        let file = item("original")
        let before = ReaderContentCellLoadIdentity(item: file, includesSource: false)
        file.imageUrl = URL(string: "https://example.invalid/updated-cover.png")!
        XCTAssertNotEqual(before, ReaderContentCellLoadIdentity(item: file, includesSource: false))
    }

    func testUnchangedIdentityIsStableAndSourceChoiceRemainsSignificant() {
        let file = item("original")
        let first = ReaderContentCellLoadIdentity(item: file, includesSource: false)
        XCTAssertEqual(first, ReaderContentCellLoadIdentity(item: file, includesSource: false))
        XCTAssertNotEqual(first, ReaderContentCellLoadIdentity(item: file, includesSource: true))
    }

    func testAlreadyCancelledCellCallerCannotRevokeCurrentLoad() async throws {
        let entered = expectation(description: "current image continuation registered")
        let gate = ReaderCellLoadGate(entered)
        let currentItem = item("current")
        let discardedItem = item("discarded")
        let realm = try await managedRealm([currentItem, discardedItem])
        defer { withExtendedLifetime(realm) {} }
        let currentID = currentItem.compoundKey
        let expectedImage = image("current")
        var imageCalls: [String] = []
        let model = makeModel(in: realm, imageURLLoader: { value in
            imageCalls.append(value.compoundKey)
            await gate.wait()
            return expectedImage
        })
        let current = Task { try await model.load(item: currentItem, includeSource: false) }
        addTeardownBlock { @MainActor in
            gate.release()
            current.cancel()
            _ = await current.result
        }
        await fulfillment(of: [entered], timeout: 3)
        let discarded = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await model.load(item: discardedItem, includeSource: false)
        }
        await assertCancelled(discarded)
        gate.release()
        try await current.value
        XCTAssertEqual(imageCalls, [currentID])
        XCTAssertEqual(model.title, "current")
        XCTAssertEqual(model.imageURL, expectedImage)
        XCTAssertTrue(model.hasLoadedDisplayState)
    }

    func testDelayedImageCannotOverwriteNewerLoad() async throws {
        let entered = expectation(description: "old image continuation registered")
        let gate = ReaderCellLoadGate(entered)
        let oldItem = item("old")
        let currentItem = item("current")
        let realm = try await managedRealm([oldItem, currentItem])
        defer { withExtendedLifetime(realm) {} }
        let oldID = oldItem.compoundKey
        let oldImage = image("old")
        let newImage = image("new")
        let model = makeModel(in: realm, imageURLLoader: { value in
            if value.compoundKey == oldID {
                await gate.wait()
                return oldImage
            }
            return newImage
        })
        let old = Task { try await model.load(item: oldItem, includeSource: false) }
        addTeardownBlock { @MainActor in
            gate.release()
            old.cancel()
            _ = await old.result
        }
        await fulfillment(of: [entered], timeout: 3)
        try await model.load(item: currentItem, includeSource: false)
        gate.release()
        await assertCancelled(old)
        XCTAssertEqual(model.title, "current")
        XCTAssertEqual(model.imageURL, newImage)
        XCTAssertTrue(model.hasLoadedDisplayState)
    }

    func testCallerCancellationRejectsNoncooperativeImageResult() async throws {
        let entered = expectation(description: "cancelled image continuation registered")
        let gate = ReaderCellLoadGate(entered)
        let file = item("cancelled")
        let realm = try await managedRealm([file])
        defer { withExtendedLifetime(realm) {} }
        let unwantedImage = image("cancelled")
        let model = makeModel(in: realm, imageURLLoader: { _ in
            await gate.wait()
            return unwantedImage
        })
        let request = Task { try await model.load(item: file, includeSource: false) }
        addTeardownBlock { @MainActor in
            gate.release()
            request.cancel()
            _ = await request.result
        }
        await fulfillment(of: [entered], timeout: 3)
        request.cancel()
        gate.release()
        await assertCancelled(request)
        XCTAssertEqual(model.title, "")
        XCTAssertNil(model.imageURL)
        XCTAssertFalse(model.hasLoadedDisplayState)
    }

    func testDelayedMetadataCannotOverwriteNewerCompleteLoad() async throws {
        let entered = expectation(description: "old sync-status continuation registered")
        let gate = ReaderCellLoadGate(entered)
        let oldItem = item("old")
        let currentItem = item("current")
        oldItem.author = "Old author"
        currentItem.author = "Current author"
        oldItem.imageUrl = image("old")
        currentItem.imageUrl = image("current")
        let oldURL = oldItem.url
        let oldStatus = status("old")
        let currentStatus = status("current")
        let realm = try await managedRealm([oldItem, currentItem])
        defer { withExtendedLifetime(realm) {} }
        let model = makeModel(in: realm, syncStatusLoader: { url in
            if url == oldURL {
                await gate.wait()
                return oldStatus
            }
            return currentStatus
        })
        let old = Task { try await model.load(item: oldItem, includeSource: false) }
        addTeardownBlock { @MainActor in
            gate.release()
            old.cancel()
            _ = await old.result
        }
        await fulfillment(of: [entered], timeout: 3)
        try await model.load(item: currentItem, includeSource: false)
        gate.release()
        await assertCancelled(old)
        XCTAssertEqual(model.title, "current")
        XCTAssertEqual(model.author, "Current author")
        XCTAssertEqual(model.imageURL, currentItem.imageUrl)
        XCTAssertEqual(model.syncStatusPresentation, currentStatus)
        XCTAssertTrue(model.hasLoadedDisplayState)
    }

    func testCallerCancellationRejectsNoncooperativeMetadataResult() async throws {
        let entered = expectation(description: "cancelled sync-status continuation registered")
        let gate = ReaderCellLoadGate(entered)
        let file = item("cancelled")
        let realm = try await managedRealm([file])
        defer { withExtendedLifetime(realm) {} }
        let unwantedStatus = status("cancelled")
        let model = makeModel(in: realm, syncStatusLoader: { _ in
            await gate.wait()
            return unwantedStatus
        })
        let request = Task { try await model.load(item: file, includeSource: false) }
        addTeardownBlock { @MainActor in
            gate.release()
            request.cancel()
            _ = await request.result
        }
        await fulfillment(of: [entered], timeout: 3)
        request.cancel()
        gate.release()
        await assertCancelled(request)
        XCTAssertEqual(model.title, "")
        XCTAssertNil(model.syncStatusPresentation)
        XCTAssertFalse(model.hasLoadedDisplayState)
    }

    func testCurrentImageFailurePreservesPriorValuesAndAllowsRetry() async throws {
        let initial = item("initial")
        let attempted = item("attempted")
        initial.imageUrl = image("initial")
        attempted.imageUrl = image("attempted")
        let realm = try await managedRealm([initial, attempted])
        defer { withExtendedLifetime(realm) {} }
        var shouldFail = false
        let model = makeModel(in: realm, imageURLLoader: { value in
            if shouldFail { throw ReaderCellLoadFixtureError.imageFailed }
            return value.imageUrl
        })
        try await model.load(item: initial, includeSource: false)
        shouldFail = true
        do {
            try await model.load(item: attempted, includeSource: false)
            XCTFail("Current image failure must still be reported")
        } catch ReaderCellLoadFixtureError.imageFailed {
        }
        XCTAssertEqual(model.title, "initial")
        XCTAssertEqual(model.imageURL, initial.imageUrl)
        XCTAssertFalse(model.hasLoadedDisplayState)

        shouldFail = false
        try await model.load(item: attempted, includeSource: false)
        XCTAssertEqual(model.title, "attempted")
        XCTAssertEqual(model.imageURL, attempted.imageUrl)
        XCTAssertTrue(model.hasLoadedDisplayState)
    }

    func testCurrentManagedLoadPreservesSelectedMetadataHistoryAndSyncProjection() async throws {
        let file = item("current")
        file.title = " <b>Current</b> "
        file.author = " Author "
        file.imageUrl = image("current")
        let realm = try await managedRealm([file])
        defer { withExtendedLifetime(realm) {} }
        let history = HistoryRecord()
        history.url = file.url
        history.updateCompoundKey()
        history.lastVisitedAt = Date(timeIntervalSince1970: 123)
        try realm.write { realm.add(history) }
        let expectedStatus = status("current")
        let model = makeModel(in: realm, syncStatusLoader: { _ in expectedStatus })

        try await model.load(item: file, includeSource: false)

        XCTAssertEqual(model.title, "Current")
        XCTAssertEqual(model.author, "Author")
        XCTAssertEqual(model.imageURL, file.imageUrl)
        XCTAssertEqual(model.latestHistoryRecordLastVisitedAt, history.lastVisitedAt)
        XCTAssertEqual(model.syncStatusPresentation, expectedStatus)
        XCTAssertNil(model.readingProgress)
        XCTAssertNil(model.totalWordCount)
        XCTAssertTrue(model.hasLoadedDisplayState)
    }

    func testSameRowRevisionReloadsMetadataAndClearsRemovedImage() async throws {
        let file = item("current")
        file.imageUrl = image("initial")
        file.modifiedAt = Date(timeIntervalSince1970: 100)
        let realm = try await managedRealm([file])
        defer { withExtendedLifetime(realm) {} }
        let model = makeModel(in: realm)
        let originalIdentity = ReaderContentCellLoadIdentity(item: file, includesSource: false)
        try await model.load(item: file, includeSource: false)
        try realm.write {
            file.title = "revised"
            file.author = " New author "
            file.imageUrl = nil
            file.modifiedAt = Date(timeIntervalSince1970: 101)
        }
        XCTAssertNotEqual(originalIdentity, ReaderContentCellLoadIdentity(item: file, includesSource: false))

        try await model.load(item: file, includeSource: false)

        XCTAssertEqual(model.title, "revised")
        XCTAssertEqual(model.author, "New author")
        XCTAssertNil(model.imageURL)
        XCTAssertTrue(model.hasLoadedDisplayState)
    }

    private func item(_ name: String) -> ContentFile {
        let item = ContentFile()
        item.url = URL(string: "reader-file://file/load/local/\(name).txt")!
        item.title = name
        // Skip the application's separately injected progress services.
        item.readerContentKind = .contentListing
        item.updateCompoundKey()
        return item
    }

    private func managedRealm(_ items: [ContentFile]) async throws -> Realm {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = "ReaderCellLoad-\(UUID().uuidString)"
        configuration.objectTypes = [ContentFile.self, HistoryRecord.self]
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        try realm.write { realm.add(items) }
        return realm
    }

    private func makeModel(
        in realm: Realm,
        imageURLLoader: @escaping @MainActor (ContentFile) async throws -> URL? = { try await $0.imageURLToDisplay() },
        syncStatusLoader: @escaping @Sendable (URL) async throws -> ReaderContentSyncStatusPresentation? = { _ in nil }
    ) -> ReaderContentCellViewModel<ContentFile> {
        ReaderContentCellViewModel(
            imageURLLoader: imageURLLoader,
            historyRealmConfiguration: realm.configuration,
            syncStatusLoader: syncStatusLoader
        )
    }

    private func assertCancelled(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await task.value
            XCTFail("The retired load must lose publication authority", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func image(_ name: String) -> URL {
        URL(string: "https://example.invalid/\(name).png")!
    }

    private func status(_ name: String) -> ReaderContentSyncStatusPresentation {
        ReaderContentSyncStatusPresentation(title: name, imageName: "checkmark", imageIsSystemSymbol: true)
    }
}

/// Gates only an I/O collaborator. The production model performs all admission,
/// Realm reads, metadata projection and publication.
@MainActor
private final class ReaderCellLoadGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(_ entered: XCTestExpectation) {
        self.entered = entered
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
            // Do not permit cancellation/replacement until registration completes.
            entered.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private enum ReaderCellLoadFixtureError: Error {
    case imageFailed
}
