import Foundation
import XCTest
@testable import LakeOfFireReader

final class EPubMetadataDocumentTests: XCTestCase {
    private let dc = "http://purl.org/dc/elements/1.1/"
    private let opfNS = "http://www.idpf.org/2007/opf"
    private let ocfNS = "urn:oasis:names:tc:opendocument:xmlns:container"

    private func opf(_ metadata: String, manifest: String = "", version: String = "3.0") -> Data {
        Data("""
        <package xmlns="\(opfNS)" version="\(version)" xmlns:dc="\(dc)">
        <metadata>\(metadata)</metadata><manifest>\(manifest)</manifest></package>
        """.utf8)
    }
    private func cover(_ href: String = "cover.jpg", properties: String = "cover-image") -> String {
        "<item id=\"cover\" href=\"\(href)\" media-type=\"image/jpeg\" properties=\"\(properties)\"/>"
    }

    func testCoverlessBookKeepsItsMetadata() throws {
        let metadata = try XCTUnwrap(EPubMetadataDocument.metadata(opf(
            "<dc:title>猫の本</dc:title><dc:creator>夏目</dc:creator><dc:date>2020-01-02</dc:date>"
        )))
        XCTAssertEqual(metadata.title, "猫の本")
        XCTAssertEqual(metadata.author, "夏目")
        XCTAssertNil(metadata.coverHref)
        XCTAssertNotNil(metadata.publicationDate)
    }

    func testNamespacedContainerUsesExpandedNames() throws {
        let data = Data("""
        <ocf:container xmlns:ocf="\(ocfNS)"><ocf:rootfiles>
        <ocf:rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/>
        </ocf:rootfiles></ocf:container>
        """.utf8)
        XCTAssertEqual(try EPubMetadataDocument.containerPath(data), "OPS/book.opf")
    }

    func testNamespaceLessContainerCompatibility() throws {
        XCTAssertEqual(try EPubMetadataDocument.containerPath(Data(
            "<container><rootfiles><rootfile full-path=\"book.opf\"/></rootfiles></container>".utf8
        )), "book.opf")
    }

    func testPrefixedOPFAndAlternateDublinCorePrefix() throws {
        let data = Data("""
        <o:package xmlns:o="\(opfNS)" xmlns:d="\(dc)" version="3.0">
        <o:metadata><d:title>本文</d:title><d:creator>作者</d:creator></o:metadata>
        <o:manifest><o:item id="c" href="a.jpg" properties="cover-image"/></o:manifest>
        </o:package>
        """.utf8)
        let value = try XCTUnwrap(EPubMetadataDocument.metadata(data))
        XCTAssertEqual(value.title, "本文")
        XCTAssertEqual(value.author, "作者")
        XCTAssertEqual(value.coverHref, "a.jpg")
    }

    func testNamespaceLessOPFCompatibility() throws {
        let data = Data("<package xmlns:dc=\"\(dc)\"><metadata><dc:title>Legacy</dc:title></metadata></package>".utf8)
        XCTAssertEqual(try EPubMetadataDocument.metadata(data)?.title, "Legacy")
    }

    func testWrongDublinCoreNamespaceCannotSupplyTitle() throws {
        let data = opf("<bad:title xmlns:bad=\"urn:not-dc\">Wrong</bad:title>")
        XCTAssertNil(try EPubMetadataDocument.metadata(data))
    }

    func testForeignMetadataContainerCannotOverrideTitle() throws {
        let data = opf("""
        <dc:title>Real</dc:title>
        <fake:metadata xmlns:fake="urn:foreign"><dc:title>Injected</dc:title></fake:metadata>
        """ )
        XCTAssertEqual(try EPubMetadataDocument.metadata(data)?.title, "Real")
    }

    func testForeignRootCannotSupplyContainerOrPackage() throws {
        XCTAssertNil(try EPubMetadataDocument.containerPath(Data(
            "<container xmlns=\"urn:wrong\"><rootfiles><rootfile full-path=\"a.opf\"/></rootfiles></container>".utf8
        )))
        let data = Data("<package xmlns=\"urn:wrong\" xmlns:dc=\"\(dc)\"><metadata><dc:title>Wrong</dc:title></metadata></package>".utf8)
        XCTAssertNil(try EPubMetadataDocument.metadata(data))
    }

