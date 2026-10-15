import CoreText
import XCTest
@testable import LakeOfFire

final class SystemManagedReaderFontTests: XCTestCase {
    func testRuntimeDeliveryIsAnExplicitPartOfFontAssetIdentity() {
        let names = ["YuKyokasho": "Helvetica", "YuKyokasho Yoko": "Helvetica-Oblique"]
        let local = SharedReaderFontAsset(systemFontNames: names,
            horizontalFamilyName: "YuKyokasho", verticalFamilyName: "YuKyokasho Yoko")
        let delivered = SharedReaderFontAsset(systemFontNames: names,
            horizontalFamilyName: "YuKyokasho", verticalFamilyName: "YuKyokasho Yoko",
            enablesRuntimeResourceDelivery: true)
        XCTAssertFalse(local.enablesRuntimeResourceDelivery)
        XCTAssertTrue(delivered.enablesRuntimeResourceDelivery)
        XCTAssertEqual(Set([local, delivered]).count, 2)
    }

    func testRuntimeDeliveryServesExactRegisteredFontBytesOnEveryReaderScheme() throws {
        let postScriptName = "Helvetica"
        let font = CTFontCreateWithName(postScriptName as CFString, 17, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, postScriptName)
        let file = try XCTUnwrap(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        let expectedBytes = try Data(contentsOf: file)
        XCTAssertFalse(expectedBytes.isEmpty)
        let asset = SharedReaderFontAsset(
            systemFontNames: ["YuKyokasho": postScriptName, "YuKyokasho Yoko": "Helvetica-Oblique"],
            horizontalFamilyName: "YuKyokasho", verticalFamilyName: "YuKyokasho Yoko",
            enablesRuntimeResourceDelivery: true)

        for base in ["internal://local", "reader-file://file", "ebook://ebook/load"] {
            let stylesheetURL = try XCTUnwrap(URL(string: "\(base)/manabi-fonts.css?family=YuKyokasho&revision=7"))
            let stylesheet = try XCTUnwrap(sharedReaderFontResponse(for: stylesheetURL, asset: asset))
            XCTAssertEqual(stylesheet.response.statusCode, 200)
            let css = String(decoding: stylesheet.data, as: UTF8.self)
            XCTAssertFalse(css.contains(file.path), "CSS must expose a logical route, not the installed path")
            let routes = try fontRoutes(in: css)
            XCTAssertEqual(routes.count, 2)
            let route = try XCTUnwrap(routes.first { $0.fragment == postScriptName })
            XCTAssertEqual(route.scheme, stylesheetURL.scheme)
            XCTAssertEqual(route.host, stylesheetURL.host)
            XCTAssertEqual(URLComponents(url: route, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "revision", value: "7")])
            let response = try XCTUnwrap(sharedReaderFontResponse(for: route, asset: asset))
            XCTAssertEqual(response.response.statusCode, 200)
            XCTAssertEqual(response.data, expectedBytes)
            XCTAssertEqual(response.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")

            let unknown = try XCTUnwrap(URL(string: "\(base)/manabi-fonts/system-unregistered"))
            let rejected = try XCTUnwrap(sharedReaderFontResponse(for: unknown, asset: asset))
            XCTAssertEqual(rejected.response.statusCode, 404)
            XCTAssertTrue(rejected.data.isEmpty)
        }
    }

    func testUnavailableVerticalFaceDoesNotBlockHorizontalOrServeFallbackBytes() throws {
        let missing = "ManabiMissingFont-\(UUID().uuidString)"
        let asset = SharedReaderFontAsset(
            systemFontNames: ["YuKyokasho": "Helvetica", "YuKyokasho Yoko": missing],
            horizontalFamilyName: "YuKyokasho", verticalFamilyName: "YuKyokasho Yoko",
            enablesRuntimeResourceDelivery: true)
        let url = URL(string: "internal://local/manabi-fonts.css?family=YuKyokasho")!
        let stylesheet = try XCTUnwrap(sharedReaderFontResponse(for: url, asset: asset))
        XCTAssertEqual(stylesheet.response.statusCode, 200)
        let routes = try fontRoutes(in: String(decoding: stylesheet.data, as: UTF8.self))
        let available = try XCTUnwrap(routes.first { $0.fragment == "Helvetica" })
        let unavailable = try XCTUnwrap(routes.first { $0.fragment == missing })
        let availableResponse = try XCTUnwrap(sharedReaderFontResponse(for: available, asset: asset))
        XCTAssertEqual(availableResponse.response.statusCode, 200)
        XCTAssertFalse(availableResponse.data.isEmpty)
        let unavailableResponse = try XCTUnwrap(sharedReaderFontResponse(for: unavailable, asset: asset))
        XCTAssertEqual(unavailableResponse.response.statusCode, 404)
        XCTAssertTrue(unavailableResponse.data.isEmpty, "CoreText fallback is not the requested font")
    }

    private func fontRoutes(in css: String) throws -> [URL] {
        let pattern = try NSRegularExpression(pattern: #"url\("([^"]+)"\)"#)
        return try pattern.matches(in: css, range: NSRange(css.startIndex..., in: css)).map { match in
            let range = try XCTUnwrap(Range(match.range(at: 1), in: css))
            return try XCTUnwrap(URL(string: String(css[range])))
        }
    }

    func testFontAssetIdentityDistinguishesSystemNamesWithoutAFileURL() {
        let asset = SharedReaderFontAsset(
            systemFontNames: ["YuKyokasho": "YuKyo-Medium", "YuKyokasho Yoko": "YuKyo_Yoko-Medium"],
            horizontalFamilyName: "YuKyokasho",
            verticalFamilyName: "YuKyokasho Yoko"
        )
        let replacement = SharedReaderFontAsset(
            systemFontNames: ["YuKyokasho": "Other-Face", "YuKyokasho Yoko": "YuKyo_Yoko-Medium"],
            horizontalFamilyName: "YuKyokasho",
            verticalFamilyName: "YuKyokasho Yoko"
        )
        let identities: Set<SharedReaderFontAsset?> = [nil, asset, asset, replacement]
        XCTAssertEqual(identities.count, 3)
        XCTAssertNil(asset.localFileURL)
        XCTAssertNil(replacement.localFileURL)
    }

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
            XCTAssertTrue(css.hasPrefix("@font-face {\n"), css)
            XCTAssertTrue(css.contains("local('YuKyo-Medium')"), css)
            XCTAssertTrue(css.contains("local('YuKyo_Yoko-Medium')"), css)
            XCTAssertTrue(css.contains("system-ui"))
            XCTAssertFalse(css.contains("src: url("))
            let fontURL = URL(string: "\(scheme)/manabi-fonts/system-font")!
            let fontResponse = try XCTUnwrap(sharedReaderFontResponse(for: fontURL, asset: asset))
            XCTAssertEqual(fontResponse.response.statusCode, 404)
            XCTAssertTrue(fontResponse.data.isEmpty)
        }
    }
}
