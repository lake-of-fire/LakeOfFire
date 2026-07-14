import XCTest
@testable import LakeOfFireContent

final class ReaderPackageEntrySourceTests: XCTestCase {
    func testKnownEbookMIMETypesAreDeterministicAndCaseInsensitive() throws {
        try withPackageSource { source in
            let expectations = [
                "chapter.XHTML": ("application/xhtml+xml", "utf-8"),
                "chapter.HTML": ("text/html", "utf-8"),
                "package.OPF": ("application/oebps-package+xml", "utf-8"),
                "toc.NCX": ("application/x-dtbncx+xml", "utf-8"),
                "image.SVG": ("image/svg+xml", "utf-8"),
                "styles.CSS": ("text/css", "utf-8"),
                "module.MJS": ("text/javascript", "utf-8"),
            ]

            for (subpath, expected) in expectations {
                let metadata = try source.mimeType(subpath: subpath)
                XCTAssertEqual(metadata.mimeType, expected.0, subpath)
                XCTAssertEqual(metadata.textEncodingName, expected.1, subpath)
            }
        }
    }

    func testUnknownBinaryExtensionDoesNotClaimTextEncoding() throws {
        try withPackageSource { source in
            let metadata = try source.mimeType(subpath: "assets/payload.manabi-binary")

            XCTAssertEqual(metadata.mimeType, "application/octet-stream")
            XCTAssertNil(metadata.textEncodingName)
        }
    }

    private func withPackageSource(
        _ operation: (ReaderPackageEntrySource) throws -> Void
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-package-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try operation(ReaderPackageEntrySource(localURL: directoryURL))
    }
}
