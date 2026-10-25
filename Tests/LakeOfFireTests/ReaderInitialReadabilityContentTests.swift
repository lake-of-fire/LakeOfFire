import Foundation
import SwiftReadability
import SwiftSoup
import XCTest
@testable import LakeOfFireReader

final class ReaderInitialReadabilityContentTests: XCTestCase {
    private let pageURL = URL(string: "https://example.test/article")!

    func testNestedHTMLTemplateRemovesTheWholeDraftAndPreservesVisibleSiblings() throws {
        let document = try sanitizedDocument("""
        <p id="before">Before</p>
        <template id="outer"><template id="inner"><p id="inner-text">Inner draft</p></template>
        <p id="outer-tail">Outer draft tail</p></template>
        <p id="after">After</p>
        """)

        for id in ["outer", "inner", "inner-text", "outer-tail"] {
            XCTAssertNil(try document.getElementById(id))
        }
        XCTAssertEqual(try document.getElementById("before")?.text(), "Before")
        XCTAssertEqual(try document.getElementById("after")?.text(), "After")
    }

    func testMultipleMixedCaseTemplatesDoNotPromoteAnyNestedTail() throws {
        let document = try sanitizedDocument("""
        <TEMPLATE id="first"><p id="first-text">First draft</p></TEMPLATE>
        <p id="between">Between</p>
        <template id="outer"><TeMpLaTe id="middle"><template id="inner">Inner</template>
        <p id="middle-tail">Middle draft</p></TeMpLaTe><p id="outer-tail">Outer draft</p></template>
        <p id="after">After</p>
        """)

        for id in ["first", "first-text", "outer", "middle", "inner", "middle-tail", "outer-tail"] {
            XCTAssertNil(try document.getElementById(id))
        }
        XCTAssertEqual(try document.getElementById("between")?.text(), "Between")
        XCTAssertEqual(try document.getElementById("after")?.text(), "After")
    }

