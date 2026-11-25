import CoreGraphics
import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
private final class ReaderCellImageGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<URL?, Never>?
    private var released = false
    private var result: URL?

    init(_ entered: XCTestExpectation) { self.entered = entered }

    func wait() async -> URL? {
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
            entered.fulfill()
        }
    }

    func release(_ url: URL?) {
        released = true
        result = url
        continuation?.resume(returning: url)
        continuation = nil
    }
}

@MainActor
final class ReviewReaderCellRefreshTests: XCTestCase {
    private func item(_ name: String) -> ContentFile {
        let item = ContentFile()
        item.url = URL(string: "reader-file://file/load/local/\(name).txt")!
        item.title = name
        // These tests isolate metadata/image ownership, not the application's
        // separately injected reading-progress service or a downloaded asset.
        item.readerContentKind = .contentListing
        item.updateCompoundKey()
        return item
    }

    private func managedRealm(_ items: [ContentFile]) async throws -> Realm {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = "reader-cell-refresh-" + UUID().uuidString
        configuration.objectTypes = [ContentFile.self]
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        try realm.write { realm.add(items) }
        addTeardownBlock { [configuration] in
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        return realm
    }

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
        let entered = expectation(description: "current image request suspended")
        let gate = ReaderCellImageGate(entered)
        let currentItem = item("current")
        let discardedItem = item("discarded")
        let realm = try await managedRealm([currentItem, discardedItem])
        defer { withExtendedLifetime(realm) {} }
        let expectedImage = URL(string: "https://example.invalid/current.png")!
        let currentID = currentItem.compoundKey
        let model = ReaderContentCellViewModel<ContentFile>(imageURLLoader: { value in
            if value.compoundKey == currentID { return await gate.wait() }
            return nil
        })
        let current = Task { try await model.load(item: currentItem, includeSource: false) }
        await fulfillment(of: [entered], timeout: 3)
        let discarded = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await model.load(item: discardedItem, includeSource: false)
                XCTFail("An already-cancelled load must be rejected")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await discarded.value
        gate.release(expectedImage)
        do {
            try await current.value
        } catch {
            XCTFail("Cancelled newcomer invalidated the current load: \(error)")
        }
        XCTAssertEqual(model.title, "current")
        XCTAssertEqual(model.imageURL, expectedImage)
        XCTAssertTrue(model.hasLoadedDisplayState)
    }

    func testDelayedImageCannotOverwriteNewerLoad() async throws {
        let entered = expectation(description: "old image request suspended")
        let gate = ReaderCellImageGate(entered)
        let oldItem = item("old")
        let currentItem = item("current")
        let realm = try await managedRealm([oldItem, currentItem])
        defer { withExtendedLifetime(realm) {} }
        let oldID = oldItem.compoundKey
        let oldImage = URL(string: "https://example.invalid/old.png")!
        let newImage = URL(string: "https://example.invalid/new.png")!
        let model = ReaderContentCellViewModel<ContentFile>(imageURLLoader: { value in
            if value.compoundKey == oldID { return await gate.wait() }
            return newImage
        })
        let old = Task { try await model.load(item: oldItem, includeSource: false) }
        await fulfillment(of: [entered], timeout: 3)
        do {
            try await model.load(item: currentItem, includeSource: false)
        } catch {
            gate.release(oldImage)
            _ = try? await old.value
            throw error
        }
        gate.release(oldImage)
        do {
            try await old.value
            XCTFail("Superseded image load must lose publication authority")
        } catch is CancellationError {
        }
        XCTAssertEqual(model.title, "current")
        XCTAssertEqual(model.imageURL, newImage)
        XCTAssertTrue(model.hasLoadedDisplayState)
    }

    func testCurrentManagedCellLoadPublishesMetadataAndImage() async throws {
        let file = item("current")
        file.author = " Author "
        file.imageUrl = URL(string: "https://example.invalid/current.png")!
        let realm = try await managedRealm([file])
        defer { withExtendedLifetime(realm) {} }
        let model = ReaderContentCellViewModel<ContentFile>()
        try await model.load(item: file, includeSource: false)
        XCTAssertEqual(model.title, "current")
        XCTAssertEqual(model.author, "Author")
        XCTAssertEqual(model.imageURL, file.imageUrl)
        XCTAssertTrue(model.hasLoadedDisplayState)
    }