    func testContainerSkipsNonOPFRootfile() throws {
        let xml = """
        <container><rootfiles><rootfile full-path="other.pdf" media-type="application/pdf"/>
        <rootfile full-path="book.opf" media-type="application/oebps-package+xml"/>
        <rootfile full-path="second.opf"/></rootfiles></container>
        """
        XCTAssertEqual(try EPubMetadataDocument.containerPath(Data(xml.utf8)), "book.opf")
    }

    func testTruncatedContainerCannotPublishEarlierRootfile() throws {
        let xml = "<container><rootfiles><rootfile full-path=\"a.opf\"/></rootfiles>"
        XCTAssertNil(try EPubMetadataDocument.containerPath(Data(xml.utf8)))
    }

    func testMalformedContainerTailCannotPublishEarlierRootfile() throws {
        let xml = "<container><rootfiles><rootfile full-path=\"a.opf\"/></rootfiles></container><broken>"
        XCTAssertNil(try EPubMetadataDocument.containerPath(Data(xml.utf8)))
    }

    func testTruncatedOPFCannotPublishEarlierTitleAndCover() throws {
        var data = opf("<dc:title>Partial</dc:title>", manifest: cover())
        data.removeLast("</package>".utf8.count)
        XCTAssertNil(try EPubMetadataDocument.metadata(data))
    }

    func testMalformedOPFTailCannotPublishEarlierTitleAndCover() throws {
        var data = opf("<dc:title>Partial</dc:title>", manifest: cover())
        data.append(Data("<broken>".utf8))
        XCTAssertNil(try EPubMetadataDocument.metadata(data))
    }

    func testCDATAAndEscapedEntitiesPreserveJapaneseText() throws {
        let value = try XCTUnwrap(EPubMetadataDocument.metadata(opf(
            "<dc:title>前<![CDATA[猫 & 犬]]>後</dc:title><dc:creator>A &amp; B</dc:creator>"
        )))
        XCTAssertEqual(value.title, "前猫 & 犬後")
        XCTAssertEqual(value.author, "A & B")
    }

    func testFirstNonemptyTitleAndAuthorRemainPrimary() throws {
        let value = try XCTUnwrap(EPubMetadataDocument.metadata(opf("""
        <dc:title> </dc:title><dc:title>Primary</dc:title><dc:title>Alternative</dc:title>
        <dc:creator>First</dc:creator><dc:creator>Second</dc:creator>
        """)))
        XCTAssertEqual(value.title, "Primary")
        XCTAssertEqual(value.author, "First")
    }

    func testExplicitMainTitleWinsOverEarlierSubtitle() throws {
        let value = try XCTUnwrap(EPubMetadataDocument.metadata(opf("""
        <dc:title id="sub">Subtitle</dc:title><dc:title id="main">Book title</dc:title>
        <meta refines="#main" property="title-type">main</meta>
        <meta refines="#sub" property="title-type">subtitle</meta>
        """)))
        XCTAssertEqual(value.title, "Book title")
    }

    func testForeignTitleRefinementCannotSelectAlternative() throws {
        let value = try XCTUnwrap(EPubMetadataDocument.metadata(opf("""
        <dc:title id="one">Primary</dc:title><dc:title id="two">Alternative</dc:title>
        <x:meta xmlns:x="urn:foreign" refines="#two" property="title-type">main</x:meta>
        """)))
        XCTAssertEqual(value.title, "Primary")
    }

    func testEmptyTitleDoesNotCountAsSuccessfulMetadata() throws {
        XCTAssertNil(try EPubMetadataDocument.metadata(opf("<dc:title> \n\t </dc:title>", manifest: cover())))
    }

    func testCoverPropertyIsATokenNotASubstring() throws {
        let bad = try XCTUnwrap(EPubMetadataDocument.metadata(opf(
            "<dc:title>Book</dc:title>", manifest: cover(properties: "not-cover-image")
        )))
        XCTAssertNil(bad.coverHref)
        let good = try XCTUnwrap(EPubMetadataDocument.metadata(opf(
            "<dc:title>Book</dc:title>", manifest: cover(properties: "svg&#x9;cover-image scripted")
        )))
        XCTAssertEqual(good.coverHref, "cover.jpg")
    }

