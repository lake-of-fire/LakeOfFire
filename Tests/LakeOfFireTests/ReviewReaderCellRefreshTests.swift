import Foundation
import RealmSwift
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
}
