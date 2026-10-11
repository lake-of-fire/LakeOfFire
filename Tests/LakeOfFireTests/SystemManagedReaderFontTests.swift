import XCTest
@testable import LakeOfFire

final class SystemManagedReaderFontTests: XCTestCase {
    func testSystemFontStylesheetUsesDistinctLocalFacesAndNoFontPayloadRoute() throws {
        let asset = SharedReaderFontAsset(
            systemFontNames: ["YuKyokasho": "YuKyo-Medium", "YuKyokasho Yoko": "YuKyo_Yoko-Medium"],
            horizontalFamilyName: "YuKyokasho",
            verticalFamilyName: "YuKyokasho Yoko"
        )
        XCTAssertNil(asset.localFileURL)
        for scheme in ["internal://local", "reader-file://file", "ebook://ebook/load"] {
            let cssURL = URL(string: "\(scheme)/manabi-fonts.css?family=YuKyokasho")!
            let response = try XCTUnwrap(sharedReaderFontResponse(for: cssURL, asset: asset))
            XCTAssertEqual(response.response.statusCode, 200)
            let css = String(decoding: response.data, as: UTF8.self)
            XCTAssertTrue(css.contains("local('YuKyo-Medium')"))
            XCTAssertTrue(css.contains("local('YuKyo_Yoko-Medium')"))
            XCTAssertTrue(css.contains("system-ui"))
            XCTAssertFalse(css.contains("src: url("))
            let fontURL = URL(string: "\(scheme)/manabi-fonts/system-font")!
            let fontResponse = try XCTUnwrap(sharedReaderFontResponse(for: fontURL, asset: asset))
            XCTAssertEqual(fontResponse.response.statusCode, 404)
            XCTAssertTrue(fontResponse.data.isEmpty)
        }
    }
}
