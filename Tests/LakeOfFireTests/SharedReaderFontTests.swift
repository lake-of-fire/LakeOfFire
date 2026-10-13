import XCTest
@testable import LakeOfFireFiles

final class SharedReaderFontTests: XCTestCase {
    private func makeFontAsset() throws -> SharedReaderFontAsset {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("woff2")
        try Data("font".utf8).write(to: fileURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return SharedReaderFontAsset(
            localFileURL: fileURL,
            mimeType: "font/woff2",
            format: "woff2",
            supportedFamilyNames: ["YuKyokasho", "YuKyokasho Yoko"]
        )
    }

    func testSharedReaderFontStylesheetURLsUseExpectedSchemeRoots() {
        XCTAssertEqual(
            sharedReaderFontStylesheetURL(
                for: URL(string: "ebook:///book.epub")!,
                familyName: "YuKyokasho"
            )?.absoluteString,
            "ebook://ebook/load/manabi-fonts.css?family=YuKyokasho"
        )
        XCTAssertEqual(
            sharedReaderFontStylesheetURL(
                for: URL(string: "internal://local/snippet?key=test-snippet")!,
                familyName: "YuKyokasho"
            )?.absoluteString,
            "internal://local/manabi-fonts.css?family=YuKyokasho"
        )
        XCTAssertEqual(
            sharedReaderFontStylesheetURL(
                for: URL(string: "reader-file://file/example.html")!,
                familyName: "YuKyokasho"
            )?.absoluteString,
            "reader-file://file/manabi-fonts.css?family=YuKyokasho"
        )
        XCTAssertNil(
            sharedReaderFontStylesheetURL(
                for: URL(string: "https://example.com/article")!,
                familyName: "YuKyokasho"
            )
        )
    }

    func testSharedReaderFontUsesLocalSchemeOnlyForSupportedReaderSchemes() {
        XCTAssertTrue(sharedReaderFontUsesLocalScheme(for: URL(string: "ebook:///book.epub")!))
        XCTAssertTrue(sharedReaderFontUsesLocalScheme(for: URL(string: "internal://local/snippet?key=test")!))
        XCTAssertTrue(sharedReaderFontUsesLocalScheme(for: URL(string: "reader-file://file/example.html")!))
        XCTAssertFalse(sharedReaderFontUsesLocalScheme(for: URL(string: "https://example.com/article")!))
    }

    func testSharedReaderFontInjectionModeUsesLocalSchemesAndBlobFallbackElsewhere() {
        XCTAssertEqual(sharedReaderFontInjectionMode(for: URL(string: "ebook:///book.epub")!), .localScheme)
        XCTAssertEqual(sharedReaderFontInjectionMode(for: URL(string: "internal://local/snippet?key=test")!), .localScheme)
        XCTAssertEqual(sharedReaderFontInjectionMode(for: URL(string: "reader-file://file/example.html")!), .localScheme)
        XCTAssertEqual(sharedReaderFontInjectionMode(for: URL(string: "https://example.com/article")!), .blob)
    }

    func testSharedReaderFontStylesheetResponseUsesSameSchemeFontURL() throws {
        let asset = try makeFontAsset()
        let response = try XCTUnwrap(
            sharedReaderFontResponse(
                for: URL(string: "internal://local/manabi-fonts.css?family=YuKyokasho")!,
                asset: asset
            )
        )

        XCTAssertEqual(response.response.statusCode, 200)
        XCTAssertEqual(response.response.value(forHTTPHeaderField: "Content-Type"), "text/css")
        let css = try XCTUnwrap(String(data: response.data, encoding: .utf8))
        XCTAssertTrue(css.contains("font-family: 'YuKyokasho'"), css)
        XCTAssertTrue(css.contains("internal://local/manabi-fonts/YuKyokasho.woff2"), css)
        XCTAssertTrue(css.contains("font-display: swap;"), css)
        XCTAssertTrue(css.contains(":not(rt)"), css)
        XCTAssertTrue(css.contains("rt {\n  font-family: -apple-system"), css)
    }

    func testSharedReaderFontFontResponseIncludesCORSHeaders() throws {
        let asset = try makeFontAsset()
        let response = try XCTUnwrap(
            sharedReaderFontResponse(
                for: URL(string: "reader-file://file/manabi-fonts/YuKyokasho.woff2")!,
                asset: asset
            )
        )

        XCTAssertEqual(response.response.statusCode, 200)
        XCTAssertEqual(response.response.value(forHTTPHeaderField: "Content-Type"), "font/woff2")
        XCTAssertEqual(response.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
        XCTAssertEqual(response.data, Data("font".utf8))
    }

    func testSharedReaderFontRejectsUnknownFamiliesAndMissingAssets() throws {
        let asset = try makeFontAsset()
        let unknownFamilyResponse = try XCTUnwrap(
            sharedReaderFontResponse(
                for: URL(string: "ebook://ebook/load/manabi-fonts.css?family=NotAReaderFont")!,
                asset: asset
            )
        )
        XCTAssertEqual(unknownFamilyResponse.response.statusCode, 404)

        let missingAssetResponse = try XCTUnwrap(
            sharedReaderFontResponse(
                for: URL(string: "internal://local/manabi-fonts/YuKyokasho.woff2")!,
                asset: nil
            )
        )
        XCTAssertEqual(missingAssetResponse.response.statusCode, 404)
    }


    private func makeSystemAsset(verticalName: String = "Vertical-PS") -> SharedReaderFontAsset {
        SharedReaderFontAsset(
            systemFontNames: ["Horizontal": "Horizontal-PS", "Vertical": verticalName],
            horizontalFamilyName: "Horizontal",
            verticalFamilyName: "Vertical"
        )
    }

    func testSystemFontStylesheetsServeBothDirectionsWithoutFontURLs() throws {
        let asset = makeSystemAsset()
        XCTAssertNil(asset.localFileURL)
        for root in ["ebook://ebook/load", "internal://local", "reader-file://file"] {
            for family in ["Horizontal", "Vertical"] {
                let served = try XCTUnwrap(sharedReaderFontResponse(
                    for: URL(string: "\(root)/manabi-fonts.css?family=\(family)")!, asset: asset
                ))
                XCTAssertEqual(served.response.statusCode, 200)
                XCTAssertEqual(served.response.value(forHTTPHeaderField: "Content-Type"), "text/css")
                let css = String(decoding: served.data, as: UTF8.self)
                XCTAssertTrue(css.contains("local('Horizontal-PS')"))
                XCTAssertTrue(css.contains("local('Vertical-PS')"))
                XCTAssertTrue(css.contains("--mnb-content-font: 'Horizontal', system-ui"))
                XCTAssertTrue(css.contains("--mnb-content-vertical-font: 'Vertical', system-ui"))
                XCTAssertTrue(css.contains("body.reader-vertical-writing"))
                XCTAssertFalse(css.contains("url("))
                XCTAssertFalse(css.contains("base64"))
            }
            let bytes = try XCTUnwrap(sharedReaderFontResponse(
                for: URL(string: "\(root)/manabi-fonts/system-font")!, asset: asset
            ))
            XCTAssertEqual(bytes.response.statusCode, 404)
            XCTAssertTrue(bytes.data.isEmpty)
        }
    }

    func testSystemFontRejectsUnknownOrIncompleteMapping() throws {
        let incomplete = SharedReaderFontAsset(
            systemFontNames: ["Horizontal": "Horizontal-PS"],
            horizontalFamilyName: "Horizontal", verticalFamilyName: "Vertical"
        )
        for (asset, family) in [(makeSystemAsset(), "Unknown"), (incomplete, "Horizontal")] {
            let served = try XCTUnwrap(sharedReaderFontResponse(
                for: URL(string: "internal://local/manabi-fonts.css?family=\(family)")!, asset: asset
            ))
            XCTAssertEqual(served.response.statusCode, 404)
            XCTAssertTrue(served.data.isEmpty)
        }
    }

    func testSystemFontIdentityIncludesMappingAndDirections() {
        let initial = makeSystemAsset()
        XCTAssertEqual(initial, makeSystemAsset())
        XCTAssertNotEqual(initial, makeSystemAsset(verticalName: "Replacement-PS"))
        let reversed = SharedReaderFontAsset(
            systemFontNames: initial.systemFontNames,
            horizontalFamilyName: "Vertical", verticalFamilyName: "Horizontal"
        )
        XCTAssertNotEqual(initial, reversed)
        XCTAssertEqual(Set([initial, makeSystemAsset(), reversed]).count, 2)
    }

    func testSystemFontCSSQuotesPostScriptNames() throws {
        let asset = makeSystemAsset(verticalName: "Vertical'Face\\Name\n")
        let served = try XCTUnwrap(sharedReaderFontResponse(
            for: URL(string: "internal://local/manabi-fonts.css?family=Vertical")!, asset: asset
        ))
        XCTAssertEqual(served.response.statusCode, 200)
        XCTAssertTrue(String(decoding: served.data, as: UTF8.self)
            .contains("local('Vertical\\'Face\\\\Name\\a ')"))
    }
}
