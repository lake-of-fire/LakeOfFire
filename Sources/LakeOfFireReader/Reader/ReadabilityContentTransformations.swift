import Foundation
import SwiftSoup
import JapaneseLanguageTools

let emptySpaceRegex = try! NSRegularExpression(pattern: "[ \\u3000]")

public func transformContentSpecificToFeed(doc: Document, url: URL) {
    guard let host = url.host else { return }

    do {
        switch host {
        case "matcha-jp.com":
            try matchaTravel(doc: doc)
        case "watanoc.com":
            try wataNoC(doc: doc)
        case "hukumusume.com":
            try hukumusume(doc: doc)
        case "www.hiraganatimes.com":
            try hiraganaTimes(doc: doc)
        case "www.cnn.co.jp":
            try cnn(doc: doc)
        case "slow-communication.jp":
            try slowCommunication(doc: doc)
        case "www3.nhk.or.jp":
            try nhk(doc: doc)
        case "hypebeast.com":
            try hypebeast(doc: doc)
        default: break
        }
    } catch { }
}

private func matchaTravel(doc: Document) throws {
    // Collapse spaces.
    guard let articleTitle = try readerDocumentElementWithID("reader-title", in: doc) else { return }
    try replaceReaderDocumentText(ReaderDocumentTree.text(in: articleTitle).replace(regex: emptySpaceRegex, template: ""), in: articleTitle)

    // Collapse spaces. /*Remove (※) which reference Matcha vocab definitions that we remove.*/
    guard let readerContent = try readerDocumentElementWithID("reader-content", in: doc),
          let articleDiv = try readerDocumentElements(in: readerContent, matching: ".page").first else { return }
    guard let elements = try? readerDocumentElements(in: articleDiv, matching: "*") else { return }
    for element in elements {
        for textNode in element.textNodes() {
            var text = textNode.getWholeText()
            if containsCJKCharacters(text: text) {
                text = text.replace(regex: emptySpaceRegex, template: "")
                //text = text.replace(pattern: "\\(※\\)", template: "")
                textNode.text(text)
            }
        }
    }

    /*// Remove 【※単語】 vocab sections
    guard let articleDivContainerDiv = articleDiv.children().first() else { return }
    for element in articleDivContainerDiv.children() {
        //try print(element.text().prefix(20))
        if try element.text().starts(with: "【※単語】") {
            try element.remove()
        }
    }*/
}

private func wataNoC(doc: Document) throws {
    guard let readerContentElement = try readerDocumentElementWithID("reader-content", in: doc),
          let articleDiv = try readerDocumentElements(in: readerContentElement, matching: "article").first else { return }

    // Remove the " –freeweb manage ..." title suffix.
    guard let titleElement = try readerDocumentElementWithID("reader-title", in: doc) else { return }
    var title = try ReaderDocumentTree.text(in: titleElement)
    if let range = title.range(of: " – free web magazine", options: .backwards) {
        title = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        try replaceReaderDocumentText(title, in: titleElement)
    }
    if let range = title.range(of: ")") {
        title.insert(" ", at: range.upperBound)
        try replaceReaderDocumentText(title, in: titleElement)
    }

    // Remove the author header which can remain in the article body, duplicated.
    try removeReaderDocumentElement(readerDocumentElements(in: readerContentElement, matching: "header").first)

    // Remove comments and rest of footer.
    try removeReaderDocumentElement(readerDocumentElementWithID("reply-title", in: readerContentElement)?.parent())
    try removeReaderDocumentElement(readerDocumentElementWithID("content-bottom-widget", in: readerContentElement))
    try removeReaderDocumentElement(readerDocumentElements(in: readerContentElement, matching: "ul > li > p > a").first?.parent()?.parent()?.parent()?.parent())

    // Remove "english" (or other language) translation buttons.
    for translationImg in try readerDocumentElements(in: readerContentElement, matching: "div span:first-of-type img") {
        // The translation image URLs look like kigoo-en.jpg
        if try !translationImg.attr("src").contains("kigoo-") {
            continue
        }

        try removeReaderDocumentElement(translationImg.parent()?.parent())
    }

    // Un-bold words that had grammar explanations.
    for strong in try readerDocumentElements(in: readerContentElement, matching: "span[title] strong") {
        guard !ReaderDocumentTree.containsInertHTMLTemplate(in: strong) else { continue }
        let surface = try ReaderDocumentTree.text(in: strong)
        try strong.before(surface)
        try strong.remove()
    }

    // Remove broken paragraphs that display code.
    for p in try readerDocumentElements(in: readerContentElement, matching: "p") {
        if p.ownText().contains("[label ") {
            try removeReaderDocumentElement(p)
        }
    }

    // Make images block level
    if let childDivs = try readerDocumentElements(in: articleDiv, matching: "div").first?.children() {
        for div in childDivs {
            guard !ReaderDocumentTree.isInertHTMLTemplate(div),
                  !ReaderDocumentTree.isInTemplateContents(div) else { continue }
            if let firstChild = div.children().first(), firstChild.tagNameNormalUTF8() == UTF8Arrays.img,
               !ReaderDocumentTree.containsInertHTMLTemplate(in: firstChild) {
                let imgHtml = try firstChild.outerHtml()
                try firstChild.remove()
                try div.before(imgHtml)
            }
        }
    }

    // Collapse spaces and learning markup in the text.
    for br in try readerDocumentElements(in: articleDiv, matching: "br") {
        try removeReaderDocumentElement(br)
    }
    for wordWithTipElement in try readerDocumentElements(in: articleDiv, matching: "[data-tipso]") {
        guard !ReaderDocumentTree.containsInertHTMLTemplate(in: wordWithTipElement) else { continue }
        try wordWithTipElement.before(wordWithTipElement.ownText())
        try wordWithTipElement.remove()
    }

    // Remove bottom bar with audio player
    try removeReaderDocumentElement(readerDocumentElementWithID("bottom-bar", in: articleDiv))

    for element in try readerDocumentElements(in: articleDiv, matching: "*") {
        guard containsCJKCharacters(text: element.ownText()) else { continue }

        for textNode in element.textNodes() {
            let text = textNode.text()
            // Appears to sometimes contain either full-width or latin spaces.
            let newText = text.replace(regex: emptySpaceRegex, template: "")
            if text != newText {
                textNode.text(newText)
            }
        }
    }

    // Remove nonfunctional "next" links and other garbage.
    for p in try readerDocumentElements(in: doc, matching: "p") {
        for garbageText in ["次(next)⇒", "つぎ(next)"] {
            if try ReaderDocumentTree.text(in: p).contains(garbageText) {
                try removeReaderDocumentElement(p)
                break
            }
        }
    }

}

