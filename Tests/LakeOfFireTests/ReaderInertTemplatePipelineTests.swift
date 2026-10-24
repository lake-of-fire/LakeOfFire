import Foundation
import LakeOfFireContent
import SwiftSoup
import WebKit
import XCTest
@testable import LakeOfFireReader

final class ReaderInertTemplatePipelineTests: XCTestCase {
    private let pageURL = URL(string: "https://example.com/article")!
    private let snippetURL = URL(string: "internal://local/snippet?key=template-regression")!

    func testPreprocessUsesLiveTitleAndOriginalLinkWithoutMutatingDrafts() throws {
        let document = try SwiftSoup.parse("""
        <template id='draft'><h1 id='reader-title'></h1><button class='reader-view-original'>draft</button></template>
        <h1 id='reader-title'></h1><button class='reader-view-original'>View Original</button>
        """)
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let original = try draft.outerHtml()

        _ = try preprocessWebContentForReaderMode(doc: document, url: pageURL, fallbackTitle: "Live title")

        XCTAssertEqual(try readerDocumentElementWithID("reader-title", in: document)?.text(), "Live title")
        let links = try readerDocumentElements(in: document, matching: ".reader-view-original")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.tagNameNormal(), "a")
        XCTAssertEqual(try links.first?.attr("href"), pageURL.absoluteString)
        XCTAssertEqual(try draft.outerHtml(), original)
        XCTAssertTrue(try document.getElementById("draft") === draft)
    }

    func testFallbackTitleRetainsNestedTemplateAndItsOriginalAncestors() throws {
        let document = try SwiftSoup.parse("""
        <h1 id='reader-title'><span id='owner'><b id='inner'><template id='draft'>下書き</template></b></span></h1>
        """)
        let title = try XCTUnwrap(document.getElementById("reader-title"))
        let owner = try XCTUnwrap(document.getElementById("owner"))
        let inner = try XCTUnwrap(document.getElementById("inner"))
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let original = try draft.outerHtml()

        _ = try preprocessWebContentForReaderMode(doc: document, url: pageURL, fallbackTitle: "猫 & 犬")
        try process(document, title: "unused")

        XCTAssertEqual(try ReaderDocumentTree.text(in: title), "猫 & 犬")
        XCTAssertTrue(owner.parent() === title)
        XCTAssertTrue(inner.parent() === owner)
        XCTAssertTrue(draft.parent() === inner)
        XCTAssertEqual(try draft.outerHtml(), original)
    }

    func testTemplateWithTitleIDPreventsMutationOfALaterDuplicate() throws {
        let document = try SwiftSoup.parse("""
        <template id='reader-title'>下書き</template><h1 id='reader-title'></h1>
        """)
        let templates = try document.getElementsByTag("template").array()
        let draft = try XCTUnwrap(templates.first)
        let original = try draft.outerHtml()

        _ = try preprocessWebContentForReaderMode(doc: document, url: pageURL, fallbackTitle: "Fallback")
        try process(document, title: "Fallback")
        normalizeSnippetReaderTitle(in: document, title: "Snippet")

        XCTAssertEqual(try document.getElementsByTag("h1").first()?.text(), "")
        XCTAssertEqual(try draft.outerHtml(), original)
        XCTAssertTrue(try ReaderDocumentTree.elementWithID("reader-title", in: document) === draft)
    }

    func testSnippetTitleNormalizationChangesOnlyVisibleText() throws {
        let document = try SwiftSoup.parse("<h1 id='reader-title'>old<span id='owner'><template id='draft'>下書き</template>old</span></h1>")
        let title = try XCTUnwrap(document.getElementById("reader-title"))
        let owner = try XCTUnwrap(document.getElementById("owner"))
        let draft = try XCTUnwrap(document.getElementById("draft"))

        normalizeSnippetReaderTitle(in: document, title: "New title")

        XCTAssertEqual(try ReaderDocumentTree.text(in: title), "New title")
        XCTAssertTrue(owner.parent() === title)
        XCTAssertTrue(draft.parent() === owner)
        XCTAssertEqual(try draft.text(), "下書き")
    }

    func testProcessPromotesLiveLegacyContentClassWithoutEditingDraftWrapper() throws {
        let document = try SwiftSoup.parse("""
        <template id='draft'><div class='reader-content keep'>下書き</div></template>
        <div class='reader-content keep'>猫</div>
        """)
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let original = try draft.outerHtml()

        try process(document, cacheWarmer: true)

        XCTAssertEqual(try readerDocumentElementWithID("reader-content", in: document)?.text(), "猫")
        XCTAssertEqual(try draft.outerHtml(), original)
    }

    func testProcessPromotesLiveSnippetClassAfterInertDuplicate() throws {
        let document = try SwiftSoup.parse("""
        <template id='draft'><div class='mnb-snippet'>下書き</div></template>
        <div class='mnb-snippet'>猫</div>
        """)
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let original = try draft.outerHtml()

        try process(document, url: snippetURL, cacheWarmer: true)

        let content = try XCTUnwrap(readerDocumentElementWithID("reader-content", in: document))
        XCTAssertEqual(try content.text(), "猫")
        XCTAssertFalse(content.hasClass("mnb-snippet"))
        XCTAssertEqual(try draft.outerHtml(), original)
    }

    func testTemplateContentIDBlocksPromotionOfALaterSnippet() throws {
        let document = try SwiftSoup.parse("<template id='reader-content'>下書き</template><div class='mnb-snippet'>猫</div>")
        let snippet = try XCTUnwrap(document.getElementsByClass("mnb-snippet").first())

        try process(document, url: snippetURL, cacheWarmer: true)

        XCTAssertEqual(snippet.id(), "")
        XCTAssertTrue(snippet.hasClass("mnb-snippet"))
        XCTAssertNil(try readerDocumentElementWithID("reader-content", in: document))
    }

    func testTitleDerivationExcludesNestedAndWholeTemplateTitles() throws {
        let document = try SwiftSoup.parse("""
        <template><h1 id='reader-title'>draft title</h1></template>
        <h1 id='reader-title'>Live <template>draft text</template>title</h1>
        """)

        XCTAssertEqual(titleFromReadabilityDocument(document), "Live title")
        XCTAssertEqual(titleFromReadabilityHTML(try document.outerHtml()), "Live title")
        XCTAssertNil(titleFromReadabilityHTML("<template><h1>only draft</h1></template>"))
    }

    func testHeaderImageIgnoresDraftMediaAndDuplicateImageURL() throws {
        let imageURL = URL(string: "https://example.com/header.jpg")!
        let document = try SwiftSoup.parse("""
        <template id='draft'><div id='reader-header'></div><img src='\(imageURL.absoluteString)'></template>
        <div id='reader-header'></div><div id='reader-content'><template><figure><img src='draft.jpg'></figure></template><p>猫</p></div>
        """)
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let original = try draft.outerHtml()

        try process(document, imageURL: imageURL, injectImage: true)

        let header = try XCTUnwrap(readerDocumentElementWithID("reader-header", in: document))
        XCTAssertEqual(try readerDocumentElements(in: header, matching: "img").first?.attr("src"), imageURL.absoluteString)
        XCTAssertEqual(try draft.outerHtml(), original)
    }

    func testLiveMediaPreservesExistingHeaderImagePolicy() throws {
        let document = try SwiftSoup.parse("""
        <div id='reader-header'></div><div id='reader-content'><img src='live.jpg'></div>
        <template><img src='draft.jpg'></template>
        """)

        try process(document, imageURL: URL(string: "https://example.com/header.jpg")!, injectImage: true)

        let header = try XCTUnwrap(readerDocumentElementWithID("reader-header", in: document))
        XCTAssertTrue(try readerDocumentElements(in: header, matching: "img").isEmpty)
    }

    func testTemplateHeaderIDDoesNotBorrowLaterHeader() throws {
        let document = try SwiftSoup.parse("""
        <template id='reader-header'>draft</template><div id='reader-header'></div><div id='reader-content'>猫</div>
        """)

        try process(document, imageURL: URL(string: "https://example.com/header.jpg")!, injectImage: true)

        XCTAssertTrue(try readerDocumentElements(in: document, matching: "img").isEmpty)
    }

    func testStyleExtractionIgnoresDraftStyleAndRetainsFirstIDPolicy() throws {
        let document = try SwiftSoup.parse("""
        <template><style id='swiftuiwebview-readability-styles'>draft { color: red; }</style></template>
        <style id='swiftuiwebview-readability-styles'>live { color: blue; }</style>
        """)
        XCTAssertEqual(readerReadabilityStyleText(in: document, fallback: "fallback"), "live { color: blue; }")

        let templateID = try SwiftSoup.parse("""
        <template id='swiftuiwebview-readability-styles'>draft</template>
        <style id='swiftuiwebview-readability-styles'>later</style>
        """)
        XCTAssertEqual(readerReadabilityStyleText(in: templateID, fallback: "fallback"), "fallback")
    }

    func testFontGateDoesNotRewriteDraftOrBorrowTemplateID() throws {
        let document = try SwiftSoup.parse("""
        <head><template id='draft'><style id='mnb-custom-font-gate'>draft CSS</style></template></head><body>猫</body>
        """)
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let original = try draft.outerHtml()

        try upsertDeferredSharedReaderFontGate(in: document)

        XCTAssertEqual(try readerDocumentElements(in: document, matching: "style#mnb-custom-font-gate").count, 1)
        XCTAssertEqual(try draft.outerHtml(), original)
        let templateID = try SwiftSoup.parse("<template id='mnb-custom-font-gate'>draft</template><p>猫</p>")
        try upsertDeferredSharedReaderFontGate(in: templateID)
        XCTAssertTrue(try readerDocumentElements(in: templateID, matching: "style#mnb-custom-font-gate").isEmpty)
    }

    func testBodyOrderKeepsInertTemplateInPlaceAndMovesLiveDecoration() throws {
        let document = try SwiftSoup.parse("""
        <body><template id='draft'><div id='reader-header'>draft</div><div id='reader-content'>draft</div></template>
        <aside id='decoration'>Live aside</aside><div id='reader-header'></div><div id='reader-content'>猫</div></body>
        """)
        let body = try XCTUnwrap(ReaderDocumentTree.firstElement(named: "body", in: document))
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let decoration = try XCTUnwrap(document.getElementById("decoration"))
        let content = try XCTUnwrap(readerDocumentElementWithID("reader-content", in: document))
        let original = try draft.outerHtml()

        normalizeReadabilityBodyOrder(document)

        XCTAssertTrue(draft.parent() === body)
        XCTAssertTrue(decoration.parent() === content)
        XCTAssertEqual(try draft.outerHtml(), original)
    }

    func testFeedTransformationsDoNotMutateDraftSelectorsOrText() throws {
        for host in ["matcha-jp.com", "watanoc.com", "hukumusume.com", "www.hiraganatimes.com", "www.cnn.co.jp", "slow-communication.jp", "www3.nhk.or.jp", "hypebeast.com"] {
            let document = try SwiftSoup.parse("""
            <template id='draft'><h1 id='reader-title'>CNN.co.jp : 下 書 き | site</h1><div id='reader-content'><div class='page'>
            <article><header>draft author</header><p>[label draft] 次(next)⇒ (音声) <br>下 書 き</p><table><tr><td>draft</td></tr></table>
            <a class='dicWin'><span class='under'>draft</span></a><div id='bottom-bar'>draft</div></article></div></div><div id='post-feed'>draft</div></template>
            <h1 id='reader-title'>猫 | site</h1><div id='reader-content'><div class='page'><article><p>猫 で す。</p></article></div></div>
            """)
            let draft = try XCTUnwrap(document.getElementById("draft"))
            let original = try draft.outerHtml()

            _ = try preprocessWebContentForReaderMode(doc: document, url: URL(string: "https://\(host)/article")!)

            XCTAssertEqual(try draft.outerHtml(), original, host)
            XCTAssertTrue(try document.getElementById("draft") === draft, host)
            if host == "matcha-jp.com" || host == "watanoc.com" {
                XCTAssertTrue(try ReaderDocumentTree.text(in: XCTUnwrap(readerDocumentElementWithID("reader-content", in: document))).contains("猫です。"), host)
            }
        }
    }

    func testDestructiveFeedCleanupRetainsTemplateOwningContainers() throws {
        let document = try SwiftSoup.parse("""
        <div id='reader-content'><div class='page'><article>
        <p id='owner'>次(next)⇒ <span><template id='draft'>下書き</template></span></p>
        <p id='ordinary'>次(next)⇒</p></article></div></div><h1 id='reader-title'>猫</h1>
        """)
        let owner = try XCTUnwrap(document.getElementById("owner"))
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let original = try draft.outerHtml()

        transformContentSpecificToFeed(doc: document, url: URL(string: "https://watanoc.com/article")!)

        XCTAssertTrue(try document.getElementById("owner") === owner)
        XCTAssertEqual(try draft.outerHtml(), original)
        XCTAssertNil(try document.getElementById("ordinary"))
    }

    func testMatchaTitleRewriteRetainsInlineTemplateHierarchy() throws {
        let document = try SwiftSoup.parse("""
        <h1 id='reader-title'>猫 <span id='owner'><template id='draft'>下 書 き</template>で す。</span></h1>
        <div id='reader-content'><div class='page'><p>本 文</p></div></div>
        """)
        let title = try XCTUnwrap(document.getElementById("reader-title"))
        let owner = try XCTUnwrap(document.getElementById("owner"))
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let original = try draft.outerHtml()

        _ = try preprocessWebContentForReaderMode(doc: document, url: URL(string: "https://matcha-jp.com/article")!)

        XCTAssertEqual(try ReaderDocumentTree.text(in: title), "猫です。")
        XCTAssertTrue(owner.parent() === title)
        XCTAssertTrue(draft.parent() === owner)
        XCTAssertEqual(try draft.outerHtml(), original)
    }

    func testWatanocImageLiftingSkipsTemplateChildrenAndRetainsOrdinaryBehavior() throws {
        let document = try SwiftSoup.parse("""
        <h1 id='reader-title'>猫</h1><div id='reader-content'><article><div id='container'>
        <template id='draft'><img id='draft-image' src='draft.jpg'></template>
        <div id='ordinary'><img id='live-image' src='live.jpg'></div></div></article></div>
        """)
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let draftImage = try XCTUnwrap(document.getElementById("draft-image"))
        let original = try draft.outerHtml()

        transformContentSpecificToFeed(doc: document, url: URL(string: "https://watanoc.com/article")!)

        XCTAssertTrue(draftImage.parent() === draft)
        XCTAssertEqual(try draft.outerHtml(), original)
        XCTAssertNil(try ReaderDocumentTree.elementWithID("draft-image", in: document))
        XCTAssertEqual(try document.getElementById("live-image")?.parent()?.id(), "container")
        XCTAssertTrue(try XCTUnwrap(document.getElementById("ordinary")).getElementsByTag("img").isEmpty())
    }

    func testRuntimeAssetStrippingPreservesDraftScriptsAndStyles() throws {
        let html = """
        <html><body class='readability-mode'><div id='reader-content'><template id='draft'>
        <script id='draft-script'>draft()</script><style id='mnb-readability-styles'>draft { }</style></template>猫</div>
        <script id='live-script'>runtime()</script><style id='mnb-readability-styles'>runtime { }</style></body></html>
        """
        let stripped = stripRuntimeReadabilityAssets(from: html)
        let document = try SwiftSoup.parse(stripped)

        XCTAssertNotNil(try document.getElementById("draft-script"))
        XCTAssertEqual(try document.getElementById("draft")?.getElementsByTag("style").size(), 1)
        XCTAssertNil(try document.getElementById("live-script"))
        XCTAssertTrue(try readerDocumentElements(in: document, matching: "style#mnb-readability-styles").isEmpty)
    }

    func testSnippetBuilderAndLatePipelineRetainNestedAndForeignTemplates() throws {
        let input = """
        <div class='mnb-snippet'><p>猫<template id='draft'><template id='nested'>下書き</template></template>です。</p>
        <svg><template id='foreign'><text>犬</text></template></svg></div>
        """
        let html = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
            html: input, contentURL: snippetURL, fallbackTitle: "Live title"
        ))
        let document = try SwiftSoup.parse(html)
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let original = try draft.outerHtml()

        _ = try preprocessWebContentForReaderMode(doc: document, url: snippetURL, fallbackTitle: "Fallback")
        try process(document, url: snippetURL)
        normalizeSnippetReaderTitle(in: document, title: "Live title")
        let reparsed = try SwiftSoup.parse(try document.outerHtml())

        XCTAssertEqual(titleFromReadabilityDocument(reparsed), "Live title")
        XCTAssertEqual(try draft.outerHtml(), original)
        XCTAssertNotNil(try reparsed.getElementById("nested"))
        XCTAssertNil(try ReaderDocumentTree.elementWithID("nested", in: reparsed))
        let foreign = try XCTUnwrap(readerDocumentElementWithID("foreign", in: reparsed))
        XCTAssertEqual(foreign.namespace(), .svg)
        XCTAssertEqual(try ReaderDocumentTree.text(in: foreign), "犬")
        XCTAssertFalse(try ReaderDocumentTree.text(in: XCTUnwrap(readerDocumentElementWithID("reader-content", in: reparsed))).contains("下書き"))
    }

    func testCanonicalSnippetRebuildUsesLiveContentAndPreservesItsDraft() throws {
        let input = """
        <html><body class='readability-mode'><template><h1 id='reader-title'>wrong</h1><div id='reader-content'>wrong body</div></template>
        <h1 id='reader-title'>Live title</h1><div id='reader-content'><p>猫</p><template id='draft'>下書き</template>
        <svg><template id='foreign'>犬</template></svg></div></body></html>
        """
        let html = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
            html: input, contentURL: snippetURL, fallbackTitle: "Fallback"
        ))
        let document = try SwiftSoup.parse(html)
        _ = try preprocessWebContentForReaderMode(doc: document, url: snippetURL)
        try process(document, url: snippetURL)

        XCTAssertEqual(titleFromReadabilityDocument(document), "Live title")
        XCTAssertNotNil(try document.getElementById("draft"))
        XCTAssertEqual(try readerDocumentElementWithID("foreign", in: document)?.namespace(), .svg)
        let content = try XCTUnwrap(readerDocumentElementWithID("reader-content", in: document))
        XCTAssertFalse(try ReaderDocumentTree.text(in: content).contains("wrong"))
        XCTAssertFalse(try ReaderDocumentTree.text(in: content).contains("下書き"))
    }

    func testSnippetBuilderDoesNotAdmitDraftMetadataToTheDirectParseShortcut() throws {
        let input = """
        <p id='live'>日本語の本文です。</p><template id='draft'><m-m id='draft-segment'>下書き</m-m>
        <script id='mnb-segment-metadata' data-mnb-seg-meta='true'>{}</script></template>
        """
        let html = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
            html: input, contentURL: snippetURL, fallbackTitle: "Live title"
        ))

        XCTAssertTrue(hasCanonicalReadabilityMarkup(in: html))
        XCTAssertFalse(hasPublishedReaderSegmentMetadataMarkup(in: html))
        let document = try SwiftSoup.parse(html)
        XCTAssertNotNil(try document.getElementById("draft-segment"))
        XCTAssertNotNil(try readerDocumentElementWithID("live", in: document))
    }

    func testDirectParseShortcutRequiresBothLiveSegmentsAndLiveSidecar() throws {
        for content in [
            "<m-m>猫</m-m><template><script id='mnb-segment-metadata'>{}</script></template>",
            "<template><m-m>下書き</m-m></template><script id='mnb-segment-metadata'>{}</script>",
        ] {
            let html = "<html><body class='readability-mode'><div id='reader-content'>\(content)</div></body></html>"
            XCTAssertFalse(hasPublishedReaderSegmentMetadataMarkup(in: html))
        }
    }

    func testSnippetBuilderRetainsTheLiveMetadataShortcut() throws {
        let html = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
            html: "<m-m id='live-segment'>猫</m-m><script id='mnb-segment-metadata' data-mnb-seg-meta='true'>{}</script>",
            contentURL: snippetURL, fallbackTitle: "Live title"
        ))

        XCTAssertTrue(hasCanonicalReadabilityMarkup(in: html))
        XCTAssertTrue(hasPublishedReaderSegmentMetadataMarkup(in: html))
    }

    func testInertContentIDDoesNotForceCanonicalSnippetRebuild() throws {
        let input = """
        <html><body class='readability-mode'><template id='draft'><div id='reader-content'>下書き</div></template>
        <p id='live'>猫です。</p></body></html>
        """
        XCTAssertFalse(hasReaderContentNodeMarkup(in: input))
        XCTAssertFalse(hasCanonicalReadabilityMarkup(in: input))
        let html = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
            html: input, contentURL: snippetURL, fallbackTitle: "Live title"
        ))
        let document = try SwiftSoup.parse(html)

        XCTAssertEqual(try readerDocumentElementWithID("live", in: document)?.text(), "猫です。")
        XCTAssertNotNil(try document.getElementById("draft"))
        XCTAssertTrue(hasCanonicalReadabilityMarkup(in: html))
    }

    func testCanonicalTemplateRootBlocksLaterDuplicateDuringRebuildAndShortcut() throws {
        let input = """
        <html><body class='readability-mode'><template id='reader-content'>下書き</template>
        <div id='reader-content'><m-m>猫</m-m></div><script id='mnb-segment-metadata'>{}</script></body></html>
        """

        XCTAssertTrue(hasReaderContentNodeMarkup(in: input))
        XCTAssertTrue(hasCanonicalReadabilityMarkup(in: input))
        XCTAssertFalse(hasPublishedReaderSegmentMetadataMarkup(in: input))
        XCTAssertNil(buildSnippetCanonicalReadabilityHTML(html: input, contentURL: snippetURL, fallbackTitle: "Fallback"))
    }

    func testXMLShortcutInspectionRespectsPrefixedTemplateAndExactCase() throws {
        let prefix = "<?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml' xmlns:h='http://www.w3.org/1999/xhtml'><body class='readability-mode'><div id='reader-content'>猫"
        let suffix = "</div></body></html>"
        let markers = "<m-m>下書き</m-m><script id='mnb-segment-metadata'>{}</script>"

        XCTAssertFalse(hasPublishedReaderSegmentMetadataMarkup(in: prefix + "<h:template>" + markers + "</h:template>" + suffix))
        XCTAssertTrue(hasPublishedReaderSegmentMetadataMarkup(in: prefix + markers + suffix))
        XCTAssertTrue(hasPublishedReaderSegmentMetadataMarkup(in: prefix + "<TEMPLATE>" + markers + "</TEMPLATE>" + suffix))
    }

    func testXMLInertBodyCannotSupplyCanonicalBodyClass() {
        let input = """
        <?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml'><template><body class='readability-mode'></body></template>
        <body><div id='reader-content'>猫</div></body></html>
        """

        XCTAssertFalse(hasReadabilityModeBodyClassMarkup(in: input))
        XCTAssertFalse(hasCanonicalReadabilityMarkup(in: input))
    }

    func testOrdinarySnippetStillUsesItsTitleAndVisibleContent() throws {
        let html = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
            html: "<p id='live'>日本語の本文です。</p>", contentURL: snippetURL, fallbackTitle: "普通のタイトル"
        ))
        let document = try SwiftSoup.parse(html)
        _ = try preprocessWebContentForReaderMode(doc: document, url: snippetURL)
        try process(document, url: snippetURL)

        XCTAssertEqual(titleFromReadabilityDocument(document), "普通のタイトル")
        XCTAssertEqual(try readerDocumentElementWithID("live", in: document)?.text(), "日本語の本文です。")
        XCTAssertFalse(ReaderDocumentTree.containsInertHTMLTemplate(in: document))
    }

    func testOrdinaryOriginalLinkLabelRetainsItsWhitespacePolicy() throws {
        let document = try SwiftSoup.parse("<button class='reader-view-original'>  View   Original\n link  </button>")
        let button = try XCTUnwrap(document.getElementsByTag("button").first())
        let expected = try button.text(trimAndNormaliseWhitespace: false)

        try wireViewOriginalLinks(doc: document, url: pageURL)

        let anchor = try XCTUnwrap(document.getElementsByTag("a").first())
        XCTAssertEqual(try anchor.text(trimAndNormaliseWhitespace: false), expected)
    }

    func testCanonicalRebuildRetainsTitleAndBylineInternalWhitespace() throws {
        let title = "Live   title\n next"
        let byline = "Author   name\n next"
        let input = "<html><body class='readability-mode'><h1 id='reader-title'>\(title)</h1>"
            + "<span id='reader-byline'>\(byline)</span><div id='reader-content'>猫</div></body></html>"
        let html = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
            html: input, contentURL: snippetURL, fallbackTitle: "Fallback"
        ))
        let document = try SwiftSoup.parse(html)

        XCTAssertEqual(try readerDocumentElementWithID("reader-title", in: document)?.text(trimAndNormaliseWhitespace: false), title)
        XCTAssertEqual(try readerDocumentElementWithID("reader-byline", in: document)?.text(trimAndNormaliseWhitespace: false), byline)
    }

    func testUnnormalizedTextPolicyAlsoAppliesToTemplatePrunedCopy() throws {
        let document = try SwiftSoup.parse("<div id='root'>  猫   <template>下書き</template>犬\n 次  </div>")
        let root = try XCTUnwrap(document.getElementById("root"))
        let control = try SwiftSoup.parse("<div id='root'>  猫   犬\n 次  </div>")

        XCTAssertEqual(
            try ReaderDocumentTree.text(in: root, trimAndNormaliseWhitespace: false),
            try control.getElementById("root")?.text(trimAndNormaliseWhitespace: false)
        )
    }

    func testXMLLatePipelineUsesLiveScaffoldAndPreservesQualifiedDraft() throws {
        let document = try SwiftSoup.parse("""
        <?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml' xmlns:h='http://www.w3.org/1999/xhtml'>
        <h:template id='draft'><head><style id='mnb-custom-font-gate'>draft</style></head><body id='draft-body'><h1 id='reader-title'>下書き</h1></body></h:template>
        <head id='live-head'><title>Live head title</title></head><BODY id='uppercase-body'>ordinary XML</BODY>
        <body id='live-body'><h1 id='reader-title'></h1><div id='reader-header'></div><div id='reader-content'>猫</div></body></html>
        """, "", Parser.xmlParser())
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let original = try draft.outerHtml()
        let liveBody = try XCTUnwrap(document.getElementById("live-body"))
        let uppercaseBody = try XCTUnwrap(document.getElementById("uppercase-body"))

        _ = try preprocessWebContentForReaderMode(doc: document, url: pageURL, fallbackTitle: "Live fallback")
        try process(document, isEbook: true)
        try upsertDeferredSharedReaderFontGate(in: document)
        markReaderRenderReady(in: document)

        XCTAssertTrue(ReaderDocumentTree.firstElement(named: "body", in: document) === liveBody)
        XCTAssertEqual(try liveBody.attr("data-is-ebook"), "true")
        XCTAssertEqual(try liveBody.attr("data-mnb-reader-render-ready"), "1")
        XCTAssertEqual(try uppercaseBody.attr("data-is-ebook"), "")
        XCTAssertEqual(titleFromReadabilityDocument(document), "Live fallback")
        XCTAssertEqual(titleFromReadabilityHTML(try document.outerHtml()), "Live fallback")
        XCTAssertEqual(try draft.outerHtml(), original)
        let gate = try XCTUnwrap(readerDocumentElementWithID("mnb-custom-font-gate", in: document))
        XCTAssertEqual(gate.parent()?.id(), "live-head")
    }

    func testXMLTemplateInsidePrecedingBreakDoesNotStallFeedCleanup() throws {
        let document = try SwiftSoup.parse("""
        <html xmlns='http://www.w3.org/1999/xhtml'><body><br id='owner'><template id='draft'>下書き</template></br><p id='translation'>← other →</p></body></html>
        """, "", Parser.xmlParser())
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let owner = try XCTUnwrap(document.getElementById("owner"))

        transformContentSpecificToFeed(doc: document, url: URL(string: "https://hukumusume.com/article")!)

        XCTAssertTrue(draft.parent() === owner)
        XCTAssertNil(try document.getElementById("translation"))
    }

    func testXMLSnippetBuildKeepsNamespaceAncestorsThroughTheLatePipeline() throws {
        let input = """
        <?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml' xmlns:h='http://www.w3.org/1999/xhtml' xmlns:s='http://www.w3.org/2000/svg'>
        <head><title>Author head</title></head><body id='author-body'><section id='owner'><h:template id='draft'><div id='reader-content'><m-m>下書き</m-m><script id='mnb-segment-metadata'>{}</script></div></h:template><p id='live'>日本語の本文です。</p><s:template id='foreign'>foreign</s:template></section></body></html>
        """
        let output = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
            html: input, contentURL: snippetURL, fallbackTitle: "Live title",
            publishedTime: "Oct 24 & 25", hideReaderTitleOverride: true
        ))
        XCTAssertTrue(readerReadabilityContentIsXML(output))
        XCTAssertTrue(hasCanonicalReadabilityMarkup(in: output))
        XCTAssertFalse(hasPublishedReaderSegmentMetadataMarkup(in: output))
        let document = try SwiftSoup.parse(output, "", Parser.xmlParser())
        let draft = try XCTUnwrap(document.getElementById("draft"))
        let owner = try XCTUnwrap(document.getElementById("owner"))
        let originalDraft = try draft.outerHtml()

        _ = try preprocessWebContentForReaderMode(doc: document, url: snippetURL)
        try process(document, url: snippetURL)

        XCTAssertTrue(draft.parent() === owner)
        XCTAssertEqual(draft.tagName(), "h:template")
        XCTAssertEqual(draft.namespace(), .html)
        XCTAssertEqual(try document.getElementById("foreign")?.namespace(), .svg)
        XCTAssertEqual(try ReaderDocumentTree.firstElement(named: "html", in: document)?.attr("xmlns:h"), "http://www.w3.org/1999/xhtml")
        XCTAssertEqual(try ReaderDocumentTree.firstElement(named: "body", in: document)?.id(), "author-body")
        XCTAssertEqual(try document.getElementById("live")?.text(), "日本語の本文です。")
        XCTAssertEqual(try readerDocumentElementWithID("reader-title", in: document)?.text(), "Live title")
        XCTAssertEqual(try readerDocumentElementWithID("reader-publication-date", in: document)?.text(), "Oct 24 & 25")
        XCTAssertEqual(try readerDocumentElementWithID("reader-publication-date", in: document)?.attr("aria-label"), "Reader metadata date: Oct 24 & 25")
        XCTAssertTrue(ReaderDocumentTree.firstElement(named: "body", in: document)?.hasClass(ReaderContentLoader.snippetReaderTitleSuppressionBodyClass) == true)
        XCTAssertEqual(try draft.outerHtml(), originalDraft)
        XCTAssertFalse(hasPublishedReaderSegmentMetadataMarkup(in: try document.outerHtml()))
    }

    func testXMLCanonicalRebuildPreservesAuthorHeaderAndDateUnlessExplicitlyOverridden() throws {
        let input = """
        <?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml' xmlns:h='http://www.w3.org/1999/xhtml'><head></head><body class='readability-mode'>
        <div id='reader-header' data-author='keep'><h1 id='reader-title'>Author title<span id='title-owner'><h:template id='title-draft'>draft title</h:template></span></h1><span id='reader-byline'>Author   name</span><span id='reader-publication-date'>Existing date</span></div>
        <div id='reader-content'><h:template id='draft'><div id='reader-content'>draft content</div></h:template><p id='live'>猫です。</p></div></body></html>
        """
        let preserved = try XCTUnwrap(rebuildCanonicalSnippetReadabilityHTML(
            html: input, contentURL: snippetURL, fallbackTitle: "Fallback", hideReaderTitleOverride: false
        ))
        let preservedDocument = try SwiftSoup.parse(preserved, "", Parser.xmlParser())
        XCTAssertEqual(try readerDocumentElementWithID("reader-header", in: preservedDocument)?.attr("data-author"), "keep")
        XCTAssertEqual(try readerDocumentElementWithID("reader-title", in: preservedDocument).map { try ReaderDocumentTree.text(in: $0) }, "Author title")
        XCTAssertEqual(try readerDocumentElementWithID("reader-byline", in: preservedDocument)?.text(trimAndNormaliseWhitespace: false), "Author   name")
        XCTAssertEqual(try readerDocumentElementWithID("reader-publication-date", in: preservedDocument)?.text(), "Existing date")

        let updated = try XCTUnwrap(rebuildCanonicalSnippetReadabilityHTML(
            html: preserved, contentURL: snippetURL, fallbackTitle: "Fallback",
            publishedTime: "New & explicit", preferredTitle: "Preferred title", hideReaderTitleOverride: true
        ))
        let updatedDocument = try SwiftSoup.parse(updated, "", Parser.xmlParser())
        XCTAssertEqual(try readerDocumentElementWithID("reader-title", in: updatedDocument).map { try ReaderDocumentTree.text(in: $0) }, "Preferred title")
        XCTAssertEqual(try updatedDocument.getElementById("title-draft")?.parent()?.id(), "title-owner")
        XCTAssertEqual(try readerDocumentElementWithID("reader-publication-date", in: updatedDocument)?.text(), "New & explicit")
        XCTAssertEqual(try readerDocumentElementWithID("reader-publication-date", in: updatedDocument)?.attr("aria-label"), "Reader metadata date: New & explicit")
        XCTAssertEqual(try updatedDocument.getElementById("draft")?.namespace(), .html)
        XCTAssertEqual(try updatedDocument.getElementById("live")?.text(), "猫です。")
    }

    func testXMLSnippetWithLiveMetadataRetainsTheDirectParseShortcut() throws {
        let input = "<?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml'><body><m-m id='live'>猫</m-m><script id='mnb-segment-metadata'>{}</script></body></html>"
        let built = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(html: input, contentURL: snippetURL, fallbackTitle: "Title"))
        let rebuilt = try XCTUnwrap(rebuildCanonicalSnippetReadabilityHTML(html: built, contentURL: snippetURL, fallbackTitle: "Fallback"))
        XCTAssertTrue(hasPublishedReaderSegmentMetadataMarkup(in: built))
        XCTAssertTrue(hasPublishedReaderSegmentMetadataMarkup(in: rebuilt))
        XCTAssertTrue(readerReadabilityContentIsXML(rebuilt))
    }

    func testXMLTemplateRootStillBlocksBuildAndRebuild() {
        let input = "<?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml'><body class='readability-mode'><template id='reader-content'>draft</template><div id='reader-content'>猫</div></body></html>"
        XCTAssertNil(buildSnippetCanonicalReadabilityHTML(html: input, contentURL: snippetURL, fallbackTitle: "Title"))
        XCTAssertNil(rebuildCanonicalSnippetReadabilityHTML(html: input, contentURL: snippetURL, fallbackTitle: "Title"))
    }

    func testXMLWithoutTheSelectedLiveBodyDoesNotBecomeAnHTMLShell() {
        let input = "<?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml'><template><body>draft</body></template><BODY>ordinary XML node</BODY></html>"
        XCTAssertNil(buildSnippetCanonicalReadabilityHTML(html: input, contentURL: snippetURL, fallbackTitle: "Title"))
        XCTAssertNil(rebuildCanonicalSnippetReadabilityHTML(html: input, contentURL: snippetURL, fallbackTitle: "Title"))
    }

    func testXMLBodyExtractionUsesTheLiveBodyWithoutReinterpretingPrefixes() throws {
        let input = "<?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml' xmlns:h='http://www.w3.org/1999/xhtml'><h:template><body id='draft'>draft</body></h:template><body><p id='live'>猫</p></body></html>"
        let body = try XCTUnwrap(bodyInnerHTML(from: input))
        XCTAssertTrue(body.contains("live"))
        XCTAssertFalse(body.contains("draft"))
    }

    func testFinalMIMESelectionUsesOnlyTheSelectedXMLProlog() {
        for input in ["<?xml version='1.0'?><html/>", "<?XML version='1.0'?><html/>"] {
            XCTAssertTrue(readerReadabilityContentIsXML(input))
            XCTAssertEqual(readerReadabilityMIMEType(isXML: readerReadabilityContentIsXML(input)), "application/xhtml+xml")
        }
        for input in ["<html xmlns='http://www.w3.org/1999/xhtml'></html>", " <?xml version='1.0'?><html/>", "<p>ordinary HTML</p>"] {
            XCTAssertFalse(readerReadabilityContentIsXML(input))
            XCTAssertEqual(readerReadabilityMIMEType(isXML: readerReadabilityContentIsXML(input)), "text/html")
        }
    }

    func testXMLStyleExtractionDecodesEntitiesBeforeFrameTextContent() throws {
        let document = try SwiftSoup.parse("""
        <?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml'><head><style id='swiftuiwebview-readability-styles'>p &gt; span { content: 'A &amp; B'; }<template>draft CSS</template></style></head><body></body></html>
        """, "", Parser.xmlParser())
        let draft = try XCTUnwrap(document.getElementsByTag("template").first())
        let original = try draft.outerHtml()

        XCTAssertEqual(readerReadabilityStyleText(in: document, fallback: "fallback"), "p > span { content: 'A & B'; }")
        XCTAssertEqual(try draft.outerHtml(), original)
    }

    func testFinalSidecarTransportLeavesDraftScriptsAndXMLInline() throws {
        let html = "<html><head></head><body><template id='draft'><script id='mnb-segment-metadata'>{}</script></template><div id='reader-content'>猫</div></body></html>"
        let xml = "<?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml'><head></head><body><div id='reader-content'>猫</div><script id='mnb-segment-metadata' type='application/json'>{\"fixture\":\"A &amp; B &lt; C\"}</script></body></html>"
        for input in [html, xml] {
            let bytes = Array(input.utf8)
            XCTAssertEqual(readerReadabilityHTMLForSyntheticLoad(bytes), bytes)
        }
        let externalXML = "<?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml'><head><meta name='mnb-segment-sidecar' content='internal://sidecar/example' /></head><body>猫</body></html>"
        XCTAssertEqual(readerReadabilityHTMLForSyntheticLoad(Array(externalXML.utf8)), Array(externalXML.utf8))
    }

    func testOrdinaryHTMLSidecarStillExternalizesAndAnExistingDescriptorIsStable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directory)
        let input = "<html><head></head><body><div id='reader-content'>猫</div><script id='mnb-segment-metadata' type='application/json'>{\"fixture\":true}</script></body></html>"
        let bytes = readerReadabilityHTMLForSyntheticLoad(Array(input.utf8), sidecarStore: store)
        let document = try SwiftSoup.parse(String(decoding: bytes, as: UTF8.self))

        XCTAssertNil(try document.getElementById("mnb-segment-metadata"))
        XCTAssertEqual(try document.select("meta[name=mnb-segment-sidecar]").count, 1)
        XCTAssertEqual(readerReadabilityHTMLForSyntheticLoad(bytes, sidecarStore: store), bytes)
    }

    private func process(
        _ document: SwiftSoup.Document,
        url: URL? = nil,
        title: String? = nil,
        imageURL: URL? = nil,
        injectImage: Bool = false,
        isEbook: Bool = false,
        cacheWarmer: Bool = false
    ) throws {
        try processForReaderMode(
            doc: document, url: url ?? pageURL, contentSectionLocationIdentifier: nil,
            isEBook: isEbook, isCacheWarmer: cacheWarmer, defaultTitle: title,
            imageURL: imageURL, injectEntryImageIntoHeader: injectImage, defaultFontSize: 21
        )
    }
}

