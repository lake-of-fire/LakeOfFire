import Foundation
import XCTest
@testable import LakeOfFireReader

final class ReaderEBookFirstPageGeometryTests: XCTestCase {
    private var payload: [String: Any] {
        ["kind": "paginated-first-page-v1", "targetSectionIndex": 4, "sectionIndex": 4,
         "targetAnchor": 0, "fractionInSection": 0, "pageFraction": 0.25]
    }

    func testFirstPageGeometryRequiresExactSectionAndLocalPageStart() throws {
        XCTAssertTrue(try XCTUnwrap(ReaderEBookFirstPageGeometry(payload: payload)).matchesFirstPage)
        for (key, value): (String, Any) in [("sectionIndex", 5), ("targetAnchor", 0.001), ("fractionInSection", 0.001)] {
            var changed = payload
            changed[key] = value
            XCTAssertFalse(try XCTUnwrap(ReaderEBookFirstPageGeometry(payload: changed)).matchesFirstPage)
        }
    }

    func testMalformedGeometryNeverCreatesAFirstPageProof() {
        for key in ["targetSectionIndex", "sectionIndex", "targetAnchor", "fractionInSection", "pageFraction"] {
            for value: Any in [true, false, "0", Double.nan, Double.infinity, -1] {
                var changed = payload
                changed[key] = value
                XCTAssertNil(ReaderEBookFirstPageGeometry(payload: changed), key)
            }
        }
        for value: Any in [0, 1.01] {
            var changed = payload
            changed["pageFraction"] = value
            XCTAssertNil(ReaderEBookFirstPageGeometry(payload: changed))
        }
        for value: Any in [0.5, 9_007_199_254_740_992.0] {
            var changed = payload
            changed["sectionIndex"] = value
            XCTAssertNil(ReaderEBookFirstPageGeometry(payload: changed))
        }
    }

    func testTerminalResultDecodesModeAndGeometryWithoutInventingMissingProof() throws {
        var result: [String: Any] = [
            "requestID": "zero", "requestedLocator": "fraction", "terminalState": "satisfied",
            "navigationOk": true, "restoreSatisfied": true,
            "handledFractionalCompletion": 0.125, "currentFractionalCompletion": 0.125,
            "positionMode": "paginated", "firstPageGeometry": payload,
        ]
        let decoded = try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: result))
        XCTAssertEqual(decoded.positionMode, .paginated)
        XCTAssertTrue(decoded.firstPageGeometry?.matchesFirstPage == true)
        XCTAssertEqual(decoded.currentFractionalCompletion, 0.125)
        result["positionMode"] = "unknown"
        result["firstPageGeometry"] = NSNull()
        let absent = try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: result))
        XCTAssertNil(absent.positionMode)
        XCTAssertNil(absent.firstPageGeometry)
    }
}
