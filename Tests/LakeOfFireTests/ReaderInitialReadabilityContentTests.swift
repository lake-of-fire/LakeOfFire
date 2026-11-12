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

    func testInputBoundaryPreventsOneDraftImageFromBecomingALiveCarouselSlide() throws {
        let result = try extractAdmittedArticle(inserting: """
        <div class="image-carousel">
          <template><img src="https://example.test/draft.jpg" alt="draft"></template>
          <img src="https://example.test/public.jpg" alt="public">
        </div>
        """)
        let document = try canonicalAndLateDocument(content: result.content)

        XCTAssertEqual(try document.select("#reader-content img").array().map { try $0.attr("alt") }, ["public"])
        XCTAssertEqual(try document.select("[data-readability-carousel]").count, 0)
        XCTAssertFalse(try document.outerHtml().contains("draft.jpg"))
        XCTAssertTrue(try XCTUnwrap(document.getElementById("visible-final")).text().hasPrefix("VISIBLE_FINAL_PARAGRAPH"))
    }

    func testInputBoundaryKeepsPublicCarouselAndCaptionsWhenNestedDraftIsPruned() throws {
        let result = try extractAdmittedArticle(inserting: """
        <div class="image-carousel">
          <figure><img src="https://example.test/public-a.jpg" alt="public-a"><figcaption>Public caption A</figcaption></figure>
          <template><template><figure><img src="https://example.test/draft.jpg" alt="draft"><figcaption>Draft caption</figcaption></figure></template></template>
          <figure><img src="https://example.test/public-b.jpg" alt="public-b"><figcaption>Public caption B</figcaption></figure>
        </div>
        """)
        let document = try canonicalAndLateDocument(content: result.content)

        XCTAssertEqual(try document.select("[data-readability-carousel-slide] img").array().map { try $0.attr("alt") }, ["public-a", "public-b"])
        XCTAssertEqual(try document.select("[data-readability-carousel]").count, 1)
        let captions = try document.select("[data-readability-carousel-slide] figcaption").array().map { try $0.text() }
        XCTAssertEqual(captions, ["Public caption A", "Public caption B"])
        XCTAssertFalse(try document.outerHtml().contains("draft.jpg"))
        XCTAssertFalse(try ReaderDocumentTree.text(in: document).contains("Draft caption"))
        XCTAssertNotNil(try document.getElementById("visible-final"))
    }

    func testInputBoundaryPreservesHeadMetadataAndBaseURLThroughActualExtraction() throws {
        let head = """
        <title>Metadata &amp; source URLs</title>
        <meta property="og:title" content="Metadata &amp; source URLs">
        <meta name="author" content="A &amp; B">
        <meta property="article:published_time" content="2026-05-03T09:30:00Z">
        <base href="https://images.example.test/editions/">
        """
        let html = inputArticleHTML(inserting: """
        <div class="image-carousel">
          <template><img src="draft.jpg" alt="draft"></template>
          <img src="public-a.jpg" alt="public-a"><img src="public-b.jpg" alt="public-b">
        </div>
        <p>The original field measurements are linked to their public supporting evidence in the
        <a id="source-link" href="../sources?one=1&amp;two=2">source table</a>, which explains the observations.</p>
        """, head: head)
        let input = try XCTUnwrap(readerInitialReadabilityInput(html, contentURL: pageURL))
        let inputDocument = try SwiftSoup.parse(input, pageURL.absoluteString)
        XCTAssertEqual(try inputDocument.select("head base").first()?.attr("href"), "https://images.example.test/editions/")
        XCTAssertEqual(try ReaderDocumentTree.title(in: inputDocument), "Metadata & source URLs")

        let result = try XCTUnwrap(SwiftReadability.Readability(
            html: input,
            url: pageURL,
            options: ReadabilityOptions(charThreshold: 500)
        ).parse())
        XCTAssertEqual(result.title, "Metadata & source URLs")
        XCTAssertEqual(result.byline, "A & B")
        XCTAssertEqual(result.publishedTime, "2026-05-03T09:30:00Z")
        XCTAssertEqual(result.lang, "en")
        let extracted = try SwiftSoup.parseBodyFragment(result.content)
        XCTAssertEqual(try extracted.select("[data-readability-carousel-slide] img").array().map { try $0.attr("src") }, [
            "https://images.example.test/editions/public-a.jpg",
            "https://images.example.test/editions/public-b.jpg",
        ])
        XCTAssertEqual(try extracted.getElementById("source-link")?.attr("href"), "https://images.example.test/sources?one=1&two=2")

        let content = try XCTUnwrap(readerInitialReadabilityContent(result.content))
        let canonical = try SwiftSoup.parse(buildCanonicalReadabilityHTML(
            title: try XCTUnwrap(result.title),
            byline: try XCTUnwrap(result.byline),
            publishedTime: result.publishedTime,
            content: content,
            contentURL: pageURL
        ))
        XCTAssertEqual(try canonical.getElementById("reader-title")?.text(), "Metadata & source URLs")
        XCTAssertEqual(try canonical.getElementById("reader-byline")?.text(), "A & B")
        XCTAssertFalse(try canonical.outerHtml().contains("draft.jpg"))
    }

    func testInputBoundaryKeepsForeignTemplatesAndHTMLIntegrationPointPolicy() throws {
        let html = """
        <!doctype html><html><head><title>Namespaces</title></head><body>
        <template id="html-draft"><p id="draft-text">Draft</p></template>
        <svg><template id="svg-template"><text id="svg-text">SVG text</text></template>
        <foreignObject><template id="integration-draft"><p>Draft</p></template>
        <p id="integration-live">Live HTML</p></foreignObject></svg>
        <math><template id="math-template"><mi id="math-text">x</mi></template></math>
        <template-card id="card"><p id="custom-live">Custom element</p></template-card>
        </body></html>
        """
        let input = try XCTUnwrap(readerInitialReadabilityInput(html, contentURL: pageURL))
        let document = try SwiftSoup.parse(input, pageURL.absoluteString)

        for id in ["html-draft", "draft-text", "integration-draft"] {
            XCTAssertNil(try document.getElementById(id))
        }
        XCTAssertEqual(try document.getElementById("svg-template")?.namespace(), .svg)
        XCTAssertEqual(try document.getElementById("svg-text")?.text(), "SVG text")
        XCTAssertEqual(try document.getElementById("math-template")?.namespace(), .mathml)
        XCTAssertEqual(try document.getElementById("math-text")?.text(), "x")
        XCTAssertEqual(try document.getElementById("integration-live")?.namespace(), .html)
        XCTAssertEqual(try document.getElementById("custom-live")?.parent()?.id(), "card")
        XCTAssertEqual(try ReaderDocumentTree.title(in: document), "Namespaces")
    }

    func testInputBoundaryUsesXMLNamespaceAndCasePolicyForPrefixedTemplates() throws {
        let xml = """
        <?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"
        xmlns:h="http://www.w3.org/1999/xhtml" xmlns:s="http://www.w3.org/2000/svg">
        <head><title>XML namespaces</title></head><body>
        <h:template id="draft"><h:p id="draft-text">Draft</h:p></h:template>
        <h:Template id="case-sensitive"><h:p>Case-sensitive live content</h:p></h:Template>
        <s:template id="foreign"><s:text id="foreign-text">Foreign content</s:text></s:template>
        <h:p id="live">Live content</h:p></body></html>
        """
        let input = try XCTUnwrap(readerInitialReadabilityInput(xml, contentURL: pageURL))
        let document = try SwiftSoup.parse(input, pageURL.absoluteString)

        XCTAssertEqual(document.outputSettings().syntax(), .xml)
        XCTAssertNil(try document.getElementById("draft"))
        XCTAssertNil(try document.getElementById("draft-text"))
        XCTAssertEqual(try document.getElementById("case-sensitive")?.tagName(), "h:Template")
        XCTAssertEqual(try document.getElementById("case-sensitive")?.namespace(), .html)
        XCTAssertEqual(try document.getElementById("foreign")?.namespace(), .svg)
        XCTAssertEqual(try document.getElementById("foreign-text")?.text(), "Foreign content")
        XCTAssertEqual(try document.getElementById("live")?.text(), "Live content")
        XCTAssertEqual(try ReaderDocumentTree.title(in: document), "XML namespaces")
    }

    func testInputBoundaryWithoutInertTemplatesKeepsExactDocumentSerialization() throws {
        let inputs = [
            "<!DOCTYPE html><html><head><title>A &amp; B</title></head><body><p data-extra='value'>Live</p></body></html>\n",
            "<!-- <template>literal comment</template> --><html><head></head><body><p>Live</p></body></html>",
            "<html><head></head><body><p data-literal='<template>literal attribute</template>'>Live</p></body></html>",
            "<html><head></head><body><svg><template><text>Foreign</text></template></svg></body></html>",
            "<html><head></head><body><template-card>Live custom element</template-card></body></html>",
            "<?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml'><head/><body><Template>Live</Template></body></html>",
        ]
        for input in inputs {
            XCTAssertEqual(try XCTUnwrap(readerInitialReadabilityInput(input, contentURL: pageURL)), input)
        }
    }

    func testInputBoundaryKeepsHealthyCarouselThroughCanonicalAndLateProcessing() throws {
        let html = inputArticleHTML(inserting: """
        <div class="image-carousel"><img src="https://example.test/public-a.jpg" alt="public-a">
        <img src="https://example.test/public-b.jpg" alt="public-b"></div>
        """)
        let input = try XCTUnwrap(readerInitialReadabilityInput(html, contentURL: pageURL))
        XCTAssertEqual(input, html)
        let result = try XCTUnwrap(SwiftReadability.Readability(
            html: input,
            url: pageURL,
            options: ReadabilityOptions(charThreshold: 500)
        ).parse())
        let document = try canonicalAndLateDocument(content: result.content)

        XCTAssertEqual(try document.select("[data-readability-carousel-slide] img").array().map { try $0.attr("alt") }, ["public-a", "public-b"])
        XCTAssertEqual(try document.select("[data-readability-carousel]").count, 1)
        XCTAssertNotNil(try document.getElementById("visible-final"))
        XCTAssertEqual(try document.getElementById("reader-title")?.text(), "Field observations")
    }

    func testInputBoundaryLeavesTemplateOnlyDocumentUnavailableToExtraction() throws {
        let html = """
        <html><head><title>Draft only</title></head><body>
        <template><article><p>\(String(repeating: "Draft prose. ", count: 200))</p>
        <div class="image-carousel"><img src="draft-a.jpg"><img src="draft-b.jpg"></div>
        </article></template></body></html>
        """
        let input = try XCTUnwrap(readerInitialReadabilityInput(html, contentURL: pageURL))
        let document = try SwiftSoup.parse(input, pageURL.absoluteString)
        XCTAssertTrue(try XCTUnwrap(document.body()).text().isEmpty)
        XCTAssertNil(try SwiftReadability.Readability(
            html: input,
            url: pageURL,
            options: ReadabilityOptions(charThreshold: 500)
        ).parse())
    }

    private func inputArticleHTML(inserting fragment: String, head: String = "<title>Field observations</title>") -> String {
        let prose = """
        This is the visible article explaining how the original field measurements were collected, compared, and checked against the journal. The public account describes a real observation and keeps its surrounding evidence together.
        """
        let paragraphs = (0..<6).map { index in
            "<p>\(index) \(Array(repeating: prose, count: 3).joined(separator: " "))</p>"
        }.joined()
        return """
        <!doctype html><html lang="en"><head>\(head)</head>
        <body><article><h1>Field observations</h1>\(paragraphs)\(fragment)
        <p id="visible-final">VISIBLE_FINAL_PARAGRAPH \(prose)</p></article></body></html>
        """
    }

    private func extractAdmittedArticle(inserting fragment: String) throws -> SwiftReadability.ReadabilityResult {
        let input = try XCTUnwrap(readerInitialReadabilityInput(inputArticleHTML(inserting: fragment), contentURL: pageURL))
        return try XCTUnwrap(SwiftReadability.Readability(
            html: input,
            url: pageURL,
            options: ReadabilityOptions(charThreshold: 500)
        ).parse())
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
