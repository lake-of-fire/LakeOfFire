import Combine
import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

@MainActor
final class ReaderContentListSnapshotTests: XCTestCase {
    func testFilteredContentsAndIDsPublishAsOneAlignedSnapshot() async throws {
        let first = contentFile(path: "first.epub")
        let second = contentFile(path: "second.epub")
        let viewModel = ReaderContentListViewModel(initialContents: [first])
        var observedCounts = [(contents: Int, ids: Int)]()
        let observation = viewModel.objectWillChange.sink {
            observedCounts.append(
                (
                    contents: viewModel.filteredContents.count,
                    ids: viewModel.filteredContentIDs.count
                )
            )
        }
        defer { observation.cancel() }

        try await viewModel.load(contents: [first, second])

        XCTAssertFalse(observedCounts.isEmpty)
        XCTAssertTrue(observedCounts.allSatisfy { $0.contents == $0.ids })
        XCTAssertEqual(viewModel.filteredContents.count, 2)
        XCTAssertEqual(viewModel.filteredContentIDs.count, 2)
    }

    func testUnmanagedContentLimitKeepsValuesAndIDsAligned() async throws {
        let contents = (0...10_000).map { contentFile(path: "book-\($0).epub") }
        let viewModel = ReaderContentListViewModel<ContentFile>()

        try await viewModel.load(contents: contents, sortOrder: .providedOrder)

        XCTAssertEqual(viewModel.filteredContents.count, 10_000)
        XCTAssertEqual(viewModel.filteredContentIDs.count, 10_000)
        XCTAssertEqual(viewModel.filteredContents.map(\.compoundKey), viewModel.filteredContentIDs)
    }


    func testDirectLoadSupersedesSuspendedFilteredLoad() async throws {
        try await assertDirectLoadRetiresFilter(replacementIsEmpty: false)
    }

    func testEmptyDirectLoadRetiresSuspendedFilteredLoad() async throws {
        try await assertDirectLoadRetiresFilter(replacementIsEmpty: true)
    }

    private func assertDirectLoadRetiresFilter(replacementIsEmpty: Bool) async throws {
        let entered = expectation(description: "old filter has registered its continuation")
        let gate = ReaderListLoadGate(entered)
        let initial = contentFile(path: "initial.epub")
        let old = contentFile(path: "old.epub")
        let newest = contentFile(path: "newest.epub")
        let model = ReaderContentListViewModel(initialContents: [initial])
        let first = Task { @MainActor in
            try await model.load(contents: [old], contentFilter: { @ReaderContentListActor _, _ in
                await gate.wait()
                return true
            })
        }
        addTeardownBlock { @MainActor in
            gate.release()
            first.cancel()
            _ = await first.result
        }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(model.isLoading)

        let replacement = replacementIsEmpty ? [] : [newest]
        try await model.load(contents: replacement)
        XCTAssertFalse(model.isLoading, "An immediate replacement retires the previous loading handle")
        XCTAssertEqual(model.filteredContentIDs, replacement.map(\.compoundKey))

        gate.release()
        try await first.value

        XCTAssertTrue(gate.wasCancelledOnReturn)
        XCTAssertEqual(model.filteredContentIDs, replacement.map(\.compoundKey))
        XCTAssertEqual(model.filteredContents.map(\.compoundKey), model.filteredContentIDs)
        XCTAssertFalse(model.isLoading)
    }

    func testCallerCancellationReachesHeldFilterAndPreventsPublication() async throws {
        let entered = expectation(description: "owned filter has registered its continuation")
        let gate = ReaderListLoadGate(entered)
        let initial = contentFile(path: "initial.epub")
        let other = contentFile(path: "other.epub")
        let model = ReaderContentListViewModel(initialContents: [initial])
        let caller = Task { @MainActor in
            try await model.load(contents: [other], contentFilter: { @ReaderContentListActor _, _ in
                await gate.wait()
                return true
            })
        }
        addTeardownBlock { @MainActor in
            gate.release()
            caller.cancel()
            _ = await caller.result
        }
        await fulfillment(of: [entered], timeout: 3)

        caller.cancel()
        gate.release()
        _ = await caller.result

        XCTAssertTrue(gate.wasCancelledOnReturn, "Cancellation must reach this invocation's producer")
        XCTAssertEqual(model.filteredContentIDs, [initial.compoundKey])
        XCTAssertEqual(model.filteredContents.map(\.compoundKey), model.filteredContentIDs)
        XCTAssertFalse(model.isLoading)
    }

