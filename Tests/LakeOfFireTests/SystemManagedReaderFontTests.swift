import CoreText
import XCTest
import WebKit
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
        XCTAssertEqual(unavailableResponse.response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertTrue(unavailableResponse.data.isEmpty, "CoreText fallback is not the requested font")
    }

    @MainActor
    func testInternalFontFaceCSSRendersBothAliasesAcrossPreviewReloads() async throws {
        let horizontalName = "Helvetica"
        let verticalName = "Menlo-Regular"
        let horizontalFamily = "Reader Horizontal Test"
        let verticalFamily = "Reader Vertical Test"
        let asset = SharedReaderFontAsset(
            systemFontNames: [horizontalFamily: horizontalName, verticalFamily: verticalName],
            horizontalFamilyName: horizontalFamily, verticalFamilyName: verticalFamily,
            enablesRuntimeResourceDelivery: true
        )
        let handler = InternalURLSchemeHandler()
        handler.sharedReaderFontAsset = asset
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "internal")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 200), configuration: configuration)
        defer { webView.stopLoading() }
        let origin = try XCTUnwrap(URL(string: "internal://local"))

        for revision in ["1", "2"] {
            var source = URLComponents(url: origin, resolvingAgainstBaseURL: false)
            source?.path = "/manabi-fonts.css"
            source?.queryItems = [URLQueryItem(name: "revision", value: revision)]
            let sourceURL = try XCTUnwrap(source?.url)
            let css = try XCTUnwrap(sharedReaderFontFaceCSS(for: sourceURL, asset: asset))
            let routes = try fontRoutes(in: css)
            let horizontalRoute = try XCTUnwrap(routes.first { $0.fragment == horizontalName })
            let verticalRoute = try XCTUnwrap(routes.first { $0.fragment == verticalName })
            for route in [horizontalRoute, verticalRoute] {
                XCTAssertEqual(URLComponents(url: route, resolvingAgainstBaseURL: false)?.queryItems,
                               [URLQueryItem(name: "revision", value: revision)])
            }

            let navigation = SystemManagedFontPreviewNavigation()
            webView.navigationDelegate = navigation
            webView.loadHTMLString("""
                <!doctype html>
                <meta charset="utf-8">
                <style>\(css)</style>
                <canvas width="560" height="90"></canvas>
                """, baseURL: origin)
            await fulfillment(of: [navigation.completed], timeout: 5)
            if let error = navigation.error { throw error }

            let result = try await webView.callAsyncJavaScript("""
                const sample = "iii WWW agile fox 123";
                const canvas = document.querySelector("canvas");
                const context = canvas.getContext("2d");
                const font = family => '400 42px "' + family + '", serif';
                const raster = family => {
                    context.clearRect(0, 0, canvas.width, canvas.height);
                    context.font = font(family);
                    context.fillText(sample, 8, 56);
                    return canvas.toDataURL();
                };
                const check = async (alias, url, reference) => {
                    const faces = await document.fonts.load(font(alias), sample);
                    const aliasPixels = raster(alias);
                    // The reference has only the routed URL, so local() cannot hide
                    // a transport failure or an unreadable font file.
                    const face = await new FontFace(reference, 'url(' + JSON.stringify(url) + ')').load();
                    document.fonts.add(face);
                    return {
                        loaded: faces.length === 1 && faces[0].status === "loaded",
                        usesRoutedGlyphs: aliasPixels === raster(reference),
                        differsFromFallback: aliasPixels !== raster("Missing Reader Test Face"),
                        pixels: aliasPixels
                    };
                };
                const horizontal = await check(horizontalFamily, horizontalURL, "Horizontal URL Reference");
                const vertical = await check(verticalFamily, verticalURL, "Vertical URL Reference");
                return {
                    horizontalLoaded: horizontal.loaded,
                    horizontalUsesRoutedGlyphs: horizontal.usesRoutedGlyphs,
                    horizontalDiffersFromFallback: horizontal.differsFromFallback,
                    verticalLoaded: vertical.loaded,
                    verticalUsesRoutedGlyphs: vertical.usesRoutedGlyphs,
                    verticalDiffersFromFallback: vertical.differsFromFallback,
                    aliasesPaintDifferentGlyphs: horizontal.pixels !== vertical.pixels
                };
                """, arguments: [
                    "horizontalFamily": asset.cssFontFaceFamilyName(for: horizontalFamily),
                    "verticalFamily": asset.cssFontFaceFamilyName(for: verticalFamily),
                    "horizontalURL": horizontalRoute.absoluteString,
                    "verticalURL": verticalRoute.absoluteString,
                ], in: nil, contentWorld: .page)
            let checks = try XCTUnwrap(result as? [String: Bool])
            for key in [
                "horizontalLoaded", "horizontalUsesRoutedGlyphs", "horizontalDiffersFromFallback",
                "verticalLoaded", "verticalUsesRoutedGlyphs", "verticalDiffersFromFallback",
                "aliasesPaintDifferentGlyphs",
            ] {
                XCTAssertEqual(checks[key], true, "\(key) at revision \(revision)")
            }
        }
    }

    @MainActor
    func testFailedRuntimeFaceDoesNotHideInstalledFamily() async throws {
        let installedFamily = "Menlo"
        let missingPostScriptName = "ManabiMissingFont-\(UUID().uuidString)"
        let asset = SharedReaderFontAsset(
            systemFontNames: [installedFamily: missingPostScriptName],
            horizontalFamilyName: installedFamily, verticalFamilyName: installedFamily,
            enablesRuntimeResourceDelivery: true
        )
        let handler = InternalURLSchemeHandler()
        handler.sharedReaderFontAsset = asset
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "internal")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 200), configuration: configuration)
        defer { webView.stopLoading() }
        let origin = try XCTUnwrap(URL(string: "internal://local/"))
        let css = try XCTUnwrap(sharedReaderFontFaceCSS(for: origin, asset: asset))
        let navigation = SystemManagedFontPreviewNavigation()
        webView.navigationDelegate = navigation
        webView.loadHTMLString("<canvas width=\"560\" height=\"90\"></canvas>", baseURL: origin)
        await fulfillment(of: [navigation.completed], timeout: 5)
        if let error = navigation.error { throw error }

        let result = try await webView.callAsyncJavaScript("""
            const sample = "iii WWW agile fox 123";
            const canvas = document.querySelector("canvas");
            const context = canvas.getContext("2d");
            const raster = cssFamilies => {
                context.clearRect(0, 0, canvas.width, canvas.height);
                context.font = "400 42px " + cssFamilies;
                context.fillText(sample, 8, 56);
                return canvas.toDataURL();
            };
            const nativeStack = JSON.stringify(installedFamily) + ", serif";
            const nativePixels = raster(nativeStack);
            const genericPixels = raster("serif");

            const style = document.createElement("style");
            style.textContent = css;
            document.head.append(style);
            try { await document.fonts.load("400 42px " + JSON.stringify(alias), sample); } catch (_) {}
            const routeFailed = Array.from(document.fonts).some(face => face.family === alias && face.status === "error");
            return {
                nativeDiffersFromGeneric: nativePixels !== genericPixels,
                routeFailed,
                newStackUsesNativeFace: raster(familyList + ", serif") === nativePixels,
            };
            """, arguments: [
                "installedFamily": installedFamily,
                "css": css,
                "alias": asset.cssFontFaceFamilyName(for: installedFamily),
                "familyList": asset.cssFontFamilyList(for: installedFamily),
            ], in: nil, contentWorld: .page)
        let checks = try XCTUnwrap(result as? [String: Bool])
        for key in ["nativeDiffersFromGeneric", "routeFailed", "newStackUsesNativeFace"] {
            XCTAssertEqual(checks[key], true, key)
        }
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

@MainActor
private final class SystemManagedFontPreviewNavigation: NSObject, WKNavigationDelegate {
    let completed = XCTestExpectation(description: "Font preview HTML loaded")
    private(set) var error: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completed.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        completed.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        completed.fulfill()
    }
}
