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

        XCTAssertTrue(html.contains("type=\"module\""), html)
        XCTAssertTrue(html.contains("src=\"/load/viewer-assets/foliate-js/ebook-viewer.js\""), html)
        XCTAssertFalse(html.contains("ebook-viewer.bundle.iife.js"), html)
        XCTAssertFalse(html.contains("ebook-viewer.bundle.js"), html)
    }

    func testLegacyBundleArtifactsAreAbsent() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: foliateJSDirectory.appendingPathComponent("ebook-viewer.bundle.iife.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foliateJSDirectory.appendingPathComponent("ebook-viewer.bundle.js").path))
    }

    func testEbookViewerModuleEntryPointImportsExistingSourceModules() throws {
        let moduleURL = foliateJSDirectory.appendingPathComponent("ebook-viewer.js")
        let moduleSource = try String(contentsOf: moduleURL, encoding: .utf8)
        let pattern = #"(?:import\s+['"](\.[^'"]+)['"]|from\s+['"](\.[^'"]+)['"])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsSource = moduleSource as NSString
        let matches = regex.matches(
            in: moduleSource,
            range: NSRange(location: 0, length: nsSource.length)
        )

        let relativeImports = matches.compactMap { match -> String? in
            for captureIndex in 1..<match.numberOfRanges {
                let range = match.range(at: captureIndex)
                guard range.location != NSNotFound else { continue }
                return nsSource.substring(with: range)
            }
            return nil
        }

        XCTAssertFalse(relativeImports.isEmpty)
        for relativeImport in relativeImports {
            let importedURL = moduleURL.deletingLastPathComponent().appendingPathComponent(relativeImport)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: importedURL.path),
                "Missing imported module at \(importedURL.path)"
            )
        }
    }

    func testFoliateSourceGraphIncludesOverlayerModule() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foliateJSDirectory.appendingPathComponent("overlayer.js").path)
        )
    }

    func testFoliateSourceGraphUsesNativePrivateSyntax() throws {
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*(?:async\s+)?(?:\*\s*)?#[_A-Za-z]"#)
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: foliateJSDirectory,
            includingPropertiesForKeys: nil
        )
            .filter { $0.pathExtension == "js" }

        XCTAssertFalse(fileURLs.isEmpty)

        var privateSyntaxFileCount = 0
        for fileURL in fileURLs {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(location: 0, length: (source as NSString).length)
            let match = regex.firstMatch(in: source, range: range)
            if match != nil {
                privateSyntaxFileCount += 1
            }
        }
        XCTAssertGreaterThan(privateSyntaxFileCount, 0)
    }

    func testEbookViewerInitializesDiagnosticsAndImportsNavigationHelpers() throws {
        let moduleURL = foliateJSDirectory.appendingPathComponent("ebook-viewer.js")
        let moduleSource = try String(contentsOf: moduleURL, encoding: .utf8)

        XCTAssertTrue(moduleSource.contains("import './view.js'"), moduleSource)
        XCTAssertTrue(moduleSource.contains("NavigationHUD"), moduleSource)
        XCTAssertTrue(moduleSource.contains("window.onerror = function"), moduleSource)
    }

    func testEPUBSourceGraphUsesBlobURLForArchiveEntries() throws {
        let epubURL = foliateJSDirectory.appendingPathComponent("epub.js")
        let epubSource = try String(contentsOf: epubURL, encoding: .utf8)

        XCTAssertTrue(epubSource.contains("URL.createObjectURL(new Blob([data]"), epubSource)
        XCTAssertTrue(epubSource.contains("loadText("), epubSource)
    }
}
