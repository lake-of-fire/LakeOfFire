import XCTest
@testable import LakeOfFireReader

final class ReaderContentEbookInitialRestoreResultTests: XCTestCase {
    func testResultParsesRequestIdentityAndTerminalSnapshot() throws {
        let result = try XCTUnwrap(
            ReaderContentEbookInitialRestoreResult(
                payload: [
                    "requestID": "0F533D4B-D99F-42D0-9614-5B1FB5C64690",
                    "requestedLocator": "fraction",
                    "terminalState": "satisfied",
                    "navigationOk": true,
                    "restoreSatisfied": true,
                    "handledFractionalCompletion": 0.42,
                    "currentFractionalCompletion": 0.421,
                    "handledCFI": NSNull(),
                    "error": NSNull(),
                ]
            )
        )

        XCTAssertEqual(result.requestID, "0F533D4B-D99F-42D0-9614-5B1FB5C64690")
        XCTAssertEqual(result.requestedLocator, "fraction")
        XCTAssertEqual(result.terminalState, .satisfied)
        XCTAssertTrue(result.navigationOk)
        XCTAssertTrue(result.restoreSatisfied)
        XCTAssertEqual(result.handledFractionalCompletion, 0.42)
        XCTAssertEqual(result.currentFractionalCompletion, 0.421)
        XCTAssertNil(result.handledCFI)
        XCTAssertNil(result.error)
    }

    func testResultRejectsMissingTerminalContractFields() {
        XCTAssertNil(
            ReaderContentEbookInitialRestoreResult(
                payload: [
                    "requestedLocator": "cfi",
                    "terminalState": "satisfied",
                ]
            )
        )
    }

    func testFailureDoesNotBecomeSatisfied() throws {
        let result = try XCTUnwrap(
            ReaderContentEbookInitialRestoreResult(
                payload: [
                    "requestID": "6244166C-35A8-4D07-B58B-8D29A4A3FB73",
                    "requestedLocator": "cfi",
                    "terminalState": "failed",
                    "navigationOk": false,
                    "restoreSatisfied": false,
                    "error": "invalid saved CFI",
                ]
            )
        )

        XCTAssertEqual(result.terminalState, .failed)
        XCTAssertFalse(result.navigationOk)
        XCTAssertFalse(result.restoreSatisfied)
        XCTAssertEqual(result.error, "invalid saved CFI")
    }
}
