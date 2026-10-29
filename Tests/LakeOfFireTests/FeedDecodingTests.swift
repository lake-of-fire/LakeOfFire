import XCTest
import FeedKit
import SwiftSoup
@testable import LakeOfFireContent

final class FeedDecodingTests: XCTestCase {
    func testFeedURLParserPreservesExistingPercentEscapes() throws {
        for raw in [
            "https://publisher.example/a%2Fb?sig=a%2Fb&literal=%252F#part%20one",
            "https://images.example/photo.jpg?sig=a%2fb&size=large",
        ] {
            XCTAssertEqual(try XCTUnwrap(readerFeedURL(raw)).absoluteString, raw)
        }
    }

    func testAtomMediaGeometryMatchesExactEnclosureVariant() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
          <id>https://publisher.example/feed</id><title>Feed</title><updated>2026-10-27T00:00:00Z</updated>
          <entry><id>https://publisher.example/a</id><title>記事</title><updated>2026-10-27T00:00:00Z</updated>
            <link rel="enclosure" href="https://images.example/photo?sig=a%2Fb&amp;crop=wide" type="image/jpeg"/>
            <media:content url="https://images.example/photo?sig=a%2Fb&amp;crop=square" medium="image" width="100" height="100"/>
            <media:content url="https://images.example/photo?sig=a%2Fb&amp;crop=wide" medium="image" width="1920" height="1080"/>
          </entry>
        </feed>
        """
        let parsed = try FeedParser(data: Data(xml.utf8)).parse().get()
        let entry = try XCTUnwrap(parsed.atomFeed?.entries?.first)
        let url = try XCTUnwrap(URL(string: "https://images.example/photo?sig=a%2Fb&crop=wide"))
        let geometry = try XCTUnwrap(feedImageGeometry(imageURL: url, media: entry.media))
        XCTAssertEqual(geometry.width, 1920)
        XCTAssertEqual(geometry.height, 1080)
        XCTAssertNil(feedImageGeometry(imageURL: URL(string: "https://images.example/photo")!, media: entry.media))
        let html = try XCTUnwrap(geometry.addingToFeedHTML("<p>本文</p>", sourceURL: URL(string: "https://publisher.example/a")!))
        let document = try SwiftSoup.parse(html)
        XCTAssertEqual(try document.select("p").text(), "本文")
        XCTAssertTrue(try document.select("img").isEmpty(), "Metadata must not add a duplicate visible image")
    }

    func testMissingOrNullMarkdownDescriptionDecodesAsNil() throws {
        let encoded = try JSONEncoder().encode(LakeOfFireContent.Feed())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        object.removeValue(forKey: "markdownDescription")
        let missingDescription = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(Feed.self, from: missingDescription).markdownDescription)

        object["markdownDescription"] = NSNull()
        let nullDescription = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(Feed.self, from: nullDescription).markdownDescription)
    }

    func testNonemptyMarkdownDescriptionIsDecoded() throws {
        let encoded = try JSONEncoder().encode(LakeOfFireContent.Feed())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["markdownDescription"] = "A feed description"

        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(
            try JSONDecoder().decode(Feed.self, from: data).markdownDescription,
            "A feed description"
        )
    }
}
