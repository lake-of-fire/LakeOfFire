import Foundation
import XCTest
@testable import LakeOfFireReader

final class EbookRequestBodyBoundaryTests: XCTestCase {
    func testProcessTextRequestBodyAdmitsExactLimitButRejectsLimitPlusOne() throws {
        let maximumByteCount = 4
        let exactLimit = Data(repeating: 0x61, count: maximumByteCount)

        XCTAssertEqual(
            try ebookBoundedRequestBodyData(
                directBody: exactLimit,
                maximumByteCount: maximumByteCount
            ),
            exactLimit
        )

        var requestedStreamReadCounts = [Int]()
        var exactStreamChunks: [EbookRequestBodyStreamChunk] = [
            .data(exactLimit),
            .end,
        ]
        XCTAssertEqual(
            try ebookBoundedRequestBodyData(
                maximumByteCount: maximumByteCount,
                nextStreamChunk: { requestedByteCount in
                    requestedStreamReadCounts.append(requestedByteCount)
                    return exactStreamChunks.removeFirst()
                }
            ),
            exactLimit
        )
        XCTAssertEqual(
            requestedStreamReadCounts,
            [maximumByteCount + 1, 1]
        )

        XCTAssertThrowsError(
            try ebookBoundedRequestBodyData(
                directBody: Data(repeating: 0x61, count: maximumByteCount + 1),
                maximumByteCount: maximumByteCount
            )
        ) { error in
            XCTAssertEqual(error as? EbookRequestBodyError, .exceedsMaximumByteCount)
        }
    }

    func testProcessTextRequestBodyRejectsOversizedOrFailedStream() {
        var chunks: [EbookRequestBodyStreamChunk] = [
            .data(Data(repeating: 0x61, count: 4)),
            .data(Data([0x62])),
        ]
        XCTAssertThrowsError(
            try ebookBoundedRequestBodyData(
                maximumByteCount: 4,
                nextStreamChunk: { _ in chunks.removeFirst() }
            )
        ) { error in
            XCTAssertEqual(error as? EbookRequestBodyError, .exceedsMaximumByteCount)
        }

        XCTAssertThrowsError(
            try ebookBoundedRequestBodyData(
                maximumByteCount: 4,
                nextStreamChunk: { _ in .failure }
            )
        ) { error in
            XCTAssertEqual(error as? EbookRequestBodyError, .streamReadFailed)
        }
    }

    func testProcessTextRequestBodyRejectsEmptyAndObservesCancellationDuringStreamRead() {
        XCTAssertThrowsError(
            try ebookBoundedRequestBodyData(
                maximumByteCount: 4,
                nextStreamChunk: { _ in .end }
            )
        ) { error in
            XCTAssertEqual(error as? EbookRequestBodyError, .empty)
        }

        var consumedChunk = false
        XCTAssertThrowsError(
            try ebookBoundedRequestBodyData(
                maximumByteCount: 4,
                isCancelled: { consumedChunk },
                nextStreamChunk: { _ in
                    consumedChunk = true
                    return .data(Data([0x61]))
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }


    func testMaximumIntegerLimitDoesNotOverflowReadHint() throws {
        var hints: [Int] = []
        var chunks: [EbookRequestBodyStreamChunk] = [.data(Data([1])), .end]
        XCTAssertEqual(try ebookBoundedRequestBodyData(
            maximumByteCount: Int.max, nextStreamChunk: {
                hints.append($0)
                return chunks.removeFirst()
            }), Data([1]))
        XCTAssertEqual(hints, [Int.max, Int.max])
    }

    func testCancellationReportedAtEndCannotPublishAccumulatedBytes() {
        var cancelled = false
        var readCount = 0
        XCTAssertThrowsError(try ebookBoundedRequestBodyData(
            maximumByteCount: 4, isCancelled: { cancelled }, nextStreamChunk: { _ in
                readCount += 1
                if readCount == 1 { return .data(Data([1])) }
                cancelled = true
                return .end
            })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testActualURLRequestUsesBoundedDirectAndStreamReaders() throws {
        let bytes = Data([1, 2, 3, 4])
        var request = URLRequest(url: URL(string: "ebook://ebook/process-text")!)
        request.httpBody = bytes
        XCTAssertEqual(try ebookRequestBodyData(request, maximumByteCount: 4), bytes)
        XCTAssertThrowsError(try ebookRequestBodyData(request, maximumByteCount: 3))
        request.httpBody = nil
        request.httpBodyStream = InputStream(data: bytes)
        XCTAssertEqual(try ebookRequestBodyData(request, maximumByteCount: 4), bytes)
        request.httpBodyStream = InputStream(data: bytes)
        XCTAssertThrowsError(try ebookRequestBodyData(request, maximumByteCount: 3))
    }

    func testNegativeAndZeroLimitsRejectNonemptyRequests() {
        for limit in [-1, 0] {
            XCTAssertThrowsError(try ebookBoundedRequestBodyData(
                directBody: Data([1]), maximumByteCount: limit)) {
                XCTAssertEqual($0 as? EbookRequestBodyError, .exceedsMaximumByteCount)
            }
        }
    }
}
