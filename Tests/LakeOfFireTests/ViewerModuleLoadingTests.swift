import XCTest

final class ViewerModuleLoadingTests: XCTestCase {
    private var foliateJSDirectory: URL {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LakeOfFireReader/Resources/foliate-js")
    }

    func testEbookViewerHTMLLoadsSourceModuleEntryPoint() throws {
        let htmlURL = foliateJSDirectory.appendingPathComponent("ebook-viewer.html")
        let html = try String(contentsOf: htmlURL, encoding: .utf8)

        XCTAssertTrue(html.contains("window.manabiViewerModuleURL = new URL('/load/viewer-assets/foliate-js/ebook-viewer.js'"), html)
        XCTAssertTrue(html.contains("window.manabiViewerModuleFetchStatus = 'module-script';"), html)
        XCTAssertTrue(html.contains("type=\"module\""), html)
        XCTAssertTrue(html.contains("src=\"/load/viewer-assets/foliate-js/ebook-viewer.js\""), html)
        XCTAssertFalse(html.contains("ebook-viewer.bundle.iife.js"), html)
        XCTAssertFalse(html.contains("ebook-viewer.bundle.js"), html)
    }

    func testLegacyBundleArtifactsAreAbsent() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: foliateJSDirectory.appendingPathComponent("ebook-viewer.bundle.iife.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foliateJSDirectory.appendingPathComponent("ebook-viewer.bundle.js").path))
    }
}
