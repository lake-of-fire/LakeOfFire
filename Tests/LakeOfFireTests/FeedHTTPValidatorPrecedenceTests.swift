import Foundation
import XCTest
@testable import LakeOfFireContent

final class FeedHTTPValidatorPrecedenceTests: XCTestCase {
    func testChangedEntityTagRequiresBodyDespiteEqualOrOlderModificationDate() {
        let cached = Date(timeIntervalSince1970: 1_700_000_000)
        for remote in [cached, cached.addingTimeInterval(-60)] {
            XCTAssertFalse(isFeedUnchanged(
                remoteMetadata: FeedFetchMetadata(etag: "\"new\"", lastModifiedAt: remote),
                lastFetchedETag: "\"old\"", lastFetchedModifiedAt: cached
            ))
        }
    }

    func testMatchingEntityTagRetainsExistingUnchangedDecision() {
        let cached = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(isFeedUnchanged(
            remoteMetadata: FeedFetchMetadata(etag: "\"same\"", lastModifiedAt: cached.addingTimeInterval(60)),
            lastFetchedETag: "\"same\"", lastFetchedModifiedAt: cached
        ))
    }

    func testDateFallbackRemainsAvailableWhenEitherEntityTagIsAbsent() {
        let cached = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(String?, String?)] = [(nil, "\"old\""), ("\"new\"", nil), (nil, nil)]
        for tags in cases {
            XCTAssertTrue(isFeedUnchanged(
                remoteMetadata: FeedFetchMetadata(etag: tags.0, lastModifiedAt: cached),
                lastFetchedETag: tags.1, lastFetchedModifiedAt: cached
            ))
        }
    }

    func testNewerDateWithoutEntityTagsRequiresBody() {
        let cached = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(isFeedUnchanged(
            remoteMetadata: FeedFetchMetadata(etag: nil, lastModifiedAt: cached.addingTimeInterval(60)),
            lastFetchedETag: nil, lastFetchedModifiedAt: cached
        ))
    }

    func testMissingValidatorsCannotProveUnchanged() {
        XCTAssertFalse(isFeedUnchanged(
            remoteMetadata: FeedFetchMetadata(etag: nil, lastModifiedAt: nil),
            lastFetchedETag: nil, lastFetchedModifiedAt: nil
        ))
    }
}
