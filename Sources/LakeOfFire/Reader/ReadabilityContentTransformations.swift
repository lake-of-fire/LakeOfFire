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
    guard let articleTitle = try doc.getElementById("reader-title") else { return }
    try articleTitle.text(articleTitle.text().replace(regex: emptySpaceRegex, template: ""))
    
    // Collapse spaces. /*Remove (※) which reference Matcha vocab definitions that we remove.*/
    guard let articleDiv = try doc.getElementById("reader-content")?.getElementsByClass("page").first() else { return }
    guard let elements = try? articleDiv.getAllElements() else { return }
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
    guard let readerContentElement = try doc.getElementById("reader-content"), let articleDiv = try readerContentElement.getElementsByTag("article").first() else { return }
    
    // Remove the " –freeweb manage ..." title suffix.
    guard let titleElement = try doc.getElementById("reader-title") else { return }
    var title = try titleElement.text()
    if let range = title.range(of: " – free web magazine", options: .backwards) {
        title = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        try titleElement.text(title)
    }
    if let range = title.range(of: ")") {
        title.insert(" ", at: range.upperBound)
        try titleElement.text(title)
    }
    
    // Remove the author header which can remain in the article body, duplicated.
    try readerContentElement.getElementsByTag("header").first()?.remove()
    
    // Remove comments and rest of footer.
    try readerContentElement.getElementById("reply-title")?.parent()?.remove()
    try readerContentElement.getElementById("content-bottom-widget")?.remove()
    try readerContentElement.select("ul > li > p > a").first()?.parent()?.parent()?.parent()?.parent()?.remove()
    
    // Remove "english" (or other language) translation buttons.
    for translationImg in try readerContentElement.select("div span:first-of-type img") {
        // The translation image URLs look like kigoo-en.jpg
        if try !translationImg.attr("src").contains("kigoo-") {
            continue
        }
        
        try translationImg.parent()?.parent()?.remove()
    }
    
    // Un-bold words that had grammar explanations.
    for strong in try readerContentElement.select("span[title] strong") {
        let surface = try strong.text()
        try strong.before(surface)
        try strong.remove()
    }
    
    // Remove broken paragraphs that display code.
    for p in try readerContentElement.getElementsByTag("p") {
        if p.ownText().contains("[label ") {
            try p.remove()
        }
    }
    
    // Mysterious image transform.
//    if let childDivs = try articleDiv.getElementsByTag("div").first()?.children() {
//        for div in childDivs {
//            let imgHtml = try div.getElementsByTag("img").outerHtml()
//            let text = try div.text()
//            try div.text(text) // Don't recall why this was necessary, maybe to deal with the image?
//            try div.prepend(imgHtml)
//        }
//    }
    
    // Collapse spaces and learning markup in the text.
    try articleDiv.getElementsByTag("br").remove()
    for wordWithTipElement in try articleDiv.getElementsByAttribute("data-tipso") {
        try wordWithTipElement.before(wordWithTipElement.ownText())
        try wordWithTipElement.remove()
    }
    
    for element in try articleDiv.getAllElements() {
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
    for p in try doc.getElementsByTag("p") {
        for garbageText in ["次(next)⇒", "つぎ(next)"] {
            if try p.text().contains(garbageText) {
                try p.remove()
                break
            }
        }
    }
    
}

