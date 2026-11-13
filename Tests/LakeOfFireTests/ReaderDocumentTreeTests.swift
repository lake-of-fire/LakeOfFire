import XCTest
import SwiftSoup
@testable import LakeOfFireReader

final class ReaderDocumentTreeTests: XCTestCase {
    func testDocumentQueriesExcludeTemplateContentsAndRetainTemplateElements() throws {
        let document = try SwiftSoup.parse("""
        <html><head><template><title>Draft title</title></template><title>Live title</title></head>
        <body><template id="draft"><m-s id="hidden">Draft</m-s></template>
        <m-s id="visible">Visible</m-s></body></html>
        """)
        XCTAssertEqual(try ReaderDocumentTree.title(in: document), "Live title")
        XCTAssertEqual(try ReaderDocumentTree.elements(in: document, matching: "m-s").map { try $0.attr("id") }, ["visible"])
        XCTAssertNil(try ReaderDocumentTree.elementWithID("hidden", in: document))
        let template = try XCTUnwrap(ReaderDocumentTree.elementWithID("draft", in: document))
        XCTAssertTrue(ReaderDocumentTree.isInertHTMLTemplate(template))
        let body = try XCTUnwrap(ReaderDocumentTree.firstElement(named: "body", in: document))
        XCTAssertTrue(ReaderDocumentTree.firstElement(named: "template", in: body) === template)
        XCTAssertEqual(try ReaderDocumentTree.elements(in: template, matching: "template").count, 1)
        XCTAssertNil(try readerDocumentElementWithID("draft", in: document))
    }

    func testHiddenRootsCannotBePromotedByTextOrCopy() throws {
        let document = try SwiftSoup.parse("<template><div id='hidden'><p>Draft</p></div></template>")
        let hidden = try XCTUnwrap(document.getElementById("hidden"))
        XCTAssertTrue(ReaderDocumentTree.isInTemplateContents(hidden))
        XCTAssertEqual(try ReaderDocumentTree.text(in: hidden), "")
        XCTAssertNil(try ReaderDocumentTree.copyExcludingInertHTMLTemplates(hidden))
        XCTAssertNil(ReaderDocumentTree.firstElement(named: "p", in: hidden))
        XCTAssertTrue(try ReaderDocumentTree.elements(in: hidden, matching: "p").isEmpty)
    }

    func testForeignTemplatesRetainContentAndHTMLIntegrationPointsRemainInert() throws {
        let document = try SwiftSoup.parse("""
        <body><svg><template id="svg-template"><text id="svg-live">SVG</text></template>
        <foreignObject><template id="html-template"><p id="html-hidden">Draft</p></template></foreignObject></svg>
        <math><template id="math-template"><mi id="math-live">Math</mi></template></math></body>
        """)
        let svg = try XCTUnwrap(document.getElementById("svg-template"))
        let math = try XCTUnwrap(document.getElementById("math-template"))
        let html = try XCTUnwrap(document.getElementById("html-template"))
        XCTAssertEqual(svg.namespace(), .svg)
        XCTAssertEqual(math.namespace(), .mathml)
        XCTAssertEqual(html.namespace(), .html)
        XCTAssertFalse(ReaderDocumentTree.isInertHTMLTemplate(svg))
        XCTAssertFalse(ReaderDocumentTree.isInertHTMLTemplate(math))
        XCTAssertTrue(ReaderDocumentTree.isInertHTMLTemplate(html))
        XCTAssertNotNil(try ReaderDocumentTree.elementWithID("svg-live", in: document))
        XCTAssertNotNil(try ReaderDocumentTree.elementWithID("math-live", in: document))
        XCTAssertNil(try ReaderDocumentTree.elementWithID("html-hidden", in: document))
    }

    func testXMLTemplatePolicyUsesExactLocalNameAndNamespaceEvenAfterCopy() throws {
        let document = try SwiftSoup.parse("""
        <h:html xmlns:h="http://www.w3.org/1999/xhtml" xmlns:s="http://www.w3.org/2000/svg">
          <h:body id="body"><h:template id="draft"><m-s id="hidden">Draft</m-s></h:template>
          <h:Template id="case-sensitive"><m-s id="case-live">Case</m-s></h:Template>
          <s:template id="foreign"><m-s id="foreign-live">SVG</m-s></s:template>
          <m-s id="live">Live</m-s></h:body>
        </h:html>
        """, "", Parser.xmlParser())
        let body = try XCTUnwrap(ReaderDocumentTree.firstElement(named: "h:body", in: document))
        let original = try document.outerHtml()
        XCTAssertNil(ReaderDocumentTree.firstElement(named: "body", in: document))
        XCTAssertEqual(try ReaderDocumentTree.elements(in: body, matching: "m-s").map { try $0.attr("id") },
                       ["case-live", "foreign-live", "live"])
        let copy = try XCTUnwrap(ReaderDocumentTree.copyExcludingInertHTMLTemplates(body))
        XCTAssertNil(copy.ownerDocument())
        XCTAssertNil(try copy.getElementById("draft"))
        XCTAssertNotNil(try copy.getElementById("case-sensitive"))
        XCTAssertNotNil(try copy.getElementById("foreign"))
        try copy.attr("data-copy", "changed")
        XCTAssertEqual(try document.outerHtml(), original)
        XCTAssertTrue(body.parent() !== nil)
        XCTAssertNil(copy.parent())
    }

