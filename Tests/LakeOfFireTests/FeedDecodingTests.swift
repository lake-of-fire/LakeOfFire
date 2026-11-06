import XCTest
@testable import LakeOfFireContent

final class FeedDecodingTests: XCTestCase {
    func testContentAndImageSettingsSurviveCodableCopy() throws {
        for containsFullContent in [false, true] {
            let source = Feed()
            source.iconUrl = URL(string: "https://example.com/feed-icon.png")!
            source.rssContainsFullContent = containsFullContent
            source.extractImageFromContent = !containsFullContent

            let copy = try JSONDecoder().decode(Feed.self, from: JSONEncoder().encode(source))
            XCTAssertEqual(copy.iconUrl, source.iconUrl)
            XCTAssertEqual(copy.rssContainsFullContent, source.rssContainsFullContent)
            XCTAssertEqual(copy.extractImageFromContent, source.extractImageFromContent)
        }
    }

    func testLegacyCopyWithoutContentAndImageSettingsRetainsDefaults() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Feed())) as? [String: Any]
        )
        object.removeValue(forKey: "iconUrl")
        object.removeValue(forKey: "rssContainsFullContent")
        object.removeValue(forKey: "extractImageFromContent")
        let copy = try JSONDecoder().decode(
            Feed.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(copy.iconUrl, Feed().iconUrl)
        XCTAssertFalse(copy.rssContainsFullContent)
        XCTAssertTrue(copy.extractImageFromContent)
    }

    func testMissingOrNullMarkdownDescriptionDecodesAsNil() throws {
        let encoded = try JSONEncoder().encode(Feed())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        object.removeValue(forKey: "markdownDescription")
        let missingDescription = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(Feed.self, from: missingDescription).markdownDescription)

        object["markdownDescription"] = NSNull()
        let nullDescription = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(Feed.self, from: nullDescription).markdownDescription)
    }

    func testNonemptyMarkdownDescriptionIsDecoded() throws {
        let encoded = try JSONEncoder().encode(Feed())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["markdownDescription"] = "A feed description"

        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(
            try JSONDecoder().decode(Feed.self, from: data).markdownDescription,
            "A feed description"
        )
    }
}
