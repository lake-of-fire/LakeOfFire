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
        XCTAssertEqual(
            sharedReaderFontInjectionMode(for: URL(string: "ebook:///book.epub")!),
            .localScheme
        )
        XCTAssertEqual(
            sharedReaderFontInjectionMode(for: URL(string: "internal://local/snippet?key=test")!),
            .localScheme
        )
        XCTAssertEqual(
            sharedReaderFontInjectionMode(for: URL(string: "reader-file://file/example.html")!),
            .localScheme
        )
        XCTAssertEqual(
            sharedReaderFontInjectionMode(for: URL(string: "https://example.com/article")!),
            .blob
        )
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
        XCTAssertTrue(css.contains(":not(rt)"), css)
        XCTAssertTrue(css.contains("rt {\n  font-family: -apple-system"), css)
        XCTAssertTrue(css.contains("internal://local/manabi-fonts/YuKyokasho.woff2"), css)
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

}