    func testEPUB2CoverUsesManifestIdentity() throws {
        let value = try XCTUnwrap(EPubMetadataDocument.metadata(opf(
            "<dc:title>Old</dc:title><meta name=\"cover\" content=\"cover\"/>",
            manifest: cover(properties: ""), version: "2.0"
        )))
        XCTAssertEqual(value.coverHref, "cover.jpg")
    }

    func testMissingLegacyCoverItemIsOptional() throws {
        let value = try XCTUnwrap(EPubMetadataDocument.metadata(opf(
            "<dc:title>Old</dc:title><meta name=\"cover\" content=\"missing\"/>", version: "2.0"
        )))
        XCTAssertNil(value.coverHref)
    }

    func testDateOnlyAndFractionalTimestamp() throws {
        for date in ["2020-01-02", "2020-01-02T03:04:05Z", "2020-01-02T03:04:05.125Z"] {
            XCTAssertNotNil(try EPubMetadataDocument.metadata(opf(
                "<dc:title>Book</dc:title><dc:date>\(date)</dc:date>"
            ))?.publicationDate, date)
        }
    }

    func testInvalidDateDoesNotEraseOtherMetadata() throws {
        let value = try XCTUnwrap(EPubMetadataDocument.metadata(opf(
            "<dc:title>Book</dc:title><dc:date>not a date</dc:date>"
        )))
        XCTAssertNil(value.publicationDate)
        XCTAssertEqual(value.title, "Book")
    }

    func testCoverResolutionDecodesOnceAndPreservesLiteralPercentAndDelimiters() {
        XCTAssertEqual(EPubMetadataDocument.coverPath(baseDirectory: "OPS", href: "images/%E8%A1%A8%E7%B4%99%20a%23b%25.jpg?size=2#cover"), "OPS/images/表紙 a#b%.jpg")
        XCTAssertEqual(EPubMetadataDocument.coverPath(baseDirectory: "OPS", href: "%252e%252e.jpg"), "OPS/%2e%2e.jpg")
        XCTAssertEqual(EPubMetadataDocument.coverPath(baseDirectory: "OPS/Text", href: "../images/cover.jpg"), "OPS/images/cover.jpg")
    }

    func testUnsafeCoversCannotEscapePackage() {
        for href in ["../../../x", "%2e%2e/%2e%2e/x", "/x", "//host/x", "https://host/x", "file:///x", "a%2fb", "a%5Cb", "a%00b", "a%0ab", "a\\b", "a//b", "#only", "a%ZZ"] {
            XCTAssertNil(EPubMetadataDocument.coverPath(baseDirectory: "OPS", href: href), href)
        }
    }

    func testEntitiesAreNotExpanded() throws {
        let xml = """
        <!DOCTYPE package [<!ENTITY text "expanded">]>
        <package xmlns="\(opfNS)" xmlns:dc="\(dc)"><metadata><dc:title>&text;</dc:title></metadata></package>
        """
        XCTAssertNil(try EPubMetadataDocument.metadata(Data(xml.utf8)))
    }

    func testExternalEntitiesAreRejectedWithoutReadingTheirTarget() throws {
        let xml = """
        <!DOCTYPE package [<!ENTITY text SYSTEM "file:///not-a-real-file">]>
        <package xmlns="\(opfNS)" xmlns:dc="\(dc)"><metadata><dc:title>&text;</dc:title></metadata></package>
        """
        XCTAssertNil(try EPubMetadataDocument.metadata(Data(xml.utf8)))
    }

    func testDirectOversizedAndOverdeepXMLAreRejected() throws {
        XCTAssertNil(try EPubMetadataDocument.metadata(Data(repeating: 32, count: 8 * 1024 * 1024 + 1)))
        let deep = String(repeating: "<x>", count: 200) + String(repeating: "</x>", count: 200)
        XCTAssertNil(try EPubMetadataDocument.metadata(opf("<dc:title>Book</dc:title>\(deep)")))
    }

    func testCancelledDecoderThrowsRatherThanReturningInvalidMetadata() async {
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try EPubMetadataDocument.metadata(Data("<package/>".utf8))
        }
        do {
            _ = try await work.value
            XCTFail("Cancellation was swallowed")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
