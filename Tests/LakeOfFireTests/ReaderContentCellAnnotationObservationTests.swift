import Foundation
import XCTest
@testable import LakeOfFireContentUI

@MainActor
private final class AnnotationLoadGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            entered = true
            if released { continuation.resume() } else { self.continuation = continuation }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct TestAnnotationStatus: Equatable, Sendable {
    var count: Int
}

@MainActor
final class ReaderContentCellAnnotationObservationTests: XCTestCase {
    func testStableRowReceivesCompleteSnapshotChanges() async {
        let states = [0, 3, 4, 0].map(TestAnnotationStatus.init)
        let stream = AsyncStream<TestAnnotationStatus> { continuation in
            for state in states { continuation.yield(state) }
            continuation.finish()
        }
        var published: [TestAnnotationStatus] = []
        await observeReaderContentCellAnnotationStatus(
            updates: { stream },
            initialStatus: { TestAnnotationStatus(count: 99) },
            publish: { published.append($0) }
        )
        XCTAssertEqual(published, states)
    }

    func testStreamIsAuthoritativeAndSkipsLegacyLoader() async {
        var loadCount = 0
        let stream = AsyncStream<TestAnnotationStatus> { continuation in
            continuation.yield(.init(count: 4))
            continuation.finish()
        }
        var published: [TestAnnotationStatus] = []
        await observeReaderContentCellAnnotationStatus(
            updates: { stream },
            initialStatus: { loadCount += 1; return .init(count: 99) },
            publish: { published.append($0) }
        )
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(published, [.init(count: 4)])
    }

    func testLegacyLoaderWorksWithoutStream() async {
        var published: [TestAnnotationStatus] = []
        await observeReaderContentCellAnnotationStatus(
            updates: { nil },
            initialStatus: { .init(count: 7) },
            publish: { published.append($0) }
        )
        XCTAssertEqual(published, [.init(count: 7)])
    }

    func testPreCancelledTaskStartsNeitherProviderNorLoader() async {
        var calls = 0
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await observeReaderContentCellAnnotationStatus(
                updates: {
                    calls += 1
                    return nil as AsyncStream<TestAnnotationStatus>?
                },
                initialStatus: {
                    calls += 1
                    return TestAnnotationStatus(count: 1)
                },
                publish: { (_: TestAnnotationStatus) in calls += 1 }
            )
        }
        await operation.value
        XCTAssertEqual(calls, 0)
    }

    func testLateLegacyResultCannotPublishAfterCancellation() async {
        let gate = AnnotationLoadGate()
        var published: [TestAnnotationStatus] = []
        let operation = Task { @MainActor in
            await observeReaderContentCellAnnotationStatus(
                updates: { nil },
                initialStatus: { await gate.wait(); return .init(count: 8) },
                publish: { published.append($0) }
            )
        }
        while !gate.entered {
            await Task.yield()
        }
        operation.cancel()
        gate.release()
        await operation.value
        XCTAssertTrue(published.isEmpty)
    }

    func testCancellationRejectsBufferedLaterSnapshots() async {
        let stream = AsyncStream<TestAnnotationStatus> { continuation in
            for count in [1, 2, 3] { continuation.yield(.init(count: count)) }
            continuation.finish()
        }
        var published: [Int] = []
        let operation = Task { @MainActor in
            await observeReaderContentCellAnnotationStatus(
                updates: { stream },
                initialStatus: { .init(count: 0) },
                publish: {
                    published.append($0.count)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        await operation.value
        XCTAssertEqual(published, [1])
    }

    func testCancelledLoadCannotOverwriteReplacementRowSnapshot() async {
        let gate = AnnotationLoadGate()
        var published: [ReaderContentCellAnnotationStatus] = []
        let retired = Task { @MainActor in
            await observeReaderContentCellAnnotationStatus(
                updates: { nil },
                initialStatus: {
                    await gate.wait()
                    return ReaderContentCellAnnotationStatus(noteCount: 99)
                },
                publish: { published.append($0) }
            )
        }
        while !gate.entered {
            await Task.yield()
        }
        retired.cancel()

        let replacement = ReaderContentCellAnnotationStatus(
            noteCount: 2, unfinishedTaskCount: 3, finishedTaskCount: 4
        )
        let stream = AsyncStream<ReaderContentCellAnnotationStatus> { continuation in
            continuation.yield(replacement)
            continuation.finish()
        }
        await observeReaderContentCellAnnotationStatus(
            updates: { stream },
            initialStatus: { .init() },
            publish: { published.append($0) }
        )
        gate.release()
        await retired.value
        XCTAssertEqual(published, [replacement])
    }

    func testFinishedEmptyStreamDoesNotInvokeFallbackLoader() async {
        var loadCount = 0
        var published: [ReaderContentCellAnnotationStatus] = []
        let stream = AsyncStream<ReaderContentCellAnnotationStatus> { $0.finish() }
        await observeReaderContentCellAnnotationStatus(
            updates: { stream },
            initialStatus: {
                loadCount += 1
                return .init(noteCount: 99)
            },
            publish: { published.append($0) }
        )
        XCTAssertEqual(loadCount, 0)
        XCTAssertTrue(published.isEmpty)
    }
}
