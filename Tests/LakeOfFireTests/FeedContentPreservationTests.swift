import XCTest
import RealmSwift
@testable import LakeOfFireContent

final class FeedContentPreservationTests: XCTestCase {
    func testAbsentAndSummaryBodiesPreserveCapturedArticle() {
        let content = Bookmark()
        content.content = Data("captured article".utf8)
        content.rssContainsFullContent = true
        XCTAssertFalse(applyFeedBody(nil, containsFullContent: false, to: content))
        XCTAssertFalse(applyFeedBody(Data(), containsFullContent: true, to: content))
        XCTAssertFalse(applyFeedBody(Data("summary".utf8), containsFullContent: false, to: content))
        XCTAssertEqual(content.content, Data("captured article".utf8))
        XCTAssertTrue(content.rssContainsFullContent)
    }

    func testIdenticalFullBodyPromotesAuthorityOnce() {
        let content = HistoryRecord()
        let body = Data("article".utf8)
        content.content = body
        XCTAssertTrue(applyFeedBody(body, containsFullContent: true, to: content))
        XCTAssertTrue(content.rssContainsFullContent)
        XCTAssertFalse(applyFeedBody(body, containsFullContent: true, to: content))
    }

    func testPayloadUpdatesAudioWhilePreservingCapturedBody() {
        let entry = FeedEntry()
        entry.url = URL(string: "https://example.com/article")!
        entry.html = "summary"
        let first = URL(string: "https://example.com/one.mp3")!
        let second = URL(string: "https://example.com/two.mp3")!
        entry.voiceAudioURL = first
        entry.voiceAudioURLs.append(objectsIn: [first, second])
        entry.updateCompoundKey()
        let content = Bookmark()
        content.content = Data("captured".utf8)
        content.rssContainsFullContent = true
        let payload = FeedEntryPayload(entry: entry, existing: nil, containsFullContent: false)
        XCTAssertTrue(applyPayload(payload, to: content))
        XCTAssertEqual(content.content, Data("captured".utf8))
        XCTAssertTrue(content.rssContainsFullContent)
        XCTAssertEqual(Array(content.voiceAudioURLs), [first, second])
        XCTAssertFalse(applyPayload(payload, to: content))
    }

}
