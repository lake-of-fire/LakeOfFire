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

        XCTAssertEqual((oneX.width, oneX.height), (24, 24))
        XCTAssertEqual((twoX.width, twoX.height), (48, 48))
        XCTAssertEqual((threeX.width, threeX.height), (72, 72))
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