    func testAlreadyCancelledDirectCallerCannotRevokeCurrentLoad() async throws {
        try await assertCancelledCallerPreservesCurrentLoad(sortOrder: nil)
    }

    func testAlreadyCancelledSortedCallerCannotRevokeCurrentLoad() async throws {
        try await assertCancelledCallerPreservesCurrentLoad(sortOrder: .providedOrder)
    }

    private func assertCancelledCallerPreservesCurrentLoad(
        sortOrder: ReaderContentSortOrder?
    ) async throws {
        let entered = expectation(description: "current filter has registered its continuation")
        let gate = ReaderListLoadGate(entered)
        let initial = contentFile(path: "initial.epub")
        let currentItem = contentFile(path: "current.epub")
        let discardedItem = contentFile(path: "discarded.epub")
        let model = ReaderContentListViewModel(initialContents: [initial])
        let current = Task { @MainActor in
            try await model.load(contents: [currentItem], contentFilter: { @ReaderContentListActor _, _ in
                await gate.wait()
                return true
            })
        }
        addTeardownBlock { @MainActor in
            gate.release()
            current.cancel()
            _ = await current.result
        }
        await fulfillment(of: [entered], timeout: 3)

        let discarded = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await model.load(contents: [discardedItem], sortOrder: sortOrder)
                XCTFail("A cancelled caller must fail before replacing rows or load ownership")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await discarded.value
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.filteredContentIDs, [initial.compoundKey])

        gate.release()
        try await current.value