private func hukumusume(doc: Document) throws {
    try doc.getElementsByTag("table").remove()
    
    func removeTranslationOptions(_ tag: Element) throws {
        if try tag.getElementsMatchingText("←").first() != nil && tag.getElementsMatchingText("→").first() != nil {
            // Remove line-breaks preceding the translation options paragraph.
            while true {
                let sibling = try tag.previousElementSibling()
                if (sibling?.tagNameNormal() ?? "") != "br" {
                    break
                }
                try sibling?.remove()
            }
            try tag.remove()
        }
    }
    
    for tag in try doc.getElementsByTag("p") {
        try removeTranslationOptions(tag)
    }
    for tag in try doc.getElementsByTag("font") {
        try removeTranslationOptions(tag)
    }
    for tag in try doc.getElementsByAttributeValue("href", "javascript:history.back();") {
        try tag.remove()
    }
    
    // Remove useless spacer.gif
    for img in try doc.getElementsByTag("img") {
        if let src = try? img.attr("src"), src.hasSuffix("/spacer.gif") {
            try img.remove()
        }
    }
    
    // Remove empty paragraphs.
    for p in try doc.getElementsByTag("p") {
        if !p.hasText() && !p.hasChildNodes() {
            try p.remove()
        }
    }
    
    // Remove <br> at start or end of paragraph nodes.
    for br in try doc.getElementsByTag("br") {
        if let parent = br.parent(), parent.tagNameNormalUTF8() == UTF8Arrays.p && (br.previousSibling() == nil || !br.hasNextSibling()) {
            try br.remove()
        }
    }
    
    // Remove breadcrumb nav at top.
    for p in try doc.getElementsByTag("p") {
        if try p.text().contains(" > ") {
            let anchors = try p.getElementsByTag("a")
            if anchors.first() == nil {
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
                try p.remove()
                break
            }
        }
    }
}

private func hiraganaTimes(doc: Document) throws {
    try doc.getElementById("reader-content")?.getElementsByTag("p").first()?.remove()
}

private func cnn(doc: Document) throws {
    guard let titleElement = try doc.getElementById("reader-title") else { return }
    let title = try titleElement.text()
    if let range = title.range(of: "CNN.co.jp : ") {
        try titleElement.text(title[range.upperBound...].trimmingCharacters(in: .whitespaces))
    }
}

private func slowCommunication(doc: Document) throws {
    guard let pageElement = try doc.getElementById("reader-content")?.getElementsByClass("page").first() else { return }
    
    // Remove date and tag which get interpreted as an article paragraph.
//    guard let dateAndTagElement = try pageElement.getElementsByTag("p").first() else { return }
//    try dateAndTagElement.remove()
    
    // Remove the inline audio.
    if let inlineAudioElement = try pageElement.getElementsByTag("article").first()?.getElementsByTag("audio").first() {
        try inlineAudioElement.remove()
    }
    
    // Remove the audio credit, which is confusing in our UI.
    for p in try doc.getElementsByTag("p") {
        if try p.text().hasPrefix("(音声") {
            try p.remove()
            break
        }
    }
    
    // Remove the line-breaks within the article that they add for readability but which screw with our sentence detection.
    for br in try doc.getElementsByTag("br") {
        try br.remove()
    }
}

private func nhk(doc: Document) throws {
    guard let pageElement = try doc.getElementById("reader-content")?.getElementsByClass("page").first() else { return }
    
    // Un-link words that have NHK popup dictionaries.
    for wordLink in try pageElement.select("a.dicWin") {
        if let word = try wordLink.select("span.under").first()?.ownText() {
            try wordLink.before(word)
            try wordLink.remove()
        }
    }
}

private func hypebeast(doc: Document) throws {
    guard let pageElement = try doc.getElementById("reader-content")?.getElementsByClass("page").first() else { return }
    
    // Remove the "『HYPEBEAST』がお届けするその他最新のファッション情報もお見逃しなく。" footer from articles.
    for p in try pageElement.getElementsByTag("p") {
        if p.ownText() == "『HYPEBEAST』がお届けするもお見逃しなく。" {
            try p.remove()
        }
    }
    
    // Remove "What To Read Next" footer
    try doc.getElementById("post-feed")?.remove()
}

public func fixAnnoyingTitlesWithPipes(doc: Document) throws {
    guard let titleElement = try doc.getElementById("reader-title") else { return }
    let textNodes = try titleElement.textNodes()
    for node in textNodes {
        let original = node.getWholeText()
        let updated = fixAnnoyingTitlesWithPipes(title: original)
        node.text(updated)
    }
}

public func fixAnnoyingTitlesWithPipes(title: String) -> String {
    guard let range = title.range(of: "|", options: .backwards) else { return title }
    let beforeText = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    let afterText = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    if containsCJKCharacters(text: afterText) {
        return afterText
    } else {
        return beforeText
    }
}

public func wireViewOriginalLinks(doc: Document, url: URL) throws {
    let originalLinks = try doc.getElementsByClass("reader-view-original")
    try originalLinks.attr("href", url.absoluteString)
}
