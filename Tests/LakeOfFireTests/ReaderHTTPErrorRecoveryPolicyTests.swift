import XCTest
@testable import LakeOfFireReader

final class ReaderHTTPErrorRecoveryPolicyTests: XCTestCase {
    func testHTTPErrorStatusDetectionOnlyTreats4xxAnd5xxAsErrors() {
        XCTAssertFalse(ReaderHTTPErrorRecoveryPolicy.isHTTPErrorStatus(nil))
        XCTAssertFalse(ReaderHTTPErrorRecoveryPolicy.isHTTPErrorStatus(200))
        XCTAssertFalse(ReaderHTTPErrorRecoveryPolicy.isHTTPErrorStatus(399))
        XCTAssertTrue(ReaderHTTPErrorRecoveryPolicy.isHTTPErrorStatus(400))
        XCTAssertTrue(ReaderHTTPErrorRecoveryPolicy.isHTTPErrorStatus(404))
        XCTAssertTrue(ReaderHTTPErrorRecoveryPolicy.isHTTPErrorStatus(500))
    }

    func testReaderStateIsPreservedOnlyForMainFrameHTTPErrorResponses() {
        XCTAssertTrue(
            ReaderHTTPErrorRecoveryPolicy.shouldPreserveReaderState(
                isMainFrame: true,
                statusCode: 404
            )
        )
        XCTAssertTrue(
            ReaderHTTPErrorRecoveryPolicy.shouldPreserveReaderState(
                isMainFrame: true,
                statusCode: 500
            )
        )
        XCTAssertFalse(
            ReaderHTTPErrorRecoveryPolicy.shouldPreserveReaderState(
                isMainFrame: false,
                statusCode: 404
            )
        )
        XCTAssertFalse(
            ReaderHTTPErrorRecoveryPolicy.shouldPreserveReaderState(
                isMainFrame: true,
                statusCode: 200
            )
        )
        XCTAssertFalse(
            ReaderHTTPErrorRecoveryPolicy.shouldPreserveReaderState(
                isMainFrame: true,
                statusCode: nil
            )
        )
    }

    func testShowOriginalKeepsReaderModeRecoverableWhenCapturedReadabilityContentExists() {
        let update = ReaderHTTPErrorRecoveryPolicy.showOriginalFlagUpdate(
            currentFlags: .init(
                isReaderModeByDefault: true,
                isReaderModeAvailable: false,
                isReaderModeOfferHidden: false
            ),
            hasCapturedReadabilityContent: true
        )

        XCTAssertEqual(
            update.flags,
            .init(
                isReaderModeByDefault: false,
                isReaderModeAvailable: true,
                isReaderModeOfferHidden: true
            )
        )
        XCTAssertTrue(update.didChange)
    }

    func testShowOriginalDoesNotInventReaderRecoveryWithoutCapturedOrStoredFullContent() {
        let update = ReaderHTTPErrorRecoveryPolicy.showOriginalFlagUpdate(
            currentFlags: .init(
                isReaderModeByDefault: true,
                isReaderModeAvailable: false,
                isReaderModeOfferHidden: false
            ),
            hasCapturedReadabilityContent: false
        )

        XCTAssertEqual(
            update.flags,
            .init(
                isReaderModeByDefault: false,
                isReaderModeAvailable: false,
                isReaderModeOfferHidden: false
            )
        )
        XCTAssertTrue(update.didChange)
    }

    func testShowOriginalKeepsReaderModeRecoverableForStoredFullContent() {
        let update = ReaderHTTPErrorRecoveryPolicy.showOriginalFlagUpdate(
            currentFlags: .init(
                isReaderModeByDefault: true,
                isReaderModeAvailable: false,
                isReaderModeOfferHidden: false
            ),
            hasCapturedReadabilityContent: false,
            hasStoredFullContent: true
        )

        XCTAssertEqual(
            update.flags,
            .init(
                isReaderModeByDefault: false,
                isReaderModeAvailable: true,
                isReaderModeOfferHidden: true
            )
        )
        XCTAssertTrue(update.didChange)
    }
}