    func testSuspendedFrozenCellCannotPublishFromRecreatedPhysicalRow() async throws {
        let gate = ReaderCellImageGate(expectation(description: "original image request suspended"))
        let replacementGate = ReaderCellImageGate(expectation(description: "replacement image request suspended"))
        let original = item("original")
        original.createdAt = Date(timeIntervalSince1970: 100)
        original.modifiedAt = Date(timeIntervalSince1970: 200)
        let realm = try await managedRealm([original])
        let frozen = original.freeze()
        let originalIdentity = try XCTUnwrap(ReaderContentCellDisplayLoadIdentity(item: frozen, includesSource: false))
        let originalImage = try XCTUnwrap(URL(string: "https://example.invalid/original.png"))
        let replacementImage = try XCTUnwrap(URL(string: "https://example.invalid/replacement.png"))
        var initialImageLoaded = false
        let model = ReaderContentCellViewModel<ContentFile>(imageURLLoader: { value in
            if value.title != "original" { return await replacementGate.wait() }
            if initialImageLoaded { return await gate.wait() }
            initialImageLoaded = true
            return originalImage
        })
        try await model.load(item: frozen, includeSource: false)
        let load = Task { try await model.load(item: frozen, includeSource: false) }
        await fulfillment(of: [gate.entered], timeout: 3)
        XCTAssertFalse(model.hasLoadedDisplayState)
        XCTAssertEqual(model.title, "original")
        XCTAssertEqual(model.imageURL, originalImage)

        let replacement = item("original")
        replacement.title = "Replacement"
        replacement.author = "New author"
        replacement.createdAt = frozen.createdAt
        replacement.modifiedAt = frozen.modifiedAt
        do {
            try realm.write {
                realm.delete(original)
                realm.add(replacement)
            }
        } catch {
            gate.release(originalImage)
            _ = await load.result
            throw error
        }
        gate.release(originalImage)
        do {
            try await load.value
            XCTFail("An older frozen row must lose display authority even without a newer load")
        } catch is CancellationError {
        }
        XCTAssertFalse(frozen.isInvalidated)
        XCTAssertEqual(frozen.compoundKey, replacement.compoundKey)
        XCTAssertEqual(replacement.createdAt, frozen.createdAt)
        let replacementIdentity = try XCTUnwrap(ReaderContentCellDisplayLoadIdentity(
            item: replacement.freeze(), includesSource: false
        ))
        XCTAssertEqual(originalIdentity.revision, replacementIdentity.revision)
        XCTAssertNotEqual(originalIdentity, replacementIdentity)
        XCTAssertEqual(model.title, "original")
        XCTAssertEqual(model.imageURL, originalImage)
        let replacementLoad = Task { try await model.load(item: replacement.freeze(), includeSource: false) }
        await fulfillment(of: [replacementGate.entered], timeout: 3)
        XCTAssertFalse(model.hasLoadedDisplayState)
        XCTAssertEqual(model.title, "")
        XCTAssertNil(model.imageURL)

        replacementGate.release(replacementImage)
        try await replacementLoad.value
        XCTAssertTrue(model.hasLoadedDisplayState)
        XCTAssertEqual(model.title, "Replacement")
        XCTAssertEqual(model.author, "New author")
        XCTAssertEqual(model.imageURL, replacementImage)
    }

