import Foundation
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class EPubMetadataResourceLimitTests: XCTestCase {
    private let container = Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8)

    private func package(cover: String? = nil) -> Data {
        let coverItem = cover.map { "<item id='cover' href='\($0)' properties='cover-image'/>" } ?? ""
        return Data("""
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
            <metadata><dc:title> 日本語の本 </dc:title><dc:creator>著者</dc:creator><dc:date>2024-02</dc:date></metadata>
            <manifest>\(coverItem)</manifest></package>
            """.utf8)
    }

    func testMetadataPreservesNamespacesOptionalCoverAndReducedPrecisionDate() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed,
                entries: [("META-INF/container.xml", container), ("OPS/book.opf", package())])
            let metadata = try XCTUnwrap(EPubParser.parseMetadataAndCover(from: fixture.url))
            XCTAssertEqual(metadata.title, "日本語の本")
            XCTAssertEqual(metadata.author, "著者")
            XCTAssertNil(metadata.coverHref)
            let date = try XCTUnwrap(metadata.publicationDate)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: date),
                           DateComponents(year: 2024, month: 2, day: 1))
        }
    }

    func testOversizedContainerIsRejectedBeforeXMLParsing() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed,
                entries: [("META-INF/container.xml", Data(repeating: 32, count: 513)), ("OPS/book.opf", package())])
            XCTAssertThrowsError(try EPubParser.parseMetadataAndCover(from: fixture.url, limits: .init(maxEntryBytes: 512))) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError,
                               .entrySizeExceeded(path: "META-INF/container.xml", size: 513, limit: 512))
            }
        }
    }

    func testOversizedOPFIsRejectedBeforeXMLParsing() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed,
                entries: [("META-INF/container.xml", container), ("OPS/book.opf", Data(repeating: 32, count: 513))])
            XCTAssertThrowsError(try EPubParser.parseMetadataAndCover(from: fixture.url, limits: .init(maxEntryBytes: 512))) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError,
                               .entrySizeExceeded(path: "OPS/book.opf", size: 513, limit: 512))
            }
        }
    }

    func testUnrequestedMediaDoesNotInheritMetadataReadCap() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed, entries: [
                ("META-INF/container.xml", container), ("OPS/book.opf", package()),
                ("media.mp4", Data(repeating: 1, count: 2048))])
            let metadata = try EPubParser.parseMetadataAndCover(from: fixture.url, limits: .init(maxEntryBytes: 1024))
            XCTAssertEqual(metadata?.title, "日本語の本")
        }
    }

    func testMetadataCatalogEntryAndAggregateBudgetsAreEnforced() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed,
                entries: [("META-INF/container.xml", container), ("OPS/book.opf", package())])
            XCTAssertThrowsError(try EPubParser.parseMetadataAndCover(from: fixture.url, limits: .init(maxEntryCount: 1))) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entryCountExceeded(limit: 1))
            }
            XCTAssertThrowsError(try EPubParser.parseMetadataAndCover(from: fixture.url,
                limits: .init(maxAggregateUncompressedBytes: 1))) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .aggregateSizeExceeded(limit: 1))
            }
        }
    }

    func testExactMetadataReadBoundaryIsAccepted() throws {
        let opf = package()
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed,
                entries: [("META-INF/container.xml", container), ("OPS/book.opf", opf)])
            XCTAssertNotNil(try EPubParser.parseMetadataAndCover(from: fixture.url,
                limits: .init(maxEntryBytes: Int64(max(container.count, opf.count)))))
        }
    }

    func testCoverPathResolutionAndTraversalRejectionArePreserved() throws {
        for packed in [false, true] {
            for (href, expected) in [("../Images/cover.jpg", "Images/cover.jpg" as String?), ("../../outside.jpg", nil)] {
                let fixture = try PackageResourceFixture(packed: packed,
                    entries: [("META-INF/container.xml", container), ("OPS/book.opf", package(cover: href))])
                let result = try XCTUnwrap(EPubParser.parseMetadataAndCover(from: fixture.url))
                XCTAssertEqual(result.title, "日本語の本")
                XCTAssertEqual(result.coverHref, expected)
            }
        }
    }

    func testMissingMetadataStillPropagatesTheSourceError() throws {
        let fixture = try PackageResourceFixture(packed: false, entries: [])
        XCTAssertThrowsError(try EPubParser.parseMetadataAndCover(from: fixture.url)) {
            XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entryNotFound)
        }
    }

    func testMalformedContainerStillReturnsNil() throws {
        let fixture = try PackageResourceFixture(packed: false,
            entries: [("META-INF/container.xml", Data("<container><rootfiles>".utf8)), ("OPS/book.opf", package())])
        XCTAssertNil(try EPubParser.parseMetadataAndCover(from: fixture.url))
    }
}
