import Foundation
import XCTest
@testable import LakeOfFireContent

final class ReaderEBookRenditionSelectionTests: XCTestCase {
    private func container(_ content: String) -> Data {
        Data(("<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'>" + content + "</container>").utf8)
    }
    private func rootfile(_ path: String) -> String {
        "<rootfile media-type='application/oebps-package+xml' full-path='\(path)'/>"
    }
    func testRetainsRenditionOrderAndLiteralJapanesePaths() throws {
        let paths = try ReaderEBookRenditionSelection.packageDocuments(in: container("<rootfiles>" + rootfile("OPS/日本語.opf") + rootfile("Other/book.opf") + "</rootfiles>"))
        XCTAssertEqual(paths, ["OPS/日本語.opf", "Other/book.opf"])
    }
    func testUnqualifiedOrForeignContainerIsNotAViewerRendition() {
        XCTAssertThrowsError(try ReaderEBookRenditionSelection.packageDocuments(in: Data(("<container><rootfiles>" + rootfile("book.opf") + "</rootfiles></container>").utf8)))
    }
    func testNestedLookalikeCannotChangeWhichDeclaredOPFIsChosen() {
        XCTAssertThrowsError(try ReaderEBookRenditionSelection.packageDocuments(in: container("<extension><rootfiles>" + rootfile("evil.opf") + "</rootfiles></extension><rootfiles>" + rootfile("book.opf") + "</rootfiles>")))
    }
    func testMissingAndUnsafePathsAreNotNormalizedIntoOtherEntries() {
        for path in ["", "../book.opf", "OPS/../book.opf", "/book.opf", " OPS/book.opf", "OPS//book.opf"] {
            XCTAssertThrowsError(try ReaderEBookRenditionSelection.packageDocuments(in: container("<rootfiles>" + rootfile(path) + "</rootfiles>")))
        }
    }
    func testLiteralPercentLookingPathsRemainLiteral() throws {
        XCTAssertEqual(try ReaderEBookRenditionSelection.packageDocuments(in: container("<rootfiles>" + rootfile("OPS/%2F.opf") + "</rootfiles>")), ["OPS/%2F.opf"])
    }
    func testInternalEntitiesAreRejectedBeforeExpansion() {
        let data = Data(("<!DOCTYPE container [<!ENTITY x 'book.opf'>]>" + String(decoding: container("<rootfiles>" + rootfile("&x;") + "</rootfiles>"), as: UTF8.self)).utf8)
        XCTAssertThrowsError(try ReaderEBookRenditionSelection.packageDocuments(in: data))
    }
    func testOversizedContainerCannotEnterUnboundedXMLParsing() {
        XCTAssertThrowsError(try ReaderEBookRenditionSelection.packageDocuments(in: Data(repeating: 32, count: 1_048_577)))
    }
    func testWrongMediaTypeIsNotAnEligibleRendition() {
        XCTAssertThrowsError(try ReaderEBookRenditionSelection.packageDocuments(in: container("<rootfiles><rootfile media-type='text/plain' full-path='book.opf'/></rootfiles>")))
    }
}
