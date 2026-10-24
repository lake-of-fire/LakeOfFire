import Foundation
import XCTest
@testable import LakeOfFireReader

final class EPubMetadataSelectionTests: XCTestCase {
    private func withPackage(
        metadata: String,
        declaration: String = "",
        containerDeclaration: String = "",
        _ assertion: ((title: String, author: String?, coverHref: String?, publicationDate: Date?)?) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"),
                                                withIntermediateDirectories: true)
        let container = """
        \(containerDeclaration)
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let package = """
        \(declaration)
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata>\(metadata)</metadata><manifest/>
        </package>
        """
        try Data(container.utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data(package.utf8).write(to: root.appendingPathComponent("package.opf"))
        try assertion(EPubParser.parseMetadataAndCover(from: root))
    }

    func testEmptyCandidatesDoNotHideFirstNonemptyTitleAndCreator() throws {
        try withPackage(metadata: """
        <dc:title> </dc:title><dc:title>日本語の本</dc:title><dc:title>Other title</dc:title>
        <dc:creator> </dc:creator><dc:creator>著者</dc:creator><dc:creator>Other author</dc:creator>
        """) { result in
            XCTAssertEqual(result?.title, "日本語の本")
            XCTAssertEqual(result?.author, "著者")
        }
    }

    func testCDATAAndEscapedEntitiesContributeToMetadataText() throws {
        try withPackage(metadata: """
        <dc:title><![CDATA[日本語 <題名>]]> &amp; 続き</dc:title>
        <dc:creator><![CDATA[著者]]></dc:creator>
        """) { result in
            XCTAssertEqual(result?.title, "日本語 <題名> & 続き")
            XCTAssertEqual(result?.author, "著者")
        }
    }

    func testCDATAOnlyTitleAndCreatorProduceMetadata() throws {
        try withPackage(metadata: """
        <dc:title><![CDATA[日本語の本]]></dc:title>
        <dc:creator><![CDATA[著者]]></dc:creator>
        """) { result in
            let metadata = try XCTUnwrap(result)
            XCTAssertEqual(metadata.title, "日本語の本")
            XCTAssertEqual(metadata.author, "著者")
        }
    }

    func testExplicitMainTitleWinsOverEarlierSubtitle() throws {
        try withPackage(metadata: """
        <dc:title id="subtitle">Subtitle</dc:title><dc:title id="main">Main title</dc:title>
        <meta refines="#main" property="title-type"><![CDATA[main]]></meta>
        """) { result in XCTAssertEqual(result?.title, "Main title") }
    }

    func testDecomposedMainTitleIDDoesNotMatchComposedSubtitleID() throws {
        try withPackage(metadata: """
        <dc:title id="caf&#xE9;">Subtitle</dc:title>
        <dc:title id="cafe&#x301;">Main title</dc:title>
        <meta refines="#cafe&#x301;" property="title-type">main</meta>
        """) { result in XCTAssertEqual(result?.title, "Main title") }
    }

    func testComposedMainTitleIDDoesNotMatchDecomposedSubtitleID() throws {
        try withPackage(metadata: """
        <dc:title id="cafe&#x301;">Subtitle</dc:title>
        <dc:title id="caf&#xE9;">Main title</dc:title>
        <meta refines="#caf&#xE9;" property="title-type">main</meta>
        """) { result in XCTAssertEqual(result?.title, "Main title") }
    }

    func testUnmatchedUnicodeRefinementKeepsFirstTitle() throws {
        try withPackage(metadata: """
        <dc:title id="first">First title</dc:title>
        <dc:title id="caf&#xE9;">Other title</dc:title>
        <meta refines="#cafe&#x301;" property="title-type">main</meta>
        """) { result in XCTAssertEqual(result?.title, "First title") }
    }

    func testPercentEncodedMainTitleReferenceSelectsDecodedXMLID() throws {
        for reference in ["#%6dain", "#%6Dain", "#ma%69n"] {
            try withPackage(metadata: """
            <meta refines="\(reference)" property="title-type">main</meta>
            <dc:title id="subtitle">Subtitle</dc:title><dc:title id="main">Main title</dc:title>
            """) { result in
                XCTAssertEqual(result?.title, "Main title", reference)
            }
        }
    }

    func testPercentEncodedJapaneseMainTitleReferenceSelectsXMLID() throws {
        try withPackage(metadata: """
        <dc:title id="subtitle">Subtitle</dc:title><dc:title id="題名">日本語の本</dc:title>
        <meta refines="#%E9%A1%8C%E5%90%8D" property="title-type">main</meta>
        """) { result in XCTAssertEqual(result?.title, "日本語の本") }
    }

    func testPercentDecodedRefinementsPreserveDistinctUnicodeIDSpellings() throws {
        try withPackage(metadata: """
        <dc:title id="caf&#xE9;">Subtitle</dc:title>
        <dc:title id="cafe&#x301;">Main title</dc:title>
        <meta refines="#cafe%CC%81" property="title-type">main</meta>
        """) { result in XCTAssertEqual(result?.title, "Main title") }

        try withPackage(metadata: """
        <dc:title id="cafe&#x301;">Subtitle</dc:title>
        <dc:title id="caf&#xE9;">Main title</dc:title>
        <meta refines="#caf%C3%A9" property="title-type">main</meta>
        """) { result in XCTAssertEqual(result?.title, "Main title") }
    }

    func testRefinementPercentDecodingOccursOnlyOnce() throws {
        try withPackage(metadata: """
        <dc:title id="first">First title</dc:title><dc:title id="main">Other title</dc:title>
        <meta refines="#%256Dain" property="title-type">main</meta>
        """) { result in XCTAssertEqual(result?.title, "First title") }
    }

    func testMalformedRefinementEncodingCannotSelectMainTitle() throws {
        for reference in ["#main%", "#main%2", "#main%GG", "#main%C3%28"] {
            try withPackage(metadata: """
            <dc:title id="first">First title</dc:title><dc:title id="main">Other title</dc:title>
            <meta refines="\(reference)" property="title-type">main</meta>
            """) { result in
                XCTAssertEqual(result?.title, "First title", reference)
            }
        }
    }

    func testNonlocalAndEmptyRefinementsKeepLocalFallback() throws {
        for reference in ["other.opf#%6Dain", "https://example.test/book.opf#main", "#"] {
            try withPackage(metadata: """
            <dc:title id="first">First title</dc:title><dc:title id="main">Other title</dc:title>
            <meta refines="\(reference)" property="title-type">main</meta>
            """) { result in
                XCTAssertEqual(result?.title, "First title", reference)
            }
        }
    }

    func testForeignAndNestedRefinementsCannotSelectAlternativeTitle() throws {
        try withPackage(metadata: """
        <dc:title id="first">First title</dc:title><dc:title id="other">Other title</dc:title>
        <foreign:meta xmlns:foreign="urn:foreign" refines="#other" property="title-type">main</foreign:meta>
        <extension><meta refines="#other" property="title-type">main</meta></extension>
        """) { result in XCTAssertEqual(result?.title, "First title") }
    }

    func testEmptyTitlesCannotProduceSuccessfulMetadata() throws {
        try withPackage(metadata: "<dc:title> </dc:title><dc:title><![CDATA[ ]]></dc:title>") {
            XCTAssertNil($0)
        }
    }

    func testInternalEntityDeclarationRejectsPackageEvenWhenUnused() throws {
        try withPackage(metadata: "<dc:title>Ordinary title</dc:title>",
                        declaration: "<!DOCTYPE package [<!ENTITY custom 'expanded'>]>") {
            XCTAssertNil($0)
        }
    }

    func testExternalEntityDeclarationRejectsPackageWithoutReadingResource() throws {
        try withPackage(metadata: "<dc:title>Ordinary title</dc:title>",
                        declaration: "<!DOCTYPE package [<!ENTITY custom SYSTEM 'file:///nonexistent-metadata'>]>") {
            XCTAssertNil($0)
        }
    }

    func testEntityDeclarationRejectsContainer() throws {
        try withPackage(metadata: "<dc:title>Ordinary title</dc:title>",
                        containerDeclaration: "<!DOCTYPE container [<!ENTITY custom 'expanded'>]>") {
            XCTAssertNil($0)
        }
    }

    func testReducedPrecisionDateAndPackageGraphValidationSurviveSelectionChange() throws {
        try withPackage(metadata: "<dc:title>Title</dc:title><dc:date>2024-02</dc:date>") { result in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            XCTAssertEqual(result?.publicationDate,
                           calendar.date(from: DateComponents(year: 2024, month: 2, day: 1)))
        }
        try withPackage(metadata: "<dc:title>Title</dc:title></metadata><metadata><dc:title>Other</dc:title>") {
            XCTAssertNil($0)
        }
    }
}
