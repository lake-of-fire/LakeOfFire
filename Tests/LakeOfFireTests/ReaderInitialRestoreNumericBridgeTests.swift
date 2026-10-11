import Foundation
import XCTest
@testable import LakeOfFireReader

final class ReaderInitialRestoreNumericBridgeTests: XCTestCase {
    private func payload() -> [String: Any] {
        [
            "requestID": "6244166C-35A8-4D07-B58B-8D29A4A3FB73",
            "requestedLocator": "fraction", "terminalState": "satisfied",
            "navigationOk": true, "restoreSatisfied": true,
            "handledFractionalCompletion": NSNumber(value: 0),
            "currentFractionalCompletion": NSNumber(value: 0.0),
        ]
    }

    func testNumericZeroSurvivesWebKitBridgeDecoding() throws {
        let result = try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: payload()))
        XCTAssertEqual(result.handledFractionalCompletion, 0)
        XCTAssertEqual(result.currentFractionalCompletion, 0)
    }

    func testMalformedNumericEvidenceCannotDisappearFromSuccessfulRestore() {
        for value in [NSNumber(value: false), NSNumber(value: true), NSNumber(value: Double.nan),
                      NSNumber(value: Double.infinity), NSNumber(value: -0.001), NSNumber(value: 1.001)] {
            for key in ["handledFractionalCompletion", "currentFractionalCompletion"] {
                var input = payload()
                input[key] = value
                XCTAssertNil(ReaderContentEbookInitialRestoreResult(payload: input))
            }
        }
    }
}
