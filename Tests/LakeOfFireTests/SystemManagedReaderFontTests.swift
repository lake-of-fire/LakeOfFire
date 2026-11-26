import CoreText
import WebKit
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

    func testRuntimePreviewCanSupplyAnExplicitFaceAlias() {
        let alias = "Manabi Reader YuKyokasho"
        let asset = SharedReaderFontAsset(
            systemFontNames: [alias: "YuKyo-Medium"],
            horizontalFamilyName: alias, verticalFamilyName: alias,
            enablesRuntimeResourceDelivery: true
        )
        XCTAssertEqual(asset.cssFontFaceFamilyName(for: alias), alias)
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
        let url = URL(string: "internal://local/manabi-fonts.css?family=YuKyokasho&revision=7")!
        let stylesheet = try XCTUnwrap(sharedReaderFontResponse(for: url, asset: asset))
        XCTAssertEqual(stylesheet.response.statusCode, 200)
        let routes = try fontRoutes(in: String(decoding: stylesheet.data, as: UTF8.self))
        XCTAssertEqual(routes.count, 1, "An unavailable vertical face must not block horizontal delivery")
        let available = try XCTUnwrap(routes.first { $0.fragment == "Helvetica" })
        XCTAssertNil(routes.first { $0.fragment == missing })
        let availableResponse = try XCTUnwrap(sharedReaderFontResponse(for: available, asset: asset))
        XCTAssertEqual(availableResponse.response.statusCode, 200)
        XCTAssertFalse(availableResponse.data.isEmpty)

        let verticalStylesheetURL = URL(
            string: "internal://local/manabi-fonts.css?family=YuKyokasho%20Yoko&revision=7"
        )!
        let verticalStylesheet = try XCTUnwrap(
            sharedReaderFontResponse(for: verticalStylesheetURL, asset: asset)
        )
        XCTAssertEqual(verticalStylesheet.response.statusCode, 404)
        let encodedMissing = Data(missing.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let unavailable = URL(
            string: "internal://local/manabi-fonts/system-\(encodedMissing)?revision=7#\(missing)"
        )!
        let unavailableResponse = try XCTUnwrap(sharedReaderFontResponse(for: unavailable, asset: asset))
        XCTAssertEqual(unavailableResponse.response.statusCode, 404)
        XCTAssertTrue(unavailableResponse.data.isEmpty, "CoreText fallback is not the requested font")

        let embedded = sharedReaderFontDocumentResources(asset: asset, sourceURL: url)
        XCTAssertEqual(embedded.count, 1)
        let face = try XCTUnwrap(embedded.first)
        XCTAssertEqual(Data(base64Encoded: face.base64), availableResponse.data)
        XCTAssertEqual(face.sourceURLs, [available.absoluteString])
    }

    @MainActor
    func testRoutedStylesheetPreservesNativeFallbackAndKeepsWorkingDirectionFirst() async throws {
        let horizontal = "Menlo"
        let vertical = "Reader Vertical Test"
        let asset = SharedReaderFontAsset(
            systemFontNames: [horizontal: "ManabiMissingFont-\(UUID().uuidString)", vertical: "Helvetica"],
            horizontalFamilyName: horizontal, verticalFamilyName: vertical,
            enablesRuntimeResourceDelivery: true
        )
        let origin = try XCTUnwrap(URL(string: "internal://local/"))
        let stylesheet = try XCTUnwrap(sharedReaderFontStylesheetURL(for: origin, familyName: horizontal))
        let response = try XCTUnwrap(sharedReaderFontResponse(for: stylesheet, asset: asset))
        let routes = try fontRoutes(in: String(decoding: response.data, as: UTF8.self))
        let verticalURL = try XCTUnwrap(routes.first { $0.fragment == "Helvetica" })
        let handler = InternalURLSchemeHandler()
        handler.sharedReaderFontAsset = asset
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "internal")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 200), configuration: configuration)
        defer { webView.stopLoading() }

        let navigation = SystemManagedFontPreviewNavigation()
        webView.navigationDelegate = navigation
        webView.loadHTMLString("""
            <!doctype html>
            <html>
              <head><link rel="stylesheet" href="\(stylesheet.absoluteString)"></head>
              <body>
                <span id="sample">iii WWW agile fox 123</span>
                <canvas width="560" height="90"></canvas>
              </body>
            </html>
            """, baseURL: origin)
        await fulfillment(of: [navigation.completed], timeout: 5)
        if let error = navigation.error { throw error }

        let result = try await webView.callAsyncJavaScript(#"""
            const text = document.getElementById('sample')
            const canvas = document.querySelector('canvas')
            const context = canvas.getContext('2d')
            const raster = families => {
                context.clearRect(0, 0, canvas.width, canvas.height)
                context.font = '400 42px ' + families
                context.fillText(text.textContent, 8, 56)
                return canvas.toDataURL()
            }
            const names = familyList => familyList.split(',').map(family => family.trim().replace(/^['"]|['"]$/g, ''))
            const select = alias => '400 42px ' + JSON.stringify(alias)
            const horizontalStack = getComputedStyle(text).fontFamily
            const nativePixels = raster(JSON.stringify(nativeFamily) + ', system-ui')
            const genericPixels = raster('system-ui')
            try { await document.fonts.load(select(horizontalAlias), text.textContent) } catch (_) {}
            const horizontalFailed = Array.from(document.fonts).some(face =>
                names(face.family)[0] === horizontalAlias && face.status === 'error')
            const horizontalPixels = raster(horizontalStack)

            document.body.classList.add('reader-vertical-writing')
            const verticalStack = getComputedStyle(text).fontFamily
            const verticalFaces = await document.fonts.load(select(verticalAlias), text.textContent)
            const verticalPixels = raster(verticalStack)
            const verticalReference = await new FontFace('Vertical URL Reference', 'url(' + JSON.stringify(verticalURL) + ')').load()
            document.fonts.add(verticalReference)
            const referencePixels = raster('"Vertical URL Reference", system-ui')
            document.body.classList.remove('reader-vertical-writing')

            // The live settings writer may explicitly select a different
            // fallback even while the previous route sheet is still present.
            document.documentElement.style.setProperty('--mnb-content-font', 'system-ui')
            document.body.style.setProperty('--mnb-content-font', 'system-ui')
            const otherStack = getComputedStyle(text).fontFamily

            return {
                nativeDiffersFromGeneric: nativePixels !== genericPixels,
                horizontalRouteFailed: horizontalFailed,
                horizontalAliasIsFirst: names(horizontalStack)[0] === horizontalAlias,
                horizontalNativeIsSecond: names(horizontalStack)[1] === nativeFamily,
                failedRouteUsesNativeFace: horizontalPixels === nativePixels,
                verticalAliasIsFirst: names(verticalStack)[0] === verticalAlias,
                verticalRouteLoaded: verticalFaces.some(face => face.status === 'loaded'),
                verticalUsesRoutedGlyphs: verticalPixels === referencePixels && verticalPixels !== genericPixels,
                explicitSettingsFallbackWins: names(otherStack)[0] === 'system-ui',
            }
            """#, arguments: [
                "nativeFamily": horizontal,
                "horizontalAlias": asset.cssFontFaceFamilyName(for: horizontal),
                "verticalAlias": asset.cssFontFaceFamilyName(for: vertical),
                "verticalURL": verticalURL.absoluteString,
            ], in: nil, contentWorld: .page)
        let checks = try XCTUnwrap(result as? [String: Bool])
        for key in [
            "nativeDiffersFromGeneric", "horizontalRouteFailed", "horizontalAliasIsFirst", "horizontalNativeIsSecond",
            "failedRouteUsesNativeFace", "verticalAliasIsFirst", "verticalRouteLoaded", "verticalUsesRoutedGlyphs",
            "explicitSettingsFallbackWins",
        ] {
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
