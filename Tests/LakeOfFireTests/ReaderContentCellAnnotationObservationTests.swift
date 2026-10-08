import Foundation
import XCTest
@testable import LakeOfFireReader

@MainActor
private final class AnnotationLoadGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(_ entered: XCTestExpectation) { self.entered = entered }

    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { self.continuation = continuation }
            entered.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class ReaderContentCellAnnotationObservationTests: XCTestCase {
    private func status(_ count: Int) -> ReaderContentCellAnnotationStatus {
        .init(noteCount: count, unfinishedTaskCount: count > 0 ? 1 : 0)
    }

    func testAStableRowReceivesNoteCreationTaskChangeAndDeletion() async {
        let states = [status(0), status(3), .init(noteCount: 3, finishedTaskCount: 1), status(0)]
        let stream = AsyncStream<ReaderContentCellAnnotationStatus> { continuation in
            for state in states { continuation.yield(state) }
            continuation.finish()
        }
        var published: [ReaderContentCellAnnotationStatus] = []
        await observeReaderContentCellAnnotationStatus(
            updates: { stream }, initialStatus: { states[0] },
            publish: { published.append($0) }
        )
        XCTAssertEqual(published, states)
    }

    func testChangesAfterInitialPresentationDoNotRequireReloadingTheRow() async {
        let first = expectation(description: "initial presentation")
        let pair = AsyncStream<ReaderContentCellAnnotationStatus>.makeStream()
        pair.continuation.yield(status(0))
        var published: [ReaderContentCellAnnotationStatus] = []
        let observation = Task { @MainActor in
            await observeReaderContentCellAnnotationStatus(
                updates: { pair.stream }, initialStatus: { self.status(0) },
                publish: {
                    published.append($0)
                    if published.count == 1 { first.fulfill() }
                }
            )
        }
        await fulfillment(of: [first], timeout: 3)
        pair.continuation.yield(status(2))
        pair.continuation.yield(status(0))
        pair.continuation.finish()
        await observation.value
        XCTAssertEqual(published.map(\.noteCount), [0, 2, 0])
    }

    func testStreamIsAuthoritativeAndDoesNotRunTheLegacyLoader() async {
        var loadCount = 0
        let stream = AsyncStream<ReaderContentCellAnnotationStatus> { continuation in
            continuation.yield(status(4))
            continuation.finish()
        }
        var published: [ReaderContentCellAnnotationStatus] = []
        await observeReaderContentCellAnnotationStatus(
            updates: { stream }, initialStatus: { loadCount += 1; return self.status(99) },
            publish: { published.append($0) }
        )
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(published, [status(4)])
    }

    func testLegacyLoaderStillWorksWhenNoStreamWasInstalled() async {
        var published: [ReaderContentCellAnnotationStatus] = []
        await observeReaderContentCellAnnotationStatus(
            updates: { nil }, initialStatus: { self.status(7) },
            publish: { published.append($0) }
        )
        XCTAssertEqual(published, [status(7)])
    }

    func testCancelledAdmissionStartsNeitherProviderNorLoader() async {
        var calls = 0
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await observeReaderContentCellAnnotationStatus(
                updates: { calls += 1; return nil },
                initialStatus: { calls += 1; return self.status(1) },
                publish: { _ in calls += 1 }
            )
        }
        await operation.value
        XCTAssertEqual(calls, 0)
    }

    func testLateLegacyResultCannotPublishAfterCancellation() async {
        let gate = AnnotationLoadGate(expectation(description: "loader suspended"))
        var published: [ReaderContentCellAnnotationStatus] = []
        let operation = Task { @MainActor in
            await observeReaderContentCellAnnotationStatus(
                updates: { nil }, initialStatus: { await gate.wait(); return self.status(8) },
                publish: { published.append($0) }
            )
        }
        await fulfillment(of: [gate.entered], timeout: 3)
        operation.cancel()
        gate.release()
        await operation.value
        XCTAssertTrue(published.isEmpty)
    }

    func testCancellationDuringPublicationRejectsBufferedLaterSnapshots() async {
        let stream = AsyncStream<ReaderContentCellAnnotationStatus> { continuation in
            for count in [1, 2, 3] { continuation.yield(status(count)) }
            continuation.finish()
        }
        var published: [Int] = []
        let operation = Task { @MainActor in
            await observeReaderContentCellAnnotationStatus(
                updates: { stream }, initialStatus: { self.status(1) },
                publish: {
                    published.append($0.noteCount)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        await operation.value
        XCTAssertEqual(published, [1])
    }
}
