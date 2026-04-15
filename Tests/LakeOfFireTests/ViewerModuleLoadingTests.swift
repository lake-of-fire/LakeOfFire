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
}