private func hukumusume(doc: Document) throws {
    for table in try readerDocumentElements(in: doc, matching: "table") {
        try removeReaderDocumentElement(table)
    }

    func removeTranslationOptions(_ tag: Element) throws {
        let visibleText = try ReaderDocumentTree.text(in: tag)
        if visibleText.contains("←") && visibleText.contains("→") {
            guard !ReaderDocumentTree.containsInertHTMLTemplate(in: tag) else { return }
            // Remove line-breaks preceding the translation options paragraph.
            while true {
                let sibling = try tag.previousElementSibling()
                if (sibling?.tagNameNormal() ?? "") != "br" {
                    break
                }
                if let sibling, ReaderDocumentTree.containsInertHTMLTemplate(in: sibling) { break }
                try removeReaderDocumentElement(sibling)
            }
            try removeReaderDocumentElement(tag)
        }
    }

    for tag in try readerDocumentElements(in: doc, matching: "p") {
        try removeTranslationOptions(tag)
    }
    for tag in try readerDocumentElements(in: doc, matching: "font") {
        try removeTranslationOptions(tag)
    }
    for tag in try readerDocumentElements(in: doc, matching: "[href='javascript:history.back();']") {
        try removeReaderDocumentElement(tag)
    }

    // Remove useless spacer.gif
    for img in try readerDocumentElements(in: doc, matching: "img") {
        if let src = try? img.attr("src"), src.hasSuffix("/spacer.gif") {
            try removeReaderDocumentElement(img)
        }
    }

    // Remove empty paragraphs.
    for p in try readerDocumentElements(in: doc, matching: "p") {
        if !p.hasText() && !p.hasChildNodes() {
            try removeReaderDocumentElement(p)
        }
    }

    // Remove <br> at start or end of paragraph nodes.
    for br in try readerDocumentElements(in: doc, matching: "br") {
        if let parent = br.parent(), parent.tagNameNormalUTF8() == UTF8Arrays.p && (br.previousSibling() == nil || !br.hasNextSibling()) {
            try removeReaderDocumentElement(br)
        }
    }

    // Remove breadcrumb nav at top.
    for p in try readerDocumentElements(in: doc, matching: "p") {
        if try ReaderDocumentTree.text(in: p).contains(" > ") {
            let anchors = try readerDocumentElements(in: p, matching: "a")
            if anchors.first == nil {
                continue
            }
            var match = true
            for anchor in anchors {
                if try !(anchor.attr("href").contains("../") && anchor.attr("href").contains("hukumusume.com/douwa/")) {
                    match = false
                    break
                }
            }
            if match {
                try removeReaderDocumentElement(p)
                break
            }
        }
    }
}

private func hiraganaTimes(doc: Document) throws {
    if let content = try readerDocumentElementWithID("reader-content", in: doc) {
        try removeReaderDocumentElement(readerDocumentElements(in: content, matching: "p").first)
    }
}

