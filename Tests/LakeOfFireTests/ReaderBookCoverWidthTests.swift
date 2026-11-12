import CoreGraphics
import XCTest
@testable import LakeOfFireContentUI

@MainActor
final class ReaderBookCoverWidthTests: XCTestCase {
    func testAlreadyCancelledRequestDoesNotStartResolution() async {
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

    func testCancelledRequestCannotPublishAfterNoncooperativeReadReturns() async {
        let entered = expectation(description: "metadata continuation registered")
        let gate = ReaderBookCoverWidthGate(entered)
        var widths: [CGFloat] = []
        let request = Task { @MainActor in
            await refreshReaderBookCoverWidth(
                resolve: { await gate.wait() },
                publish: { widths.append($0) }
            )
        }
        addTeardownBlock { @MainActor in
            request.cancel()
            gate.release(24)
            await request.value
        }
        await fulfillment(of: [entered], timeout: 3)

        request.cancel()
        gate.release(24)
        await request.value

        XCTAssertTrue(gate.wasCancelledOnReturn)
        XCTAssertTrue(widths.isEmpty)
    }

    func testCancelledOldRequestCannotOverwriteSuccessorWidth() async {
        let entered = expectation(description: "old metadata continuation registered")
        let gate = ReaderBookCoverWidthGate(entered)
        var widths: [CGFloat] = []
        let old = Task { @MainActor in
            await refreshReaderBookCoverWidth(
                resolve: { await gate.wait() },
                publish: { widths.append($0) }
            )
        }
        addTeardownBlock { @MainActor in
            old.cancel()
            gate.release(24)
            await old.value
        }
        await fulfillment(of: [entered], timeout: 3)

        // The existing .task(id:) cancels its old caller on URL/dimension changes.
        old.cancel()
        await refreshReaderBookCoverWidth(resolve: { 72 }, publish: { widths.append($0) })
        gate.release(24)
        await old.value

        XCTAssertTrue(gate.wasCancelledOnReturn)
        XCTAssertEqual(widths, [72])
    }

    func testCurrentDelayedRequestPublishes() async {
        let entered = expectation(description: "current metadata continuation registered")
        let gate = ReaderBookCoverWidthGate(entered)
        var widths: [CGFloat] = []
        let request = Task { @MainActor in
            await refreshReaderBookCoverWidth(
                resolve: { await gate.wait() },
                publish: { widths.append($0) }
            )
        }
        addTeardownBlock { @MainActor in
            request.cancel()
            gate.release(24)
            await request.value
        }
        await fulfillment(of: [entered], timeout: 3)

        gate.release(24)
        await request.value

        XCTAssertFalse(gate.wasCancelledOnReturn)
        XCTAssertEqual(widths, [24])
    }

    func testCancellationBeforeResolverReturnsPreventsPublication() async {
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

/// Controls only the metadata collaborator; cancellation and publication execute
/// the same production helper called by BookCoverImageView's .task(id:).
@MainActor
private final class ReaderBookCoverWidthGate {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<CGFloat, Never>?
    private var releasedWidth: CGFloat?
    private var hasWaited = false
    private(set) var wasCancelledOnReturn = false

    init(_ entered: XCTestExpectation) {
        self.entered = entered
    }

    func wait() async -> CGFloat {
        guard !hasWaited else {
            XCTFail("This fixture expects one metadata read")
            return 0
        }
        hasWaited = true
        let width = await withCheckedContinuation { continuation in
            if let releasedWidth {
                continuation.resume(returning: releasedWidth)
            } else {
                self.continuation = continuation
            }
            entered.fulfill()
        }
        wasCancelledOnReturn = Task.isCancelled
        return width
    }

    func release(_ width: CGFloat) {
        guard releasedWidth == nil else { return }
        releasedWidth = width
        continuation?.resume(returning: width)
        continuation = nil
    }
}
