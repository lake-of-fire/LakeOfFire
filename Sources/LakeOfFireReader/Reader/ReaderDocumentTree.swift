import Foundation
import SwiftSoup

/// Reader's document-tree view of SwiftSoup's compatibility DOM. HTML template
/// contents remain API children in SwiftSoup but are a separate browser fragment.
public enum ReaderDocumentTree {
    public static func isInertHTMLTemplate(_ element: Element) -> Bool {
        isInertHTMLTemplate(
            element,
            isXML: element.ownerDocument()?.outputSettings().syntax() == .xml
        )
    }

    private static func isInertHTMLTemplate(_ element: Element, isXML: Bool) -> Bool {
        guard element.namespace() == .html else { return false }
        guard isXML else { return element.tagNameNormal() == "template" }
        // XML element types use the exact local name and namespace. An HTML
        // parser instead treats a colon as part of the ordinary tag name.
        let name = element.tagName()
        let localName = name.firstIndex(of: ":").map { name[name.index(after: $0)...] }
            ?? name[...]
        return localName == "template"
    }

    /// The template element itself belongs to the document; its contents do not.
    /// Foreign SVG/MathML elements named template retain ordinary descendants.
    public static func isInTemplateContents(_ node: Node) -> Bool {
        var ancestor = node.parent()
        while let current = ancestor {
            if let element = current as? Element, isInertHTMLTemplate(element) {
                return true
            }
            ancestor = current.parent()
        }
        return false
    }

    public static func containsInertHTMLTemplate(in root: Node) -> Bool {
        var pending = [root]
        while let node = pending.popLast() {
            if let element = node as? Element, isInertHTMLTemplate(element) {
                return true
            }
            pending.append(contentsOf: node.getChildNodes())
        }
        return false
    }

    /// Match Document.head/body's exact qualified-name and preorder rules,
    /// excluding the separate template-content fragments from that walk.
    public static func firstElement(named name: String, in root: Node) -> Element? {
        guard !isInTemplateContents(root) else { return nil }
        let nameBytes = Array(name.utf8)
        var pending = [root]
        while let node = pending.popLast() {
            if node.nodeNameUTF8() == nameBytes {
                if let element = node as? Element { return element }
                continue
            }
            if let element = node as? Element, isInertHTMLTemplate(element) { continue }
            pending.append(contentsOf: node.getChildNodes().reversed())
        }
        return nil
    }

    /// Preserve SwiftSoup's text normalization without including draft text or
    /// mutating the author DOM. CSS visibility remains the caller's policy.
    public static func text(in root: Element, trimAndNormaliseWhitespace: Bool = true) throws -> String {
        guard !isInertHTMLTemplate(root), !isInTemplateContents(root) else { return "" }
        guard containsInertHTMLTemplate(in: root) else {
            return try root.text(trimAndNormaliseWhitespace: trimAndNormaliseWhitespace)
        }
        guard let copy = try copyExcludingInertHTMLTemplates(root) else { return "" }
        return try copy.text(trimAndNormaliseWhitespace: trimAndNormaliseWhitespace)
    }

    /// Keep the source vocabulary while pruning a detached copy. Its owner
    /// document is unavailable after copying, so capture XML mode first.
    public static func copyExcludingInertHTMLTemplates(_ root: Element) throws -> Element? {
        guard !isInertHTMLTemplate(root), !isInTemplateContents(root) else { return nil }
        let isXML = root.ownerDocument()?.outputSettings().syntax() == .xml
        guard let copy = root.copy() as? Element else { return nil }
        var pending = copy.getChildNodes()
        while let node = pending.popLast() {
            if let element = node as? Element, isInertHTMLTemplate(element, isXML: isXML) {
                try element.remove()
                continue
            }
            pending.append(contentsOf: node.getChildNodes())
        }
        return copy
    }

    public static func title(in document: Document) throws -> String {
        guard let title = try elements(in: document, matching: "title").first else { return "" }
        return StringUtil.normaliseWhitespace(try text(in: title))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Retains SwiftSoup's selector order and inclusion of a matching root.
    public static func elements(in root: Element, matching selector: String) throws -> [Element] {
        try root.select(selector).array().filter { !isInTemplateContents($0) }
    }

    /// App-owned IDs are fixed CSS-safe tokens. Preserve exact ID case and the
    /// first live match, even when that match is itself an inert template.
    public static func elementWithID(_ id: String, in root: Element) throws -> Element? {
        try elements(in: root, matching: "#" + id).first
    }
}

/// Select the first document-tree ID without treating a template element's
/// fragment as a mutable title, style, header, or article container.
internal func readerDocumentElementWithID(_ id: String, in root: Element) throws -> Element? {
    guard let element = try ReaderDocumentTree.elementWithID(id, in: root),
          !ReaderDocumentTree.isInertHTMLTemplate(element) else { return nil }
    return element
}

internal func readerDocumentElements(in root: Element, matching selector: String) throws -> [Element] {
    try ReaderDocumentTree.elements(in: root, matching: selector).filter {
        !ReaderDocumentTree.isInertHTMLTemplate($0)
    }
}

/// Replace the displayed text while retaining author templates and the ancestor
/// elements which own them. The ordinary path retains Element.text's behavior.
internal func replaceReaderDocumentText(_ text: String, in root: Element) throws {
    guard !ReaderDocumentTree.isInertHTMLTemplate(root),
          !ReaderDocumentTree.isInTemplateContents(root) else { return }
    guard ReaderDocumentTree.containsInertHTMLTemplate(in: root) else {
        try root.text(text)
        return
    }
    var protectedNodes = Set<ObjectIdentifier>()
    var pending = root.getChildNodes()
    while let node = pending.popLast() {
        if let element = node as? Element, ReaderDocumentTree.isInertHTMLTemplate(element) {
            var ancestor: Node? = element
            while let current = ancestor, current !== root {
                guard protectedNodes.insert(ObjectIdentifier(current)).inserted else { break }
                ancestor = current.parent()
            }
        } else {
            pending.append(contentsOf: node.getChildNodes())
        }
    }
    pending = root.getChildNodes()
    while let node = pending.popLast() {
        if protectedNodes.contains(ObjectIdentifier(node)) {
            if let element = node as? Element, ReaderDocumentTree.isInertHTMLTemplate(element) { continue }
            pending.append(contentsOf: node.getChildNodes())
        } else {
            try node.remove()
        }
    }
    try root.prependText(text)
}

/// Feed cleanup may discard ordinary live decoration, but must not discard a
/// container which owns an author template fragment.
internal func removeReaderDocumentElement(_ element: Element?) throws {
    guard let element,
          !ReaderDocumentTree.isInTemplateContents(element),
          !ReaderDocumentTree.containsInertHTMLTemplate(in: element) else { return }
    try element.remove()
}