private func cnn(doc: Document) throws {
    guard let titleElement = try readerDocumentElementWithID("reader-title", in: doc) else { return }
    let title = try ReaderDocumentTree.text(in: titleElement)
    if let range = title.range(of: "CNN.co.jp : ") {
        try replaceReaderDocumentText(title[range.upperBound...].trimmingCharacters(in: .whitespaces), in: titleElement)
    }
}

private func slowCommunication(doc: Document) throws {
    guard let content = try readerDocumentElementWithID("reader-content", in: doc),
          let pageElement = try readerDocumentElements(in: content, matching: ".page").first else { return }

    // Remove date and tag which get interpreted as an article paragraph.
//    guard let dateAndTagElement = try pageElement.getElementsByTag("p").first() else { return }
//    try dateAndTagElement.remove()

    // Remove the inline audio.
    if let article = try readerDocumentElements(in: pageElement, matching: "article").first,
       let inlineAudioElement = try readerDocumentElements(in: article, matching: "audio").first {
        try removeReaderDocumentElement(inlineAudioElement)
    }

    // Remove the audio credit, which is confusing in our UI.
    for p in try readerDocumentElements(in: doc, matching: "p") {
        if try ReaderDocumentTree.text(in: p).hasPrefix("(音声") {
            try removeReaderDocumentElement(p)
            break
        }
    }

    // Remove the line-breaks within the article that they add for readability but which screw with our sentence detection.
    for br in try readerDocumentElements(in: doc, matching: "br") {
        try removeReaderDocumentElement(br)
    }
}

private func nhk(doc: Document) throws {
    guard let content = try readerDocumentElementWithID("reader-content", in: doc),
          let pageElement = try readerDocumentElements(in: content, matching: ".page").first else { return }

    // Un-link words that have NHK popup dictionaries.
    for wordLink in try readerDocumentElements(in: pageElement, matching: "a.dicWin") {
        guard !ReaderDocumentTree.containsInertHTMLTemplate(in: wordLink) else { continue }
        if let word = try readerDocumentElements(in: wordLink, matching: "span.under").first?.ownText() {
            try wordLink.before(word)
            try wordLink.remove()
        }
    }
}

private func hypebeast(doc: Document) throws {
    guard let content = try readerDocumentElementWithID("reader-content", in: doc),
          let pageElement = try readerDocumentElements(in: content, matching: ".page").first else { return }

    // Remove the "『HYPEBEAST』がお届けするその他最新のファッション情報もお見逃しなく。" footer from articles.
    for p in try readerDocumentElements(in: pageElement, matching: "p") {
        if p.ownText() == "『HYPEBEAST』がお届けするもお見逃しなく。" {
            try removeReaderDocumentElement(p)
        }
    }

    // Remove "What To Read Next" footer
    try removeReaderDocumentElement(readerDocumentElementWithID("post-feed", in: doc))
}

public func fixAnnoyingTitlesWithPipes(doc: Document, url: URL) throws {
    guard shouldPreferPipePrefixTitle(url: url) else { return }
    guard let titleElement = try readerDocumentElementWithID("reader-title", in: doc) else { return }
    let textNodes = try titleElement.textNodes()
    for node in textNodes {
        let original = node.getWholeText()
        let updated = fixAnnoyingTitlesWithPipes(title: original, url: url)
        node.text(updated)
    }
}

public func fixAnnoyingTitlesWithPipes(title: String) -> String {
    title
}

public func fixAnnoyingTitlesWithPipes(title: String, url: URL) -> String {
    guard shouldPreferPipePrefixTitle(url: url) else { return title }
    guard let range = title.range(of: "|", options: .backwards) else { return title }
    let beforeText = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    return beforeText.isEmpty ? title : beforeText
}

private func shouldPreferPipePrefixTitle(url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "matcha-jp.com"
        || host.hasSuffix(".matcha-jp.com")
        || host == "news.web.nhk"
        || host.hasSuffix(".news.web.nhk")
        || host == "www3.nhk.or.jp"
        || host.hasSuffix(".nhk.or.jp")
}

public func wireViewOriginalLinks(doc: Document, url: URL) throws {
    let originalLinks = try readerDocumentElements(in: doc, matching: ".reader-view-original")
    for originalLink in originalLinks {
        if originalLink.tagName().lowercased() == "button" {
            guard !ReaderDocumentTree.containsInertHTMLTemplate(in: originalLink) else { continue }
            let baseURI = originalLink.ownerDocument()?.getBaseUri() ?? ""
            let anchor = try Element(Tag.valueOf("a"), baseURI)
            try anchor.attr("class", "reader-view-original")
            try anchor.attr("href", url.absoluteString)
            try anchor.text(ReaderDocumentTree.text(in: originalLink, trimAndNormaliseWhitespace: false))
            try originalLink.replaceWith(anchor)
        } else {
            try originalLink.attr("href", url.absoluteString)
        }
    }
}
