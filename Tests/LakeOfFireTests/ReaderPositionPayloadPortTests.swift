import Foundation
import XCTest
@testable import LakeOfFireReader

final class ReaderPositionPayloadPortTests: XCTestCase {
    private func position(_ values: [String: Any] = [:]) -> [String: Any] {
        ["fractionalCompletion": 0.25, "cfi": "epubcfi(/6/10)", "reason": "user-navigation"]
            .merging(values, uniquingKeysWith: { _, new in new })
    }

    private func receipt(_ values: [String: Any] = [:]) -> [String: Any] {
        ["requestID": "restore-1", "requestedLocator": "fraction", "terminalState": "satisfied",
         "navigationOk": true, "restoreSatisfied": true,
         "handledFractionalCompletion": 0.25, "currentFractionalCompletion": 0.25]
            .merging(values, uniquingKeysWith: { _, new in new })
    }

    func testRejectsInvalidFractionsRatherThanClamping() {
        for value: Any in [Double.nan, Double.infinity, -Double.infinity, -0.01, 1.01, true, false, "0.25", NSNull()] {
            XCTAssertNil(FractionalCompletionMessage(body: position(["fractionalCompletion": value])))
        }
    }

    func testProgressAcceptsNumericEndpointsThroughJSON() throws {
        for value in [0, 1] {
            let payload = try JSONSerialization.jsonObject(with: JSONSerialization.data(
                withJSONObject: position(["fractionalCompletion": value])))
            let message = try XCTUnwrap(FractionalCompletionMessage(body: payload))
            XCTAssertEqual(message.fractionalCompletion, Float(value))
        }
    }

    func testMissingRequiredFieldsAreRejected() {
        for field in ["fractionalCompletion", "cfi", "reason"] {
            var payload = position()
            payload.removeValue(forKey: field)
            XCTAssertNil(FractionalCompletionMessage(body: payload))
        }
        XCTAssertNil(FractionalCompletionMessage(body: []))
        XCTAssertNil(FractionalCompletionMessage(body: nil))
    }

    func testCFIBoundAcceptsExactBytesAndRejectsAnExtraByte() {
        let limit = FractionalCompletionMessage.maximumCFIUTF8Bytes
        XCTAssertNotNil(FractionalCompletionMessage(body: position(["cfi": String(repeating: "a", count: limit)])))
        XCTAssertNil(FractionalCompletionMessage(body: position(["cfi": String(repeating: "a", count: limit + 1)])))
    }

    func testReasonLimitCountsUTF8RatherThanCharacters() {
        let limit = FractionalCompletionMessage.maximumReasonUTF8Bytes
        let accepted = String(repeating: "日", count: limit / 3) + "ab"
        XCTAssertEqual(accepted.utf8.count, limit)
        XCTAssertNotNil(FractionalCompletionMessage(body: position(["reason": accepted])))
        XCTAssertNil(FractionalCompletionMessage(body: position(["reason": accepted + "c"])))
    }

    func testDocumentURLBoundaryAndMalformedValues() {
        let prefix = "https://example.invalid/"
        let accepted = prefix + String(repeating: "a", count: FractionalCompletionMessage.maximumURLUTF8Bytes - prefix.utf8.count)
        XCTAssertNotNil(FractionalCompletionMessage(body: position(["mainDocumentURL": accepted])))
        for value: Any in [accepted + "b", 42, NSNull()] {
            XCTAssertNil(FractionalCompletionMessage(body: position(["mainDocumentURL": value])))
        }
        XCTAssertNotNil(FractionalCompletionMessage(body: position()))
    }

