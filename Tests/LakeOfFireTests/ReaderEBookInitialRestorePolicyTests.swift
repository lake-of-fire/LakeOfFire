import Foundation
import XCTest
@testable import LakeOfFireContent

final class ReaderEBookInitialRestorePolicyTests: XCTestCase {
    func testZeroIsARealRestorePosition() {
        XCTAssertTrue(ReaderEBookInitialRestorePolicy.shouldRequestRestore(
            cfi: "", fractionalCompletion: 0
        ))
        XCTAssertTrue(ReaderEBookInitialRestorePolicy.shouldRequestRestore(
            cfi: "", fractionalCompletion: -0.0
        ))
    }

    func testEndAndInteriorFractionsAreValid() {
        for value: Float in [0.25, 1] {
            XCTAssertTrue(ReaderEBookInitialRestorePolicy.shouldRequestRestore(
                cfi: "", fractionalCompletion: value
            ))
        }
    }

    func testAbsentLocatorIsNotARestoreRequest() {
        XCTAssertFalse(ReaderEBookInitialRestorePolicy.shouldRequestRestore(
            cfi: "", fractionalCompletion: nil
        ))
    }

    func testCFIOnlyRestoreRemainsValid() {
        XCTAssertTrue(ReaderEBookInitialRestorePolicy.shouldRequestRestore(
            cfi: "epubcfi(/6/4!)", fractionalCompletion: nil
        ))
    }

    func testMalformedPresentFractionRejectsEvenWithCFI() {
        for value: Float in [.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertFalse(ReaderEBookInitialRestorePolicy.shouldRequestRestore(
                cfi: "epubcfi(/6/4!)", fractionalCompletion: value
            ))
        }
    }
}
