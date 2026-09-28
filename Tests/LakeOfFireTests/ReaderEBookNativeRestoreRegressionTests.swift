import Foundation
import XCTest
import LakeOfFireContent
@testable import LakeOfFireReader

/// These cases use the retained unchecked value initializer, so they can also
/// execute against the original native bridge as assertion-based controls.
final class ReaderEBookNativeRestoreRegressionTests: XCTestCase {
    func testSavedZeroSurvivesTheNativeBridge() throws {
        let request = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(
            restore: .init(cfi: "", fractionalCompletion: 0)
        ))
        XCTAssertEqual(request.requestedLocator, "fraction")
        XCTAssertEqual(request.fractionalCompletion, 0)
        XCTAssertEqual(request.javaScriptArgument["fractionalCompletion"] as? Double, 0)
    }

    func testInvalidPresentFractionCannotBecomeCFIOnlySuccess() {
        for fraction: Float in [.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertThrowsError(try ReaderEBookInitialRestoreBridgeRequest(
                restore: .init(cfi: "epubcfi(/6/4!)", fractionalCompletion: fraction)
            ))
        }
    }

    func testInvalidPresentFractionIsNotNoTarget() {
        for fraction: Float in [.nan, .infinity, -.infinity, -1, 2] {
            XCTAssertThrowsError(try ReaderEBookInitialRestoreBridgeRequest(
                restore: .init(cfi: "", fractionalCompletion: fraction)
            ))
        }
    }

    func testAbsentValueAndEmptyLocatorStillHaveNoRequest() throws {
        XCTAssertNil(try ReaderEBookInitialRestoreBridgeRequest(restore: nil))
        XCTAssertNil(try ReaderEBookInitialRestoreBridgeRequest(
            restore: .init(cfi: "", fractionalCompletion: nil)
        ))
    }

    func testCFIWithHistoricalZeroRetainsCFIPriority() throws {
        let cfi = "epubcfi(/6/4[章]!/4/2:0)"
        let request = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(
            restore: .init(cfi: cfi, fractionalCompletion: 0)
        ))
        XCTAssertEqual(request.requestedLocator, "cfi")
        XCTAssertEqual(request.cfi, cfi)
        XCTAssertEqual(request.fractionalCompletion, 0)
    }

    func testExactEndRemainsOne() throws {
        let request = try XCTUnwrap(try ReaderEBookInitialRestoreBridgeRequest(
            restore: .init(cfi: "", fractionalCompletion: 1)
        ))
        XCTAssertEqual(request.fractionalCompletion, 1)
    }
}