    func testInvalidOptionalIntegersAreOmittedWithoutTrapping() throws {
        let keys = ["sectionIndex", "currentPageNumber", "totalPages", "visibleSegmentCount", "observedSegmentCount"]
        for value: Any in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude,
                           Double(Int.max), true, false, "not-an-integer", NSNull()] {
            let payload = position(Dictionary(uniqueKeysWithValues: keys.map { ($0, value) }))
            let message = try XCTUnwrap(FractionalCompletionMessage(body: payload))
            XCTAssertNil(message.sectionIndex)
            XCTAssertNil(message.currentPageNumber)
            XCTAssertNil(message.totalPages)
            XCTAssertNil(message.visibleSegmentCount)
            XCTAssertNil(message.observedSegmentCount)
        }
    }

    func testOptionalIntegerWireCompatibilityIsPreserved() throws {
        let message = try XCTUnwrap(FractionalCompletionMessage(body: position([
            "sectionIndex": 0, "currentPageNumber": 2.9, "totalPages": "10",
            "visibleSegmentCount": NSNumber(value: 3), "observedSegmentCount": -2.9,
        ])))
        XCTAssertEqual(message.sectionIndex, 0)
        XCTAssertEqual(message.currentPageNumber, 2)
        XCTAssertEqual(message.totalPages, 10)
        XCTAssertEqual(message.visibleSegmentCount, 3)
        XCTAssertEqual(message.observedSegmentCount, -2)
    }

    func testRepresentableIntegerExtremesRemainValid() throws {
        let message = try XCTUnwrap(FractionalCompletionMessage(body: position([
            "sectionIndex": Int.max, "observedSegmentCount": Int.min,
        ])))
        XCTAssertEqual(message.sectionIndex, Int.max)
        XCTAssertEqual(message.observedSegmentCount, Int.min)
    }

    func testKnownBlankViewportClassificationRemainsUnchanged() throws {
        let values: [String: Any] = ["visibleSegmentCount": 0, "observedSegmentCount": 12]
        let blank = try XCTUnwrap(FractionalCompletionMessage(body: position(values)))
        XCTAssertTrue(blank.representsKnownBlankViewport)
        let paged = try XCTUnwrap(FractionalCompletionMessage(body: position(values.merging(
            ["currentPageNumber": 1], uniquingKeysWith: { _, new in new }))))
        XCTAssertFalse(paged.representsKnownBlankViewport)
    }

    func testDocumentTimestampIsFiniteAndNeverBoolean() throws {
        let message = try XCTUnwrap(FractionalCompletionMessage(body: position(["documentStartedAtMs": 1_700_000_000_000.5])))
        XCTAssertEqual(message.documentStartedAtMilliseconds, 1_700_000_000_000.5)
        for value: Any in [true, false, "123", Double.nan, Double.infinity, NSNull()] {
            XCTAssertNil(FractionalCompletionMessage(body: position(["documentStartedAtMs": value])))
        }
        XCTAssertNil(try XCTUnwrap(FractionalCompletionMessage(body: position())).documentStartedAtMilliseconds)
    }

    func testVisibleJapaneseFlagAcceptsOnlyRealBooleans() throws {
        for value in [true, false] {
            XCTAssertEqual(try XCTUnwrap(FractionalCompletionMessage(body: position(["hasVisibleJapaneseText": value]))).hasVisibleJapaneseText, value)
        }
        for value: Any in [0, 1, "true"] {
            XCTAssertNil(try XCTUnwrap(FractionalCompletionMessage(body: position(["hasVisibleJapaneseText": value]))).hasVisibleJapaneseText)
        }
    }

    func testRestoreReceiptPreservesNumericEndpointsThroughJSON() throws {
        for value in [0, 1] {
            let payload = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: receipt([
                "handledFractionalCompletion": value, "currentFractionalCompletion": value,
            ])))
            let message = try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: payload))
            XCTAssertEqual(message.handledFractionalCompletion, Double(value))
            XCTAssertEqual(message.currentFractionalCompletion, Double(value))
        }
    }

    func testRestoreReceiptDropsInvalidFractionsWithoutReinterpretingThem() throws {
        for value: Any in [true, false, "0.5", Double.nan, Double.infinity, -0.1, 1.1, NSNull()] {
            let message = try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: receipt([
                "terminalState": "failed", "restoreSatisfied": false,
                "handledFractionalCompletion": value, "currentFractionalCompletion": value,
            ])))
            XCTAssertNil(message.handledFractionalCompletion)
            XCTAssertNil(message.currentFractionalCompletion)
        }
    }

    func testNumericBooleansCannotForgeRestoreSuccess() {
        for field in ["navigationOk", "restoreSatisfied"] {
            for value: Any in [0, 1, "true", NSNull()] {
                XCTAssertNil(ReaderContentEbookInitialRestoreResult(payload: receipt([field: value])))
            }
        }
    }

    func testContradictoryTerminalAcknowledgementsAreRejected() {
        let changes: [[String: Any]] = [
            ["terminalState": "failed"], ["terminalState": "noTarget"],
            ["restoreSatisfied": false], ["navigationOk": false], ["error": "navigation failed"],
        ]
        for change in changes { XCTAssertNil(ReaderContentEbookInitialRestoreResult(payload: receipt(change))) }
    }

    func testSuccessfulNavigationWithMissedTargetIsStillAValidFailureReceipt() throws {
        let message = try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: receipt([
            "terminalState": "failed", "restoreSatisfied": false,
            "error": "Saved restore position was not reached",
        ])))
        XCTAssertTrue(message.navigationOk)
        XCTAssertFalse(message.restoreSatisfied)
        XCTAssertEqual(message.terminalState, .failed)
        XCTAssertEqual(message.requestID, "restore-1")
    }

    func testNoTargetReceiptRetainsItsWireSemantics() throws {
        let message = try XCTUnwrap(ReaderContentEbookInitialRestoreResult(payload: [
            "requestID": NSNull(), "requestedLocator": "none", "terminalState": "noTarget",
            "navigationOk": true, "restoreSatisfied": false,
            "currentFractionalCompletion": 0, "error": NSNull(),
        ] as [String: Any]))
        XCTAssertEqual(message.terminalState, .noTarget)
        XCTAssertNil(message.requestID)
        XCTAssertEqual(message.currentFractionalCompletion, 0)
    }
}
