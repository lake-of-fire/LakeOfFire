import CryptoKit
import Foundation
import XCTest
import ZIPFoundation
@testable import LakeOfFireReader

final class ReaderImageCoverRevisionTests: XCTestCase {
    private let subpath = "OPS/Images/表紙 #%.jpg"
    private let readerFileURL = URL(string: "reader-file://file/local/Books/book.epub")!

    func testVersionedCoverRequestsUseNewCacheIdentityWhileLegacyAndRemoteURLsStayExact() throws {
        let original = try coverURL(revision: revision(for: Data("cover".utf8)))
        let admitted = try XCTUnwrap(ReaderPackagedImageRequest.imageURL(for: original))
        let originalItems = try XCTUnwrap(URLComponents(url: original, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertNotEqual(admitted.absoluteString, original.absoluteString)
        XCTAssertEqual(ReaderPackagedImageRequest.imageURL(for: admitted), admitted)
        XCTAssertEqual(
            URLComponents(url: admitted, resolvingAgainstBaseURL: false)?.queryItems,
            originalItems + [URLQueryItem(name: "cover-validation", value: "1")]
        )
        XCTAssertEqual(try ReaderPackagedImageRequest(url: admitted)?.readerFileURL, readerFileURL)

        let legacy = try coverURL(revision: nil)
        let remote = try XCTUnwrap(URL(string: "https://example.test/image.jpg?cover-revision=ordinary"))
        XCTAssertEqual(ReaderPackagedImageRequest.imageURL(for: legacy)?.absoluteString, legacy.absoluteString)
        XCTAssertEqual(ReaderPackagedImageRequest.imageURL(for: remote)?.absoluteString, remote.absoluteString)
        XCTAssertNil(try ReaderPackagedImageRequest(url: remote))
    }

    func testMalformedVersionedRequestsCannotFallBackToTheirOriginalCacheKey() throws {
        let valid = revision(for: Data("cover".utf8))
        let subpathItem = URLQueryItem(name: "subpath", value: subpath)
        let revisionItem = URLQueryItem(name: "cover-revision", value: valid)
        let cases: [[URLQueryItem]] = [
            [subpathItem, URLQueryItem(name: "cover-revision", value: nil)],
            [subpathItem, URLQueryItem(name: "cover-revision", value: "")],
            [subpathItem, URLQueryItem(name: "cover-revision", value: String(repeating: "z", count: 64))],
            [subpathItem, URLQueryItem(name: "cover-revision", value: String(valid.dropLast()))],
            [subpathItem, revisionItem, revisionItem],
            [revisionItem],
            [URLQueryItem(name: "subpath", value: ""), revisionItem],
        ]
        for query in cases {
            let url = try coverURL(query: query)
            XCTAssertNil(ReaderPackagedImageRequest.imageURL(for: url), url.absoluteString)
            XCTAssertThrowsError(try ReaderPackagedImageRequest(url: url), url.absoluteString) { error in
                XCTAssertEqual(error as? ReaderCoverRevisionError, .malformed)
            }
        }
    }

    func testSamePathDirectoryAndZIPReplacementCannotLoadUnderAnOldCoverRevision() throws {
        let first = Data("original cover bytes".utf8)
        let replacement = Data("replacement cover bytes".utf8)
        let firstRequest = try admittedRequest(coverURL(revision: revision(for: first)))
        let replacementRequest = try admittedRequest(coverURL(revision: revision(for: replacement)))
        let legacyRequest = try admittedRequest(coverURL(revision: nil))
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("unpacked.epub", isDirectory: true)
        let entry = package.appendingPathComponent(subpath)
        let archive = root.appendingPathComponent("archive.epub")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)

        func writeCover(_ bytes: Data) throws {
            try bytes.write(to: entry, options: .atomic)
            if manager.fileExists(atPath: archive.path) { try manager.removeItem(at: archive) }
            try manager.zipItem(at: package, to: archive, shouldKeepParent: false, compressionMethod: .deflate)
        }

        try writeCover(first)
        for url in [package, archive] {
            XCTAssertEqual(try firstRequest.loadData(from: url), first)
        }

        try writeCover(replacement)
        for url in [package, archive] {
            XCTAssertThrowsError(try firstRequest.loadData(from: url)) { error in
                XCTAssertEqual(error as? ReaderCoverRevisionError, .mismatch)
            }
            XCTAssertEqual(try replacementRequest.loadData(from: url), replacement)
            XCTAssertEqual(try legacyRequest.loadData(from: url), replacement)
        }

        try writeCover(first)
        for url in [package, archive] {
            XCTAssertEqual(try firstRequest.loadData(from: url), first)
        }
    }

    private func admittedRequest(_ url: URL) throws -> ReaderPackagedImageRequest {
        let admitted = try XCTUnwrap(ReaderPackagedImageRequest.imageURL(for: url))
        return try XCTUnwrap(try ReaderPackagedImageRequest(url: admitted))
    }

    private func revision(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func coverURL(revision: String?) throws -> URL {
        var query = [URLQueryItem(name: "subpath", value: subpath)]
        if let revision { query.append(URLQueryItem(name: "cover-revision", value: revision)) }
        return try coverURL(query: query)
    }

    private func coverURL(query: [URLQueryItem]) throws -> URL {
        var components = try XCTUnwrap(URLComponents(url: readerFileURL, resolvingAgainstBaseURL: false))
        components.queryItems = query
        return try XCTUnwrap(components.url)
    }
}