    func testTemplateOnlyContentRemainsEmptyForTheExistingAvailabilityGuard() throws {
        let fragments = [
            "<template>Only draft</template>",
            "  <template><template>Inner</template><p>Outer tail</p></template>  ",
            "<template>First</template>\n<template>Second</template>",
            "",
            "  \n  ",
        ]
        for fragment in fragments {
            let result = try XCTUnwrap(readerInitialReadabilityContent(fragment))
            XCTAssertTrue(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testForeignTemplateElementsKeepTheirNamespacesAndChildrenDuringHTMLRemoval() throws {
        let document = try sanitizedDocument("""
        <template id="html-draft"><p id="draft-text">Draft</p></template>
        <svg><template id="svg-template"><text id="svg-text">SVG text</text></template></svg>
        <math><template id="math-template"><mi id="math-text">x</mi></template></math>
        <p id="after">After</p>
        """)

        XCTAssertNil(try document.getElementById("html-draft"))
        XCTAssertNil(try document.getElementById("draft-text"))
        XCTAssertEqual(try document.getElementById("svg-template")?.namespace(), .svg)
        XCTAssertEqual(try document.getElementById("svg-text")?.namespace(), .svg)
        XCTAssertEqual(try document.getElementById("svg-text")?.text(), "SVG text")
        XCTAssertEqual(try document.getElementById("math-template")?.namespace(), .mathml)
        XCTAssertEqual(try document.getElementById("math-text")?.namespace(), .mathml)
        XCTAssertEqual(try document.getElementById("math-text")?.text(), "x")
        XCTAssertEqual(try document.getElementById("after")?.text(), "After")
    }

    func testHTMLIntegrationPointRemovesOnlyItsHTMLTemplate() throws {
        let document = try sanitizedDocument("""
        <svg><template id="foreign"><text>Foreign</text></template>
        <foreignObject><template id="html-draft"><p id="draft-text">Draft</p></template>
        <p id="live">Live HTML</p></foreignObject></svg>
        """)

        XCTAssertEqual(try document.getElementById("foreign")?.namespace(), .svg)
        XCTAssertNil(try document.getElementById("html-draft"))
        XCTAssertNil(try document.getElementById("draft-text"))
        XCTAssertEqual(try document.getElementById("live")?.namespace(), .html)
        XCTAssertEqual(try document.getElementById("live")?.text(), "Live HTML")
    }

    func testTemplateLikeCustomElementRetainsItsLiveChildren() throws {
        let document = try sanitizedDocument("""
        <template-card id="card"><p id="before">Before</p>
        <template id="draft">Draft</template><p id="after">After</p></template-card>
        """)

        let card = try XCTUnwrap(document.getElementById("card"))
        XCTAssertEqual(card.tagNameNormal(), "template-card")
        XCTAssertEqual(try document.getElementById("before")?.parent()?.id(), "card")
        XCTAssertEqual(try document.getElementById("after")?.parent()?.id(), "card")
        XCTAssertEqual(try card.text(), "Before After")
        XCTAssertNil(try document.getElementById("draft"))
    }

    func testFragmentsWithoutInertTemplatesKeepTheirExactSerialization() throws {
        let fragments = [
            "  <p data-extra='value'>A &amp; B</p>\n",
            "<!-- <template>literal comment</template> --><p>Live</p>",
            "<p data-literal='<template>literal attribute</template>'>Live</p>",
            "<svg><template id='foreign'><text>Foreign</text></template></svg>",
            "<template-card>Ordinary custom element</template-card>",
        ]
        for fragment in fragments {
            XCTAssertEqual(try XCTUnwrap(readerInitialReadabilityContent(fragment)), fragment)
        }
    }

    func testCanonicalConstructionPreservesEntitiesLinksAndTextMetadata() throws {
        let content = try XCTUnwrap(readerInitialReadabilityContent("""
        <template><template>Inner</template><p id="draft">Outer tail</p></template>
        <p id="live">A &amp; B &lt; 3</p><a id="link" href="/article?one=1&amp;two=2">Link</a>
        """))
        let metadata = "A & B < 3"
        let html = buildCanonicalReadabilityHTML(
            title: metadata,
            byline: metadata,
            publishedTime: nil,
            content: content,
            contentURL: pageURL
        )
        let document = try SwiftSoup.parse(html)

        XCTAssertNil(try document.getElementById("draft"))
        XCTAssertEqual(try document.getElementById("live")?.text(), metadata)
        XCTAssertEqual(try document.getElementById("link")?.attr("href"), "/article?one=1&two=2")
        XCTAssertEqual(try ReaderDocumentTree.title(in: document), metadata)
        XCTAssertEqual(try document.getElementById("reader-title")?.text(), metadata)
        XCTAssertEqual(try document.getElementById("reader-byline")?.text(), metadata)
    }

    func testActualSwiftReadabilityResultCannotPromoteNestedDraftThroughCanonicalAndLateProcessing() throws {
        let result = try extractArticle(inserting: """
        <template id="outer"><template id="inner"><p id="inner-text">Inner draft</p></template>
        <p id="outer-tail">Outer draft tail</p></template>
        """)
        // Establish producer survival before exercising the shipping boundary.
        let extracted = try SwiftSoup.parseBodyFragment(result)
        let outer = try XCTUnwrap(extracted.getElementById("outer"))
        XCTAssertEqual(try extracted.getElementById("outer-tail")?.parent()?.id(), outer.id())

        let document = try canonicalAndLateDocument(content: result)

        for id in ["outer", "inner", "inner-text", "outer-tail"] {
            XCTAssertNil(try document.getElementById(id))
        }
        XCTAssertEqual(try document.getElementById("reader-title")?.text(), "Field observations")
        XCTAssertTrue(try XCTUnwrap(document.getElementById("visible-final")).text().hasPrefix("VISIBLE_FINAL_PARAGRAPH"))
        let content = try XCTUnwrap(readerDocumentElementWithID("reader-content", in: document))
        XCTAssertFalse(try ReaderDocumentTree.text(in: content).contains("Outer draft tail"))
        XCTAssertTrue(try ReaderDocumentTree.text(in: content).contains("original field measurements"))
    }

    func testActualSwiftReadabilityOrdinaryArticleKeepsItsContentThroughTheSameBoundary() throws {
        let result = try extractArticle(inserting: "<p id='ordinary-middle'>Ordinary middle</p>")
        XCTAssertEqual(try XCTUnwrap(readerInitialReadabilityContent(result)), result)

        let document = try canonicalAndLateDocument(content: result)

        XCTAssertEqual(try document.getElementById("ordinary-middle")?.text(), "Ordinary middle")
        XCTAssertNotNil(try document.getElementById("visible-final"))
        XCTAssertEqual(try document.getElementById("reader-title")?.text(), "Field observations")
    }

    private func sanitizedDocument(_ html: String) throws -> Document {
        try SwiftSoup.parseBodyFragment(XCTUnwrap(readerInitialReadabilityContent(html)))
    }

    private func extractArticle(inserting fragment: String) throws -> String {
        let prose = """
        This is the visible article explaining how the original field measurements were collected, compared, and checked against the journal. The public account describes a real observation and keeps its surrounding evidence together.
        """
        let paragraphs = (0..<6).map { index in
            "<p>\(index) \(Array(repeating: prose, count: 3).joined(separator: " "))</p>"
        }.joined()
        let html = """
        <!doctype html><html><head><title>Field observations</title></head>
        <body><article><h1>Field observations</h1>\(paragraphs)\(fragment)
        <p id="visible-final">VISIBLE_FINAL_PARAGRAPH \(prose)</p></article></body></html>
        """
        let parser = SwiftReadability.Readability(
            html: html,
            url: pageURL,
            options: ReadabilityOptions(charThreshold: 500)
        )
        return try XCTUnwrap(parser.parse()).content
    }

    private func canonicalAndLateDocument(content: String) throws -> Document {
        let content = try XCTUnwrap(readerInitialReadabilityContent(content))
        let html = buildCanonicalReadabilityHTML(
            title: "Field observations",
            byline: "",
            publishedTime: nil,
            content: content,
            contentURL: pageURL
        )
        let document = try SwiftSoup.parse(html)
        _ = try preprocessWebContentForReaderMode(
            doc: document,
            url: pageURL,
            fallbackTitle: "Field observations"
        )
        try processForReaderMode(
            doc: document,
            url: pageURL,
            contentSectionLocationIdentifier: nil,
            isEBook: false,
            isCacheWarmer: true,
            defaultTitle: nil,
            imageURL: nil,
            injectEntryImageIntoHeader: false,
            defaultFontSize: 16
        )
        return document
    }
}
