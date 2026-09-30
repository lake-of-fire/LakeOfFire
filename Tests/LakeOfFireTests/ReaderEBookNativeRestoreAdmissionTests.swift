import Foundation
import XCTest
import LakeOfFireContent
@testable import LakeOfFireReader

final class ReaderEBookNativeRestoreAdmissionTests: XCTestCase {
    func testNoSavedValueRemainsAbsent() throws {
        for cfi: String? in [nil, ""] {
            XCTAssertNil(try ReaderContentEbookInitialRestore(
                validatingCFI: cfi, fractionalCompletion: nil
            ))
        }
    }

    func testBothZeroRepresentationsArePresentAndNotClamped() throws {
        for fraction: Float in [0, -0.0] {
            let value = try XCTUnwrap(try ReaderContentEbookInitialRestore(
                validatingCFI: nil, fractionalCompletion: fraction
            ))
            XCTAssertEqual(value.cfi, "")
            XCTAssertEqual(try XCTUnwrap(value.fractionalCompletion).bitPattern, fraction.bitPattern)
            let bridge = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(restore: value))
            XCTAssertEqual(try XCTUnwrap(bridge.fractionalCompletion).sign, Double(fraction).sign)
        }
    }

    func testRepresentativeFiniteFractionsPreserveExactFloatValue() throws {
        for fraction: Float in [.leastNonzeroMagnitude, .leastNormalMagnitude, 0.25, 0.33333334, Float(1).nextDown, 1] {
            let value = try XCTUnwrap(try ReaderContentEbookInitialRestore(
                validatingCFI: "", fractionalCompletion: fraction
            ))
            let bridge = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(restore: value))
            XCTAssertEqual(value.fractionalCompletion, fraction)
            XCTAssertEqual(bridge.fractionalCompletion, Double(fraction))
        }
    }

    func testMalformedPresentFractionThrowsForEveryCFIPresence() {
        for cfi: String? in [nil, "", "epubcfi(/6/4!)"] {
            for fraction: Float in [.nan, .infinity, -.infinity, -Float.leastNonzeroMagnitude, Float(1).nextUp] {
                XCTAssertThrowsError(try ReaderContentEbookInitialRestore(
                    validatingCFI: cfi, fractionalCompletion: fraction
                )) { XCTAssertEqual($0 as? ReaderEBookInitialRestoreError, .invalidFraction) }
            }
        }
    }

    func testValidCFIRemainsByteExactAndDoesNotInventFraction() throws {
        for cfi in ["epubcfi(/6/4[日本語]!/4/2:0)", "mnb-loc-v1:2:0:30", "e\u{301}", " "] {
            let value = try XCTUnwrap(try ReaderContentEbookInitialRestore(
                validatingCFI: cfi, fractionalCompletion: nil
            ))
            let bridge = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(restore: value))
            XCTAssertEqual(Array(bridge.cfi.utf8), Array(cfi.utf8))
            XCTAssertEqual(bridge.requestedLocator, "cfi")
            XCTAssertNil(bridge.fractionalCompletion)
            XCTAssertNil(bridge.javaScriptArgument["fractionalCompletion"])
        }
    }

    func testTwoNativeRequestsHaveIndependentCorrelationIDs() throws {
        let value = ReaderContentEbookInitialRestore(cfi: "", fractionalCompletion: 0)
        let first = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(restore: value))
        let second = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(restore: value))
        XCTAssertNotEqual(first.requestID, second.requestID)
        XCTAssertNotNil(UUID(uuidString: first.requestID))
        XCTAssertEqual(first.javaScriptArgument["requestID"] as? String, first.requestID)
        XCTAssertEqual(first.javaScriptArgument["requestID"] as? String, first.javaScriptArgument["requestID"] as? String)
    }

    func testBridgeSerializationContainsNumericNotBooleanZeroAndOne() throws {
        for fraction: Float in [0, 1] {
            let bridge = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(
                restore: .init(cfi: "", fractionalCompletion: fraction)
            ))
            let data = try JSONSerialization.data(withJSONObject: bridge.javaScriptArgument, options: [.sortedKeys])
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let number = try XCTUnwrap(object["fractionalCompletion"] as? NSNumber)
            XCTAssertEqual(number.doubleValue, Double(fraction))
            let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(encoded.contains("true"))
            XCTAssertFalse(encoded.contains("false"))
        }
    }

    func testBridgeRevalidatesRawLegacyConstructor() {
        let value = ReaderContentEbookInitialRestore(cfi: "epubcfi(/6/4!)", fractionalCompletion: .nan)
        // The old initializer stays source compatible, but is not admission.
        XCTAssertTrue(value.fractionalCompletion?.isNaN == true)
        XCTAssertThrowsError(try ReaderEBookInitialRestoreBridgeRequest(restore: value)) {
            XCTAssertEqual($0 as? ReaderEBookInitialRestoreError, .invalidFraction)
        }
    }

    func testValidationDoesNotModifyTheOriginalSnapshot() throws {
        let original = ReaderContentEbookInitialRestore(cfi: "epubcfi(/6/4!)", fractionalCompletion: 0)
        let bridge = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(restore: original))
        XCTAssertEqual(original.cfi, bridge.cfi)
        XCTAssertEqual(original.fractionalCompletion, 0)
        XCTAssertEqual(bridge.requestedLocator, "cfi")
    }

    func testValidationErrorContainsNoStoredReadingData() {
        let message = ReaderEBookInitialRestoreError.invalidFraction.localizedDescription
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("epubcfi"))
        XCTAssertFalse(message.contains("ebook://"))
    }

    func testValidLocatorAlwaysAgreesWithSharedPolicy() throws {
        // Exercise a deterministic spread of representable values, including
        // distinct subnormal/endpoint cases without mutating any stored model.
        for numerator in 0...1024 {
            let fraction = Float(numerator) / 1024
            XCTAssertTrue(ReaderEBookInitialRestorePolicy.shouldRequestRestore(cfi: "", fractionalCompletion: fraction))
            let value = try XCTUnwrap(try ReaderContentEbookInitialRestore(validatingCFI: "", fractionalCompletion: fraction))
            XCTAssertNotNil(try ReaderEBookInitialRestoreBridgeRequest(restore: value))
        }
    }
}
