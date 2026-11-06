import XCTest
@testable import LakeOfFireContent

final class FeedDecodingTests: XCTestCase {
    func testRoundTripPreservesContentAndImageSettings() throws {
        let feed = Feed()
        feed.iconUrl = try XCTUnwrap(URL(string: "https://example.org/custom-icon.png"))
        feed.rssContainsFullContent = true
        feed.extractImageFromContent = false

        let encoded = try JSONEncoder().encode(feed)
        let decoded = try JSONDecoder().decode(Feed.self, from: encoded)

        XCTAssertEqual(decoded.iconUrl, feed.iconUrl)
        XCTAssertTrue(decoded.rssContainsFullContent)
        XCTAssertFalse(decoded.extractImageFromContent)
    }

    func testLegacyPayloadWithoutContentAndImageSettingsRetainsModelDefaults() throws {
        let feed = Feed()
        feed.iconUrl = try XCTUnwrap(URL(string: "https://example.org/custom-icon.png"))
        feed.rssContainsFullContent = true
        feed.extractImageFromContent = false
        let encoded = try JSONEncoder().encode(feed)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["iconUrl", "rssContainsFullContent", "extractImageFromContent"] {
            object.removeValue(forKey: key)
        }

        let legacyPayload = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Feed.self, from: legacyPayload)
        let defaults = Feed()

        XCTAssertEqual(decoded.iconUrl, defaults.iconUrl)
        XCTAssertEqual(decoded.rssContainsFullContent, defaults.rssContainsFullContent)
        XCTAssertEqual(decoded.extractImageFromContent, defaults.extractImageFromContent)
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