    func testPrunedTextAndCopiesPreserveTheAuthorTree() throws {
        let document = try SwiftSoup.parse("<div id='content'>Alpha <template><p>Draft</p></template> Beta</div>")
        let content = try XCTUnwrap(document.getElementById("content"))
        let original = try document.outerHtml()
        XCTAssertEqual(try ReaderDocumentTree.text(in: content), "Alpha Beta")
        let copy = try XCTUnwrap(ReaderDocumentTree.copyExcludingInertHTMLTemplates(content))
        XCTAssertFalse(copy === content)
        XCTAssertFalse(ReaderDocumentTree.containsInertHTMLTemplate(in: copy))
        try copy.text("Changed")
        XCTAssertEqual(try document.outerHtml(), original)
        XCTAssertEqual(try ReaderDocumentTree.text(in: content), "Alpha Beta")
    }

    func testTextReplacementRetainsTemplateOwnersAndCleanupDoesNotRemoveThem() throws {
        let document = try SwiftSoup.parse("""
        <div id="content">Old<span id="owner"><template id="draft"><p>Draft</p></template><b>Old inner</b></span>
        <i id="ordinary">Old live</i></div>
        """)
        let content = try XCTUnwrap(document.getElementById("content"))
        let owner = try XCTUnwrap(document.getElementById("owner"))
        let template = try XCTUnwrap(document.getElementById("draft"))
        let templateHTML = try template.outerHtml()
        try removeReaderDocumentElement(owner)
        XCTAssertTrue(owner.parent() === content)
        try replaceReaderDocumentText("Replacement", in: content)
        XCTAssertEqual(try ReaderDocumentTree.text(in: content), "Replacement")
        XCTAssertEqual(try template.outerHtml(), templateHTML)
        XCTAssertTrue(template.parent() === owner)
        XCTAssertNil(try document.getElementById("ordinary"))
        XCTAssertTrue(try owner.getElementsByTag("b").isEmpty())
    }
    func testCanonicalReaderDetectionCannotBorrowAnInertContentID() throws {
        let html = "<body class='readability-mode'><template><div id='reader-content'>Draft</div></template><p>Live</p></body>"
        XCTAssertTrue(hasReadabilityModeBodyClassMarkup(in: html))
        XCTAssertFalse(hasReaderContentNodeMarkup(in: html))
        XCTAssertFalse(hasCanonicalReadabilityMarkup(in: html))
        XCTAssertNil(recoverPersistedSnippetSourceHTMLForProcessing(html))
        XCTAssertFalse(hasCanonicalReadabilityMarkup(in:
            "<body class='readability-mode'><template id='reader-content'>Draft</template></body>"))
        XCTAssertTrue(hasCanonicalReadabilityMarkup(in:
            "<body class='readability-mode'><div id='reader-content'>Live</div></body>"))
    }

    func testReaderTitleExtractionIgnoresNestedDraftsAndRetainsLiveFallback() throws {
        let document = try SwiftSoup.parse("""
        <body><template><h1 id="reader-title">Draft title</h1></template>
        <h1 id="reader-title">Live <template>Hidden suffix</template>title</h1>
        <div id="reader-content">Article</div></body>
        """)
        XCTAssertEqual(titleFromReadabilityDocument(document), "Live title")
        XCTAssertNil(titleFromReadabilityHTML("<template><h1>Only a draft</h1></template>"))
    }

    func testSnippetRecoveryTransformsOnlyLiveGeneratedMarkup() throws {
        let html = """
        <body class="readability-mode"><div id="reader-content">
        <m-s sid="live" o="true"><m-m id="live-segment">日本語</m-m></m-s>
        <template id="draft"><m-s sid="draft-sentence"><m-m id="draft-segment">下書き</m-m></m-s>
        <script id="mnb-segment-metadata">draft-sidecar</script></template></div></body>
        """
        let source = try SwiftSoup.parse(html)
        let originalDraft = try XCTUnwrap(source.getElementById("draft")).outerHtml()
        let recovered = try XCTUnwrap(recoverPersistedSnippetSourceHTMLForProcessing(html))
        let result = try SwiftSoup.parse(recovered)
        XCTAssertTrue(try ReaderDocumentTree.elements(in: result, matching: "m-m, m-s").isEmpty)
        XCTAssertEqual(try XCTUnwrap(result.getElementById("draft")).outerHtml(), originalDraft)
        XCTAssertEqual(try readerDocumentTextWithID("reader-content", in: result), "日本語")
    }

    func testCompletionProofIgnoresOnlyInertHTMLTemplateCoverage() throws {
        let sourceHTML = """
        <html><head></head><body><p>Live English</p>
        <template><m-s sid="draft"><m-m id="draft-id">下書き</m-m></m-s></template></body></html>
        """
        let document = try SwiftSoup.parse(sourceHTML)
        let proof = try XCTUnwrap(EbookReaderProcessingCompletionProof(sourceDocument: document))
        let payload = proof.complete(documentHTML: Data(sourceHTML.utf8), segmentSidecar: Data())
        XCTAssertTrue(payload.isAuthoritativelyProcessed)
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(payload))
        XCTAssertFalse(proof.complete(documentHTML: payload.documentHTML, segmentSidecar: Data()).isAuthoritativelyProcessed)

        let foreignHTML = "<html><head></head><body><svg><template><text>日本語</text></template></svg></body></html>"
        let foreignDocument = try SwiftSoup.parse(foreignHTML)
        let foreignProof = try XCTUnwrap(EbookReaderProcessingCompletionProof(sourceDocument: foreignDocument))
        XCTAssertFalse(foreignProof.complete(documentHTML: Data(foreignHTML.utf8), segmentSidecar: Data()).isAuthoritativelyProcessed)
    }

}
