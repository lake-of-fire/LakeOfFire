import XCTest
@testable import LakeOfFireContent

final class FeedDecodingTests: XCTestCase {
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
