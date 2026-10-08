import Foundation
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
private final class ReviewStatusProvider {
    var entered: [XCTestExpectation]
    var continuations: [Int: CheckedContinuation<CloudDriveSyncStatus, Never>] = [:]
    var cancelledOnReturn: [Int: Bool] = [:]
    var count = 0
    init(_ entered: [XCTestExpectation]) { self.entered = entered }
    func load(_ item: ContentFile) async -> CloudDriveSyncStatus {
        let index = count
        count += 1
        let status = await withCheckedContinuation { continuation in
            continuations[index] = continuation
            entered[index].fulfill()
        }
        cancelledOnReturn[index] = Task.isCancelled
        return status
    }
    func finish(_ index: Int, _ status: CloudDriveSyncStatus) {
        continuations.removeValue(forKey: index)?.resume(returning: status)
    }
}

@MainActor
private final class ReviewListGate {
    let entered: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class ReviewReaderAsyncOwnershipTests: XCTestCase {
    private func item(_ name: String = "same") -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "reader-file://file/load/local/\(name).txt")!
        file.updateCompoundKey()
        return file
    }

    func testOlderSameItemStatusCannotOverwriteNewerStatus() async {
        let a = expectation(description: "first status suspended")
        let b = expectation(description: "replacement status suspended")
        let provider = ReviewStatusProvider([a, b])
        let model = CloudDriveSyncStatusModel(statusLoader: { await provider.load($0) })
        let file = item()
        let first = Task { await model.refreshAsync(item: file) }
        await fulfillment(of: [a], timeout: 3)
        let second = Task { await model.refreshAsync(item: file) }
        await fulfillment(of: [b], timeout: 3)
        provider.finish(1, .localOnly)
        await second.value
        provider.finish(0, .cloudOnly)
        await first.value
        XCTAssertEqual(model.status, .localOnly, "RED: obsolete same-item response replaced newer status")
    }

    func testCallerCancellationReachesItsStatusProducerAndPreventsPublication() async {
        let entered = expectation(description: "status suspended")
        let provider = ReviewStatusProvider([entered])
        let model = CloudDriveSyncStatusModel(statusLoader: { await provider.load($0) })
        let file = item()
        let caller = Task { await model.refreshAsync(item: file) }
        await fulfillment(of: [entered], timeout: 3)
        caller.cancel()
        provider.finish(0, .localOnly)
        await caller.value
        XCTAssertEqual(provider.cancelledOnReturn[0], true, "RED: caller cancellation did not reach its child")
        XCTAssertEqual(model.status, .loadingStatus, "Cancelled work must not publish")
    }

    func testCancellingOlderCallerDoesNotCancelReplacementStatus() async {
        let a = expectation(description: "old suspended")
        let b = expectation(description: "new suspended")
        let provider = ReviewStatusProvider([a, b])
        let model = CloudDriveSyncStatusModel(statusLoader: { await provider.load($0) })
        let file = item()
        let first = Task { await model.refreshAsync(item: file) }
        await fulfillment(of: [a], timeout: 3)
        let second = Task { await model.refreshAsync(item: file) }
        await fulfillment(of: [b], timeout: 3)
        first.cancel()
        provider.finish(0, .cloudOnly)
        await first.value
        provider.finish(1, .localOnly)
        await second.value
        XCTAssertEqual(provider.cancelledOnReturn[1], false)
        XCTAssertEqual(model.status, .localOnly)
    }

    func testDirectListLoadSupersedesSuspendedFilteredLoad() async throws {
        let entered = expectation(description: "filter suspended")
        let gate = ReviewListGate(entered)
        let old = item("old"), newest = item("new")
        let model = ReaderContentListViewModel<ContentFile>()
        let first = Task { try await model.load(contents: [old], contentFilter: { @ReaderContentListActor _ in
            await gate.wait()
            return true
        }) }
        await fulfillment(of: [entered], timeout: 3)
        try await model.load(contents: [newest])
        XCTAssertFalse(model.isLoading, "Fast-path completion must not retain the old loading handle")
        gate.release()
        try await first.value
        XCTAssertEqual(model.filteredContentIDs, [newest.compoundKey], "RED: old filtered result overwrote direct load")
        XCTAssertEqual(model.filteredContents.map(\.compoundKey), model.filteredContentIDs)
    }

    func testCancelledListCallerCannotPublishItsSuspendedFilter() async throws {
        let entered = expectation(description: "filter suspended")
        let gate = ReviewListGate(entered)
        let initial = item("initial"), other = item("other")
        let model = ReaderContentListViewModel(initialContents: [initial])
        let caller = Task { try await model.load(contents: [other], contentFilter: { @ReaderContentListActor _ in
            await gate.wait()
            return true
        }) }
        await fulfillment(of: [entered], timeout: 3)
        caller.cancel()
        gate.release()
        _ = try? await caller.value
        XCTAssertEqual(model.filteredContentIDs, [initial.compoundKey])
        XCTAssertFalse(model.isLoading)
    }

    func testCurrentListLoadStillPublishes() async throws {
        let model = ReaderContentListViewModel<ContentFile>()
        let file = item()
        try await model.load(contents: [file], sortOrder: .providedOrder)
        XCTAssertEqual(model.filteredContentIDs, [file.compoundKey])
        XCTAssertFalse(model.isLoading)
    }

    func testSupersededNavigationFailureDoesNotPublish() {
        XCTAssertNil(ReaderSelectionErrorPolicy.message(for: URLError(.notConnectedToInternet), requestIsCurrent: false))
    }
    func testCancellationDoesNotBecomeNavigationError() {
        XCTAssertNil(ReaderSelectionErrorPolicy.message(for: CancellationError(), requestIsCurrent: true))
        XCTAssertNil(ReaderSelectionErrorPolicy.message(for: URLError(.cancelled), requestIsCurrent: true))
    }
    func testCurrentRealNavigationFailureRemainsVisible() {
        XCTAssertNotNil(ReaderSelectionErrorPolicy.message(for: URLError(.notConnectedToInternet), requestIsCurrent: true))
    }
}