    func testRecreatedPhysicalRowCannotReceiveLateProgress() async throws {
        let progressGate = ReaderCellImageGate(expectation(description: "reading progress request suspended"))
        let original = item("original")
        original.readerContentKind = .readerContent
        let realm = try await managedRealm([original])
        let frozen = original.freeze()
        let model = ReaderContentCellViewModel<ContentFile>(
            imageURLLoader: { _ in nil },
            readingProgressLoader: { _ in
                _ = await progressGate.wait()
                return (0.75, false)
            }
        )
        let load = Task { try await model.load(item: frozen, includeSource: false) }
        await fulfillment(of: [progressGate.entered], timeout: 3)

        let replacement = item("original")
        replacement.readerContentKind = .readerContent
        replacement.title = "Replacement"
        replacement.createdAt = frozen.createdAt
        replacement.modifiedAt = frozen.modifiedAt
        do {
            try realm.write {
                realm.delete(original)
                realm.add(replacement)
            }
        } catch {
            progressGate.release(nil)
            _ = await load.result
            throw error
        }
        progressGate.release(nil)
        do {
            try await load.value
            XCTFail("A late progress result cannot grant display authority to a retired row")
        } catch is CancellationError {
        }
        XCTAssertFalse(model.hasLoadedDisplayState)
        XCTAssertEqual(model.title, "")
        XCTAssertNil(model.readingProgress)
    }

    func testAlreadyCancelledCoverWidthRequestDoesNotStartResolution() async {
        var resolutions = 0
        var widths: [CGFloat] = []
        let request = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await refreshReaderBookCoverWidth(
                resolve: { resolutions += 1; return 24 },
                publish: { widths.append($0) }
            )
        }
        await request.value
        XCTAssertEqual(resolutions, 0)
        XCTAssertTrue(widths.isEmpty)
    }

    func testCancelledCoverWidthCannotPublishAfterNoncooperativeReadReturns() async {
        let entered = expectation(description: "cover metadata read suspended")
        let gate = ReaderCellImageGate(entered)
        var widths: [CGFloat] = []
        let request = Task { @MainActor in
            await refreshReaderBookCoverWidth(
                resolve: { _ = await gate.wait(); return 24 },
                publish: { widths.append($0) }
            )
        }
        await fulfillment(of: [entered], timeout: 3)
        request.cancel()
        // The underlying read deliberately finishes despite cancellation.
        gate.release(nil)
        await request.value
        XCTAssertTrue(widths.isEmpty)
    }

    func testCancelledOldCoverWidthCannotOverwriteSuccessorWidth() async {
        let entered = expectation(description: "previous cover metadata suspended")
        let gate = ReaderCellImageGate(entered)
        var widths: [CGFloat] = []
        let old = Task { @MainActor in
            await refreshReaderBookCoverWidth(
                resolve: { _ = await gate.wait(); return 24 },
                publish: { widths.append($0) }
            )
        }
        await fulfillment(of: [entered], timeout: 3)
        // Models the cancellation performed by the existing SwiftUI .task(id:)
        // when its image URL or dimension changes, without launching SwiftUI.
        old.cancel()
        await refreshReaderBookCoverWidth(resolve: { 72 }, publish: { widths.append($0) })
        gate.release(nil)
        await old.value
        XCTAssertEqual(widths, [72])
    }

    func testCurrentDelayedCoverWidthStillPublishes() async {
        let entered = expectation(description: "current cover metadata suspended")
        let gate = ReaderCellImageGate(entered)
        var widths: [CGFloat] = []
        let request = Task { @MainActor in
            await refreshReaderBookCoverWidth(
                resolve: { _ = await gate.wait(); return 24 },
                publish: { widths.append($0) }
            )
        }
        await fulfillment(of: [entered], timeout: 3)
        gate.release(nil)
        await request.value
        XCTAssertEqual(widths, [24])
    }

    func testCancellationBeforeCoverResolverReturnsPreventsPublication() async {
        var widths: [CGFloat] = []
        let request = Task { @MainActor in
            await refreshReaderBookCoverWidth(
                resolve: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 24
                },
                publish: { widths.append($0) }
            )
        }
        await request.value
        XCTAssertTrue(widths.isEmpty)
    }

    func testCurrentMissingCoverCanPublishZeroWidth() async {
        var width: CGFloat = 72
        await refreshReaderBookCoverWidth(resolve: { 0 }, publish: { width = $0 })
        XCTAssertEqual(width, 0)
    }
}
