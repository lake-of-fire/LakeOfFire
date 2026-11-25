import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class ReaderContentPublicationDateTests: XCTestCase {
    @MainActor
    func testSavedRSSHistoryUsesItsPublicationDateWithoutDiscoveringOtherRecords() async throws {
        let history = HistoryRecord()
        history.url = try XCTUnwrap(URL(string: "https://example.com/saved-feed-article"))
        history.rssContainsFullContent = true
        history.publicationDate = Date(timeIntervalSinceNow: -86_400)

        let date = await readerContentPublicationDateFallback(for: history) { _ in
            XCTFail("The saved RSS history already carries a publication date")
            return nil
        }

        XCTAssertNotNil(date)
    }

    @MainActor
    func testSavedRSSHistoryWithoutPublicationDateStillUsesRelatedRecords() async throws {
        let history = HistoryRecord()
        history.url = try XCTUnwrap(URL(string: "https://example.com/older-feed-article"))
        history.rssContainsFullContent = true

        let date = await readerContentPublicationDateFallback(for: history) { url in
            XCTAssertEqual(url, history.url)
            return "Date from the source record"
        }

        XCTAssertEqual(date, "Date from the source record")
    }
}