@MainActor
final class ReaderInertTemplateFrameTests: XCTestCase {
    private let snippetURL = URL(string: "internal://local/snippet?key=xml-frame-regression")!
    private let baseURL = URL(string: "https://example.com/reader")!

    func testXMLFrameInjectionPreservesTemplatesNamespacesAndTheTargetRoot() async throws {
        let source = try xmlSnippet()
        for isXMLTarget in [false, true] {
            let prolog = isXMLTarget ? "<?xml version='1.0'?>" : ""
            let target = prolog + "<html xmlns='http://www.w3.org/1999/xhtml'><head></head><body><div id='mount' data-owner='keep'><p id='previous'>old</p></div></body></html>"
            let webView = try await load(target, ready: "document.getElementById('previous') !== null")
            _ = try await webView.evaluateJavaScript("window.savedReaderRoot = document.getElementById('mount')")

            try await inject(source, into: webView, selector: "#mount")

            let result = try await webView.evaluateJavaScript("""
            (() => {
                const draft = document.getElementById('draft');
                const nested = draft?.content?.querySelector('#nested');
                const foreign = document.getElementById('foreign');
                const root = document.getElementById('mount');
                return root === window.savedReaderRoot && root.getAttribute('data-owner') === 'keep'
                    && draft?.namespaceURI === 'http://www.w3.org/1999/xhtml' && draft.prefix === 'h'
                    && draft.childNodes.length === 0 && draft.content.querySelector('#hidden')?.textContent === 'draft'
                    && nested?.content?.querySelector('#nested-hidden')?.textContent === 'nested draft'
                    && document.getElementById('hidden') === null && document.getElementById('nested-hidden') === null
                    && draft.parentElement.id === 'owner' && foreign?.namespaceURI === 'http://www.w3.org/2000/svg'
                    && !foreign.content && foreign.textContent === 'foreign text'
                    && document.getElementById('live')?.textContent === '猫 & 犬'
                    && document.getElementById('reader-title')?.textContent === 'Live & title'
                    && document.getElementById('reader-publication-date')?.textContent === 'Oct 24 & 25'
                    && document.getElementById('reader-publication-date')?.getAttribute('aria-label') === 'Reader metadata date: Oct 24 & 25'
                    && document.getElementsByTagNameNS('*', 'parsererror').length === 0
                    && document.getElementById('swiftuiwebview-readability-styles')?.namespaceURI === 'http://www.w3.org/1999/xhtml'
                    && document.getElementById('swiftuiwebview-readability-styles').textContent.includes('p > span')
                    && document.getElementById('swiftuiwebview-readability-styles').textContent.includes('A & B')
                    && getComputedStyle(document.getElementById('styled')).color === 'rgb(1, 2, 3)'
                    && window.readerRuntimeProbe === 1;
            })()
            """) as? Bool
            XCTAssertEqual(result, true, "XML target: \(isXMLTarget)")
            webView.stopLoading()
        }
    }

