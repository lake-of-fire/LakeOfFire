import XCTest
@testable import LakeOfFireReader

final class ReaderTTSProgressEvaluatorTests: XCTestCase {
    func testFractionUsesUTF16Offsets() {
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "A😀B",
                spokenRange: NSRange(location: 1, length: 2)
            ),
            0.75
        )
    }

    func testFractionClampsRangesPastTextEnd() {
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "本文",
                spokenRange: NSRange(location: 1, length: 10)
            ),
            1
        )
    }

    func testFractionSaturatesOverflowingRange() {
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "A😀B",
                spokenRange: NSRange(location: Int.max - 1, length: 10)
            ),
            1
        )
    }

    func testFractionRejectsInvalidOrEmptyInput() {
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "本文",
                spokenRange: NSRange(location: NSNotFound, length: 0)
            ),
            0
        )
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "本文",
                spokenRange: NSRange(location: -1, length: 1)
            ),
            0
        )
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "",
                spokenRange: NSRange(location: 0, length: 1)
            ),
            0
        )
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(text: "本文", spokenRange: nil),
            0
        )
    }
}
