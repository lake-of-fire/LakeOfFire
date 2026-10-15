import CoreGraphics
import XCTest
@testable import LakeOfFireReader

@MainActor
final class ReaderContentInitialImageRendererTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ReaderContentInitialImageRenderer.resetCacheForTesting()
    }

    func testRenderUsesDisplayScaleForPixelDimensions() throws {
        let oneX = try image(initial: "A", dimension: 24, displayScale: 1)
        let twoX = try image(initial: "A", dimension: 24, displayScale: 2)
        let threeX = try image(initial: "A", dimension: 24, displayScale: 3)

        XCTAssertEqual(oneX.width, 24)
        XCTAssertEqual(oneX.height, 24)
        XCTAssertEqual(twoX.width, 48)
        XCTAssertEqual(twoX.height, 48)
        XCTAssertEqual(threeX.width, 72)
        XCTAssertEqual(threeX.height, 72)
    }

    func testRenderReusesCachedImageForSameTextAndPixelSize() throws {
        let first = try image(initial: "A", dimension: 24, displayScale: 3)
        let second = try image(initial: "A", dimension: 24, displayScale: 3)

        XCTAssertTrue(first === second)
    }

    func testRenderSeparatesTextAndPixelSizeCacheKeys() throws {
        let base = try image(initial: "A", dimension: 24, displayScale: 3)
        let otherText = try image(initial: "B", dimension: 24, displayScale: 3)
        let otherSize = try image(initial: "A", dimension: 25, displayScale: 3)

        XCTAssertFalse(base === otherText)
        XCTAssertFalse(base === otherSize)
        XCTAssertEqual(otherSize.width, 75)
    }

    func testCacheHasBoundedCountAndMemoryCost() {
        XCTAssertEqual(ReaderContentInitialImageRenderer.cacheCountLimit, 128)
        XCTAssertEqual(ReaderContentInitialImageRenderer.cacheTotalCostLimit, 4 * 1_024 * 1_024)
    }

    func testInvalidDimensionsReturnNilWithoutConvertingOrAllocating() {
        let dimensions: [CGFloat] = [
            .nan, .infinity, -.infinity, 0, -1, .greatestFiniteMagnitude, CGFloat(Int.max),
        ]
        for dimension in dimensions {
            XCTAssertNil(ReaderContentInitialImageRenderer.render(
                initial: "A", dimension: dimension, displayScale: 3
            ), "Invalid dimension: \(dimension)")
        }
    }

    func testInvalidDisplayScalesReturnNil() {
        let scales: [CGFloat] = [.nan, .infinity, -.infinity, 0, -1, .greatestFiniteMagnitude]
        for scale in scales {
            XCTAssertNil(ReaderContentInitialImageRenderer.render(
                initial: "A", dimension: 24, displayScale: scale
            ), "Invalid scale: \(scale)")
        }
    }

    func testFiniteDimensionsCannotOverflowRowOrBitmapCost() {
        // These are finite and may be representable as an Int, but the row or
        // square bitmap cost is not. Rejection must precede CGContext creation.
        for dimension in [CGFloat(Int.max / 4), CGFloat(4_294_967_296)] {
            XCTAssertNil(ReaderContentInitialImageRenderer.render(
                initial: "A", dimension: dimension, displayScale: 1
            ))
        }
    }

    func testOneBitmapCannotExceedTheExistingCacheBudget() throws {
        let boundary = try image(initial: "A", dimension: 1_024, displayScale: 1)
        XCTAssertEqual(boundary.width, 1_024)
        XCTAssertEqual(boundary.height, 1_024)
        XCTAssertEqual(boundary.bytesPerRow * boundary.height,
                       ReaderContentInitialImageRenderer.cacheTotalCostLimit)
        XCTAssertNil(ReaderContentInitialImageRenderer.render(
            initial: "A", dimension: 1_025, displayScale: 1
        ))
        XCTAssertNil(ReaderContentInitialImageRenderer.render(
            initial: "A", dimension: 513, displayScale: 2
        ))
    }

    func testFractionalPixelsRoundUpAndPositiveSubunitScaleKeepsOneX() throws {
        let fractional = try image(initial: "A", dimension: 24.1, displayScale: 2)
        XCTAssertEqual(fractional.width, 49)
        XCTAssertEqual(fractional.height, 49)
        let subunitScale = try image(initial: "A", dimension: 24, displayScale: 0.5)
        XCTAssertEqual(subunitScale.width, 24)
        XCTAssertEqual(subunitScale.height, 24)
    }

    func testRejectedGeometryDoesNotPoisonAnExistingCacheEntry() throws {
        let before = try image(initial: "A", dimension: 24, displayScale: 3)
        XCTAssertNil(ReaderContentInitialImageRenderer.render(
            initial: "A", dimension: .nan, displayScale: 3
        ))
        let after = try image(initial: "A", dimension: 24, displayScale: 3)
        XCTAssertTrue(before === after)
    }

    func testEmptyInitialRemainsUnrendered() {
        XCTAssertNil(ReaderContentInitialImageRenderer.render(
            initial: "", dimension: 24, displayScale: 3
        ))
    }

    private func image(
        initial: String,
        dimension: CGFloat,
        displayScale: CGFloat
    ) throws -> CGImage {
        try XCTUnwrap(
            ReaderContentInitialImageRenderer.render(
                initial: initial,
                dimension: dimension,
                displayScale: displayScale
            )
        )
    }
}