        XCTAssertFalse(gate.wasCancelledOnReturn)
        XCTAssertEqual(model.filteredContentIDs, [currentItem.compoundKey])
        XCTAssertEqual(model.filteredContents.map(\.compoundKey), model.filteredContentIDs)
        XCTAssertFalse(model.isLoading)
    }

    func testCancellingOldCallerCannotCancelOrRetireReplacementLoad() async throws {
        try await assertOldCompletionPreservesReplacement(oldFilterFails: false)
    }

    func testLateFilterFailureCannotRetireReplacementLoad() async throws {
        try await assertOldCompletionPreservesReplacement(oldFilterFails: true)
    }

    private func assertOldCompletionPreservesReplacement(oldFilterFails: Bool) async throws {
        let oldEntered = expectation(description: "old filter has registered its continuation")
        let newEntered = expectation(description: "new filter has registered its continuation")
        let oldGate = ReaderListLoadGate(oldEntered)
        let newGate = ReaderListLoadGate(newEntered)
        let initial = contentFile(path: "initial.epub")
        let old = contentFile(path: "old.epub")
        let newest = contentFile(path: "newest.epub")
        let model = ReaderContentListViewModel(initialContents: [initial])
        let first = Task { @MainActor in
            try await model.load(contents: [old], contentFilter: { @ReaderContentListActor _, _ in
                await oldGate.wait()
                if oldFilterFails { throw ReaderListLoadFixtureError.filterFailed }
                return true
            })
        }
        addTeardownBlock { @MainActor in
            oldGate.release()
            first.cancel()
            _ = await first.result
        }
        await fulfillment(of: [oldEntered], timeout: 3)
        let second = Task { @MainActor in
            try await model.load(contents: [newest], contentFilter: { @ReaderContentListActor _, _ in
                await newGate.wait()
                return true
            })
        }
        addTeardownBlock { @MainActor in
            newGate.release()
            second.cancel()
            _ = await second.result
        }
        await fulfillment(of: [newEntered], timeout: 3)

        first.cancel()
        oldGate.release()
        _ = await first.result
        XCTAssertTrue(model.isLoading, "An old success/error must not clear the replacement handle")
        XCTAssertEqual(model.filteredContentIDs, [initial.compoundKey])

        newGate.release()
        try await second.value

        XCTAssertTrue(oldGate.wasCancelledOnReturn)
        XCTAssertFalse(newGate.wasCancelledOnReturn)
        XCTAssertEqual(model.filteredContentIDs, [newest.compoundKey])
        XCTAssertEqual(model.filteredContents.map(\.compoundKey), model.filteredContentIDs)
        XCTAssertFalse(model.isLoading)
    }

    func testCurrentFilterFailurePreservesRowsAndAllowsRetry() async throws {
        let entered = expectation(description: "failing filter has registered its continuation")
        let gate = ReaderListLoadGate(entered)
        let initial = contentFile(path: "initial.epub")
        let attempted = contentFile(path: "attempted.epub")
        let model = ReaderContentListViewModel(initialContents: [initial])
        let failed = Task { @MainActor in
            try await model.load(contents: [attempted], contentFilter: { @ReaderContentListActor _, _ in
                await gate.wait()
                throw ReaderListLoadFixtureError.filterFailed
            })
        }
        addTeardownBlock { @MainActor in
            gate.release()
            failed.cancel()
            _ = await failed.result
        }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(model.isLoading)
        gate.release()
        // Preserve the selected loader's existing producer-error suppression.
        try await failed.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.filteredContentIDs, [initial.compoundKey])

        try await model.load(contents: [attempted], contentFilter: { @ReaderContentListActor _, _ in true })
        XCTAssertEqual(model.filteredContentIDs, [attempted.compoundKey])
        XCTAssertEqual(model.filteredContents.map(\.compoundKey), model.filteredContentIDs)
        XCTAssertFalse(model.isLoading)
    }

    func testManagedFilteredLoadPreservesSortingTransformAndAlignedSnapshot() async throws {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = "ReaderListLoad-\(UUID().uuidString)"
        configuration.objectTypes = [ContentFile.self]
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let first = contentFile(path: "first.epub")
        first.title = "B"
        let second = contentFile(path: "second.epub")
        second.title = "A"
        let excluded = contentFile(path: "excluded.epub")
        excluded.title = "Exclude"
        try realm.write { realm.add([first, second, excluded]) }
        let identifier = configuration.inMemoryIdentifier
        addTeardownBlock {
            await { @ReaderContentListActor in
                for (key, cached) in ReaderContentListActor.shared.cachedRealms
                    where cached.configuration.inMemoryIdentifier == identifier {
                    cached.invalidate()
                    ReaderContentListActor.shared.cachedRealms.removeValue(forKey: key)
                }
            }()
        }
        let model = ReaderContentListViewModel<ContentFile>()

        try await model.load(
            contents: [first, second, excluded],
            contentFilter: { @ReaderContentListActor _, content in content.title != "Exclude" },
            sortOrder: .title,
            postSortTransform: { @ReaderContentListActor contents in Array(contents.prefix(1)) }
        )

        XCTAssertEqual(model.filteredContentIDs, [second.compoundKey])
        XCTAssertEqual(model.filteredContents.map(\.compoundKey), model.filteredContentIDs)
        XCTAssertTrue(model.filteredContents.first?.isSameObject(as: second) == true)
        XCTAssertFalse(model.isLoading)
        withExtendedLifetime(realm) {}
    }

    private func contentFile(path: String) -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "ebook://book/\(path)")!
        file.updateCompoundKey()
        return file
    }
}

/// Controls only the asynchronous filter collaborator. Publication, cancellation
/// forwarding and loading state always run through the production list model.
@MainActor
private final class ReaderListLoadGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var wasCancelledOnReturn = false
    private(set) var calls = 0

    init(_ entered: XCTestExpectation) {
        self.entered = entered
    }

    func wait() async {
        calls += 1
        guard calls == 1 else {
            XCTFail("This fixture expects one filter call")
            return
        }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
            // A test may replace/cancel the load only after registration.
            entered.fulfill()
        }
        wasCancelledOnReturn = Task.isCancelled
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private enum ReaderListLoadFixtureError: Error {
    case filterFailed
}