    func testFinalXMLMIMELoadKeepsTheAuthoredDocumentWellFormedAndTemplatesInert() async throws {
        let built = try xmlSnippet()
        let source = String(decoding: readerReadabilityHTMLForSyntheticLoad(Array(built.utf8)), as: UTF8.self)
        XCTAssertEqual(source, built)
        XCTAssertEqual(readerReadabilityMIMEType(isXML: readerReadabilityContentIsXML(source)), "application/xhtml+xml")
        let webView = try await load(source, ready: "document.getElementById('live') !== null")
        defer { webView.stopLoading() }

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const draft = document.getElementById('draft');
            return document.contentType === 'application/xhtml+xml'
                && document.getElementsByTagNameNS('*', 'parsererror').length === 0
                && draft?.namespaceURI === 'http://www.w3.org/1999/xhtml' && draft.prefix === 'h'
                && draft.content?.querySelector('#hidden')?.textContent === 'draft'
                && document.getElementById('hidden') === null
                && document.getElementById('live')?.textContent === '猫 & 犬'
                && document.getElementById('reader-title')?.textContent === 'Live & title'
                && document.getElementById('reader-publication-date')?.textContent === 'Oct 24 & 25'
                && JSON.parse(document.getElementById('mnb-segment-metadata').textContent).fixture === 'A & B < C'
                && document.querySelector('meta[name="mnb-segment-sidecar"]') === null
                && document.querySelector('style')?.textContent.includes('p > span')
                && getComputedStyle(document.getElementById('styled')).color === 'rgb(1, 2, 3)';
        })()
        """) as? Bool
        XCTAssertEqual(result, true)
    }

    func testOrdinaryHTMLFrameInjectionRetainsTheExistingReplacementPath() async throws {
        let webView = try await load(
            "<html><head></head><body data-owner='old'><p id='previous'>old</p></body></html>",
            ready: "document.getElementById('previous') !== null"
        )
        defer { webView.stopLoading() }
        _ = try await webView.evaluateJavaScript("window.savedReaderRoot = document.body")
        let source = try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
            html: "<p id='live'>普通の本文</p>", contentURL: snippetURL, fallbackTitle: "Ordinary title"
        ))

        try await inject(source, into: webView)

        let result = try await webView.evaluateJavaScript("""
        document.body !== window.savedReaderRoot
            && document.body.getAttribute('data-owner') === null
            && document.getElementById('live')?.textContent === '普通の本文'
            && document.getElementById('reader-title')?.textContent === 'Ordinary title'
            && document.body.className === 'readability-mode fixture'
            && window.readerRuntimeProbe === 1
        """) as? Bool
        XCTAssertEqual(result, true)
    }

    func testMalformedXMLAndMissingTargetFailBeforeReplacingFrameContent() async throws {
        let webView = try await load(
            "<html><head><style id='swiftuiwebview-readability-styles'>original</style></head><body><div id='mount'><p id='previous'>old</p></div></body></html>",
            ready: "document.getElementById('previous') !== null"
        )
        defer { webView.stopLoading() }
        _ = try await webView.evaluateJavaScript("window.savedReaderChild = document.getElementById('previous')")
        let malformed = "<?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml'><head></head><body><p>broken</body></html>"
        for (source, selector) in [(malformed, "#mount"), (try xmlSnippet(), "#missing")] {
            do {
                try await inject(source, into: webView, selector: selector)
                XCTFail("Invalid XML or missing target must reject frame injection")
            } catch {
                let unchanged = try await webView.evaluateJavaScript("""
                document.getElementById('previous') === window.savedReaderChild
                    && document.getElementById('previous').textContent === 'old'
                    && document.getElementById('swiftuiwebview-readability-styles').textContent === 'original'
                    && window.readerRuntimeProbe === undefined
                """) as? Bool
                XCTAssertEqual(unchanged, true)
            }
        }
    }

    private func xmlSnippet() throws -> String {
        try XCTUnwrap(buildSnippetCanonicalReadabilityHTML(
            html: """
            <?xml version='1.0'?><html xmlns='http://www.w3.org/1999/xhtml' xmlns:h='http://www.w3.org/1999/xhtml' xmlns:s='http://www.w3.org/2000/svg'><head><style id='swiftuiwebview-readability-styles'>p &gt; span { color: rgb(1, 2, 3); } p::before { content: 'A &amp; B'; }</style></head><body><section id='owner'><h:template id='draft'><p id='hidden'>draft</p><h:template id='nested'><p id='nested-hidden'>nested draft</p></h:template></h:template><p id='live'><span id='styled'>猫 &amp; 犬</span></p><s:template id='foreign'>foreign text</s:template></section><script id='mnb-segment-metadata' type='application/json' data-mnb-seg-meta='true'>{"fixture":"A &amp; B &lt; C","version":10}</script></body></html>
            """,
            contentURL: snippetURL, fallbackTitle: "Live & title", publishedTime: "Oct 24 & 25"
        ))
    }

    private func inject(_ source: String, into webView: WKWebView, selector: String = "") async throws {
        let isXML = readerReadabilityContentIsXML(source)
        let document = try SwiftSoup.parse(source, "", isXML ? Parser.xmlParser() : Parser.htmlParser())
        _ = try await webView.callAsyncJavaScript(
            readerReadabilityFrameInjectionScript,
            arguments: [
                "renderToSelector": selector,
                "html": source,
                "isXMLContent": isXML,
                "css": readerReadabilityStyleText(in: document, fallback: "fallback"),
                "bodyClassNames": "readability-mode fixture",
                "readerModeScript": "window.readerRuntimeProbe = (window.readerRuntimeProbe || 0) + 1",
            ],
            in: nil,
            contentWorld: .page
        )
    }

    private func load(_ source: String, ready: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
        webView.load(
            Data(source.utf8),
            mimeType: readerReadabilityMIMEType(isXML: readerReadabilityContentIsXML(source)),
            characterEncodingName: "utf-8",
            baseURL: baseURL
        )
        let deadline = Date().addingTimeInterval(10)
        while (try? await webView.evaluateJavaScript(ready)) as? Bool != true {
            guard Date() < deadline else {
                webView.stopLoading()
                throw URLError(.timedOut)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return webView
    }
}
