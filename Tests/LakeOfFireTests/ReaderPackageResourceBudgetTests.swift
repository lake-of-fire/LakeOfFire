import Foundation
import XCTest
@testable import LakeOfFireContent

final class ReaderPackageResourceBudgetTests: XCTestCase {
    func testPresetsAndNegativeLimits() {
        XCTAssertEqual(ReaderPackageResourceLimits.default.maxEntryBytes, 64 * 1024 * 1024)
        XCTAssertEqual(ReaderPackageResourceLimits.metadata.maxEntryBytes, 8 * 1024 * 1024)
        XCTAssertEqual(ReaderPackageResourceLimits.image.maxEntryBytes, 128 * 1024 * 1024)
        let limits = ReaderPackageResourceLimits(maxEntryCount: -1, maxEntryBytes: -1,
            maxAggregateUncompressedBytes: -1, maxPathUTF8Bytes: -1, maxAggregatePathUTF8Bytes: -1)
        XCTAssertEqual(limits.maxEntryCount, 0)
        XCTAssertEqual(limits.maxEntryBytes, 0)
        XCTAssertEqual(limits.maxAggregateUncompressedBytes, 0)
        XCTAssertEqual(limits.maxPathUTF8Bytes, 0)
        XCTAssertEqual(limits.maxAggregatePathUTF8Bytes, 0)
    }

    func testCatalogCountIncludesZeroByteEntriesAndFailureDoesNotConsumeBudget() throws {
        var budget = ReaderPackageCatalogBudget(limits: .init(maxEntryCount: 2))
        try budget.include(path: "dir/", uncompressedSize: 0)
        try budget.include(path: "empty", uncompressedSize: 0)
        XCTAssertThrowsError(try budget.include(path: "extra", uncompressedSize: 0)) {
            XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entryCountExceeded(limit: 2))
        }
        XCTAssertEqual(budget.entryCount, 2)
        XCTAssertEqual(budget.uncompressedBytes, 0)
        XCTAssertEqual(budget.pathUTF8Bytes, 9)
    }

    func testCatalogAggregateAcceptsExactLimit() throws {
        var budget = ReaderPackageCatalogBudget(limits: .init(maxAggregateUncompressedBytes: 7))
        try budget.include(path: "a", uncompressedSize: 3)
        try budget.include(path: "b", uncompressedSize: 4)
        XCTAssertThrowsError(try budget.include(path: "c", uncompressedSize: 1)) {
            XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .aggregateSizeExceeded(limit: 7))
        }
        XCTAssertEqual(budget.entryCount, 2)
        XCTAssertEqual(budget.uncompressedBytes, 7)
        try budget.include(path: "empty", uncompressedSize: 0)
    }

    func testUnrepresentableAdvertisedSizeCannotOverflowAggregate() throws {
        var budget = ReaderPackageCatalogBudget(limits: .init(maxAggregateUncompressedBytes: .max))
        try budget.include(path: "a", uncompressedSize: 1)
        XCTAssertThrowsError(try budget.include(path: "b", uncompressedSize: UInt64.max))
        XCTAssertEqual(budget.entryCount, 1)
        XCTAssertEqual(budget.uncompressedBytes, 1)
        try budget.include(path: "c", uncompressedSize: UInt64(Int64.max - 1))
        XCTAssertEqual(budget.uncompressedBytes, Int64.max)
    }

    func testPathLimitsMeasureUTF8NotCharacterCount() throws {
        var budget = ReaderPackageCatalogBudget(limits: .init(maxPathUTF8Bytes: 3))
        try budget.include(path: "日", uncompressedSize: 0)
        XCTAssertThrowsError(try budget.include(path: "日本", uncompressedSize: 0)) {
            XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entryPathSizeExceeded(limit: 3))
        }
        XCTAssertEqual(budget.pathUTF8Bytes, 3)
        XCTAssertEqual(budget.entryCount, 1)
    }

    func testTotalPathLimitCannotBeEvadedByEmptyFiles() throws {
        var budget = ReaderPackageCatalogBudget(limits: .init(maxAggregatePathUTF8Bytes: 4))
        try budget.include(path: "ab", uncompressedSize: 0)
        try budget.include(path: "cd", uncompressedSize: 0)
        XCTAssertThrowsError(try budget.include(path: "e", uncompressedSize: 0)) {
            XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .aggregatePathSizeExceeded(limit: 4))
        }
        XCTAssertEqual(budget.pathUTF8Bytes, 4)
    }

    func testCatalogDoesNotApplyReadCapToUnrequestedMedia() throws {
        var budget = ReaderPackageCatalogBudget(limits: .init(maxEntryBytes: 1, maxAggregateUncompressedBytes: 8))
        try budget.include(path: "media", uncompressedSize: 8)
        XCTAssertEqual(budget.uncompressedBytes, 8)
    }

    func testAdvertisedReadSizeRejectsUnrepresentableAndOversizedValues() throws {
        let limits = ReaderPackageResourceLimits(maxEntryBytes: 4)
        try limits.validateAdvertisedEntrySize(4, path: "a")
        XCTAssertThrowsError(try limits.validateAdvertisedEntrySize(5, path: "a")) {
            XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entrySizeExceeded(path: "a", size: 5, limit: 4))
        }
        XCTAssertThrowsError(try limits.validateAdvertisedEntrySize(UInt64.max, path: "a"))
    }

    func testActualBytesRejectFirstExcessChunkWithoutAppendingIt() throws {
        var accumulator = ReaderPackageEntryAccumulator(path: "a", limits: .init(maxEntryBytes: 4))
        try accumulator.append(Data([1, 2]))
        XCTAssertThrowsError(try accumulator.append(Data([3, 4, 5]))) {
            XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .actualEntrySizeExceeded(path: "a", limit: 4))
        }
        XCTAssertEqual(accumulator.data, Data([1, 2]))
        try accumulator.append(Data([3, 4]))
        try accumulator.append(Data())
        XCTAssertEqual(accumulator.data, Data([1, 2, 3, 4]))
    }

    func testZeroReadBudgetAcceptsOnlyEmptyChunks() throws {
        var accumulator = ReaderPackageEntryAccumulator(path: "a", limits: .init(maxEntryBytes: 0))
        try accumulator.append(Data())
        XCTAssertThrowsError(try accumulator.append(Data([1])))
        XCTAssertTrue(accumulator.data.isEmpty)
    }
}
