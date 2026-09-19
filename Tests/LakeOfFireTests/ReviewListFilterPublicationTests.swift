import Combine
import Foundation
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

private actor ReviewFilterGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    let entered: XCTestExpectation

    init(entered: XCTestExpectation) { self.entered = entered }

    func wait() async {
        entered.fulfill()
        await withCheckedContinuation { continuation in
            if isOpen { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
final class ReviewListFilterPublicationTests: XCTestCase {
    private enum Fault: Error { case filterFailed }

    private func file(_ name: String) -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "reader-file://file/load/local/\(name).txt")!
        file.updateCompoundKey()
        return file
    }

    func testColdLoadNeverPublishesRowsBeforeTheirFilterCompletes() async throws {
        let allowed = file("allowed")
        let excluded = file("excluded")
        let excludedID = excluded.compoundKey
        let model = ReaderContentListViewModel<ContentFile>()
        let entered = expectation(description: "production filter entered")
        let gate = ReviewFilterGate(entered: entered)
        var snapshots: [[String]] = []
        let observation = model.objectWillChange.sink { snapshots.append(model.filteredContentIDs) }
        defer { observation.cancel() }
        let load = Task { @MainActor in
            try await model.load(contents: [allowed, excluded], contentFilter: { index, item in
                if index == 0 { await gate.wait() }
                return item.compoundKey != excludedID
            }, sortOrder: .providedOrder)
        }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(model.filteredContentIDs.isEmpty, "Unfiltered input is not a valid published snapshot")
        await gate.open()
        try await load.value
        snapshots.append(model.filteredContentIDs)
        XCTAssertFalse(snapshots.contains { $0.contains(excludedID) })
        XCTAssertEqual(model.filteredContentIDs, [allowed.compoundKey])
        XCTAssertEqual(model.filteredContents.map(\.compoundKey), model.filteredContentIDs)
    }

    func testFilterFailurePreservesLastValidSnapshotAndReachesCaller() async {
        let original = file("original")
        let model = ReaderContentListViewModel(initialContents: [original])
        do {
            try await model.load(contents: [file("replacement")], contentFilter: { _, _ in
                throw Fault.filterFailed
            }, sortOrder: .providedOrder)
            XCTFail("The production loader swallowed the filter failure")
        } catch Fault.filterFailed {
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }
        XCTAssertEqual(model.filteredContentIDs, [original.compoundKey])
        XCTAssertFalse(model.isLoading)
    }

    func testColdFilterFailureCannotLeaveUnfilteredInputVisible() async {
        let model = ReaderContentListViewModel<ContentFile>()
        do {
            try await model.load(contents: [file("excluded")], contentFilter: { _, _ in
                throw Fault.filterFailed
            }, sortOrder: .providedOrder)
            XCTFail("Expected the filter failure, not apparent success")
        } catch Fault.filterFailed {
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }
        XCTAssertTrue(model.filteredContentIDs.isEmpty)
        XCTAssertFalse(model.hasLoadedBefore, "No valid filtered snapshot has completed")
        XCTAssertFalse(model.isLoading)
    }

    func testCancelledColdLoadDoesNotPublishInputOrReportSuccess() async {
        let model = ReaderContentListViewModel<ContentFile>()
        let entered = expectation(description: "filter suspended")
        let gate = ReviewFilterGate(entered: entered)
        let input = file("cancelled")
        let load = Task { @MainActor in
            try await model.load(contents: [input], contentFilter: { _, _ in
                await gate.wait()
                return true
            }, sortOrder: .providedOrder)
        }
        await fulfillment(of: [entered], timeout: 3)
        load.cancel()
        await gate.open()
        do {
            try await load.value
            XCTFail("A cancelled current load must not report success")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }
        XCTAssertTrue(model.filteredContentIDs.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testSupersededFilterFailureDoesNotDisturbNewerDirectLoad() async throws {
        let model = ReaderContentListViewModel<ContentFile>()
        let entered = expectation(description: "obsolete filter suspended")
        let gate = ReviewFilterGate(entered: entered)
        let first = file("first")
        let second = file("second")
        let old = Task { @MainActor in
            try await model.load(contents: [first], contentFilter: { _, _ in
                await gate.wait()
                throw Fault.filterFailed
            }, sortOrder: .providedOrder)
        }
        await fulfillment(of: [entered], timeout: 3)
        try await model.load(contents: [second], sortOrder: nil)
        await gate.open()
        try await old.value
        XCTAssertEqual(model.filteredContentIDs, [second.compoundKey])
        XCTAssertFalse(model.isLoading)
    }

    func testAlreadyCancelledCallerCannotRevokeNewerListLoad() async throws {
        let original = file("original")
        let current = file("current")
        let intruder = file("cancelled-caller")
        let model = ReaderContentListViewModel(initialContents: [original])
        let oldEntered = expectation(description: "old caller waiting before load")
        let activeEntered = expectation(description: "newer filter suspended")
        let callerGate = ReviewFilterGate(entered: oldEntered)
        let filterGate = ReviewFilterGate(entered: activeEntered)
        let old = Task { @MainActor in
            await callerGate.wait()
            try await model.load(contents: [intruder], sortOrder: nil)
        }
        await fulfillment(of: [oldEntered], timeout: 3)
        let active = Task { @MainActor in
            try await model.load(contents: [current], contentFilter: { _, _ in
                await filterGate.wait()
                return true
            }, sortOrder: .providedOrder)
        }
        await fulfillment(of: [activeEntered], timeout: 3)
        old.cancel()
        await callerGate.open()
        do {
            try await old.value
            XCTFail("The cancelled caller must not load")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }
        await filterGate.open()
        try await active.value
        XCTAssertEqual(model.filteredContentIDs, [current.compoundKey])
        XCTAssertFalse(model.isLoading)
    }

    func testUnfilteredLoadStillPublishesAlignedValuesAndIDs() async throws {
        let model = ReaderContentListViewModel<ContentFile>()
        let input = [file("one"), file("two")]
        try await model.load(contents: input, sortOrder: .providedOrder)
        XCTAssertEqual(model.filteredContentIDs, input.map(\.compoundKey))
        XCTAssertEqual(model.filteredContents.map(\.compoundKey), model.filteredContentIDs)
        XCTAssertTrue(model.hasLoadedBefore)
        XCTAssertFalse(model.isLoading)
    }
}
