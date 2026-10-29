import Foundation
import SwiftSoup
import LakeOfFireCore
import LakeOfFireContent

/// Final presentation preparation operates on a transient document. Canonical
/// HTML is stored earlier, with source URLs and without these registrations.
func prepareReaderOwnedDocument(
    _ doc: SwiftSoup.Document,
    sourceURL: URL,
    generation: UUID
) throws -> ReaderDocumentPresentation {
    let span = ReaderLoadTrace.begin("reader.documentPreparation")
    var outcome = "status=failed stage=normalization"
    defer { span?.end(outcome) }
    let presentation = ReaderDocumentPresentation(sourceURL: sourceURL, generation: generation)
    do {
        try normalizeReaderDocumentResourceURLs(in: doc, sourceURL: sourceURL)
        outcome = "status=failed stage=components"
        try prepareReaderComponents(in: doc, presentation: presentation, nested: false, depth: 0)
        outcome = "status=prepared"
        return presentation
    } catch {
        presentation.release()
        recordReaderRenderFailure(error, phase: .documentPreparation)
        throw error
    }
}

private func prepareReaderComponents(in doc: SwiftSoup.Document, presentation: ReaderDocumentPresentation, nested: Bool, depth: Int, inheritedReferrerPolicy: String? = nil) throws {
    let documentPolicy = try readerDocumentReferrerPolicy(in: doc) ?? inheritedReferrerPolicy
    let headlineGeometry = ReaderImageGeometry.metadata(in: doc, sourceURL: presentation.sourceURL)
    let root = try doc.getElementById("reader-content") ?? doc.body() ?? doc
    try sanitizeReaderRetainedContent(root)
    if !nested { try replaceReaderDocumentExecutableShell(in: doc) }
    for image in try doc.select("img") {
        try image.removeAttr("data-mnb-source-url")
        try image.removeAttr("data-mnb-image-layout")
    }
    var embeds = [[String: String]]()
    var media = [[String: String]]()
    var assets: [String: String] = [:]
    func imageURL(_ raw: String, symbol: Bool = false, referrerPolicy: String? = nil, crossOrigin: String? = nil) throws -> String {
        guard let source = URL(string: raw) else { return "" }
        if source.scheme == "data" {
            let allowed = ["data:image/png;", "data:image/jpeg;", "data:image/gif;", "data:image/webp;", "data:image/avif;", "data:image/svg+xml;"]
            let prefix = raw.prefix(48).lowercased()
            return raw.utf8.count <= 8 * 1_024 * 1_024 && allowed.contains(where: { prefix.hasPrefix($0) }) ? raw : ""
        }
        guard source.isHTTP, source.user == nil, source.password == nil else { return "" }
        let anonymous = crossOrigin != nil && crossOrigin?.lowercased() != "use-credentials"
        let sameOrigin = readerResourceHasSameOrigin(source, presentation.sourceURL)
        let allowsCookies = !anonymous || sameOrigin
        let referrerPolicy = normalizedReaderReferrerPolicy(referrerPolicy) ?? documentPolicy
        let key = (symbol ? "symbol:" : "image:") + (referrerPolicy ?? "") + ":\(allowsCookies):" + source.absoluteString
        let id: String
        if let existing = assets[key] { id = existing }
        else {
            guard let registered = try? presentation.register(symbol ? .svgSymbol(source) : .image(source), referrerPolicy: referrerPolicy, allowsCookies: allowsCookies) else { return "" }
            id = registered
            assets[key] = id
        }
        var result = nested ? "/asset/" + id : readerRegisteredResourceURL(id).absoluteString
        if !symbol, let fragment = URLComponents(url: source, resolvingAgainstBaseURL: false)?.percentEncodedFragment { result += "#" + fragment }
        return result
    }
    // Generated header images are resources too; sanitize publisher content
    // separately so trusted Reader scripts outside it remain intact.
    for element in try (doc.body() ?? root).getAllElements() {
        let tag = element.tagName().lowercased()
        for attribute in element.getAttributes()?.asList() ?? [] {
            let name = attribute.getKey().lowercased()
            if name.hasPrefix("on") || ["href", "src", "xlink:href", "data"].contains(name) && readerURLIsExecutable(attribute.getValue()) {
                try element.removeAttr(attribute.getKey())
            }
        }
        if element !== doc.body(), element.hasAttr("style") {
            let graphic = try preserveReaderGraphicPresentation(in: element)
            try element.removeAttr("style")
            if !graphic.isEmpty { try element.attr("style", graphic) }
        }
        if ["img", "source"].contains(tag), tag == "img" || element.parent()?.tagName() == "picture" {
            let ownerImage = tag == "source" ? try element.parent()?.select("img").first() : element
            let referrerPolicy = try ownerImage?.attr("referrerpolicy")
            let crossOrigin = ownerImage?.hasAttr("crossorigin") == true ? try ownerImage?.attr("crossorigin") : nil
            let lazySources = ["data-src", "data-original", "data-lazy-src", "data-url", "data-flickity-lazyload-src", "data-flickity-lazyload"]
            let originalSource = try element.attr("src")
            var selectedSource = originalSource
            for attr in lazySources where element.hasAttr(attr) {
                let raw = try element.attr(attr)
                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectedSource = raw
                    break
                }
            }
            if tag == "img" {
                // Associate dimensions with the selected publisher resource
                // before registration replaces it with a presentation URL.
                try applyReaderSelectedImageGeometry(element, originalSource: originalSource,
                    selectedSource: selectedSource, headlineGeometry: headlineGeometry)
            }
            if !selectedSource.isEmpty {
                if tag == "img", let original = URL(string: selectedSource), original.isHTTP,
                   original.user == nil, original.password == nil {
                    try element.attr("data-mnb-source-url", original.absoluteString)
                }
                try element.attr("src", imageURL(selectedSource, referrerPolicy: referrerPolicy, crossOrigin: crossOrigin))
                if selectedSource.lowercased().hasPrefix("blob:") {
                    try appendReaderSourceLink(after: element, url: presentation.sourceURL, document: doc, label: "View unavailable image in the original article")
                }
            }
            for attr in lazySources where element.hasAttr(attr) { try element.removeAttr(attr) }
            let lazySets = ["data-srcset", "data-lazy-srcset", "data-flickity-lazyload-srcset"]
            var selectedSet = try element.attr("srcset")
            for attr in lazySets where element.hasAttr(attr) {
                let raw = try element.attr(attr)
                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { selectedSet = raw; break }
            }
            if !selectedSet.isEmpty { try element.attr("srcset", readerResolvedSrcset(selectedSet, resolve: { try imageURL($0, referrerPolicy: referrerPolicy, crossOrigin: crossOrigin) })) }
            for attr in lazySets where element.hasAttr(attr) { try element.removeAttr(attr) }
            if tag == "img" { try prepareReaderImageGeometry(element) }
            // Responsive candidates remain candidates. WebKit chooses one;
            // preparation does not download every resolution.
            if tag == "img", !(try element.attr("src")).hasPrefix("internal:"), !(try element.attr("src")).hasPrefix("/asset/"), !(try element.attr("src")).hasPrefix("data:") {
                try element.removeAttr("src")
            }
        }
        if tag == "video", element.hasAttr("poster") { try element.attr("poster", imageURL(try element.attr("poster"))) }
        if ["image", "feimage"].contains(tag) {
            for attr in ["href", "xlink:href"] where element.hasAttr(attr) {
                let value = try element.attr(attr)
                if !value.hasPrefix("#") { try element.attr(attr, imageURL(value)) }
            }
        }
        if tag == "use" {
            let raw = try element.hasAttr("href") ? element.attr("href") : element.attr("xlink:href")
            if !raw.isEmpty, !raw.hasPrefix("#"), URL(string: raw)?.isHTTP == true {
                let image = try doc.createElement("image")
                // Replacing an external use changes the resource boundary, not
                // its placement or compositing in the surrounding diagram.
                // Resource-bearing effects have already been limited to local
                // fragment references by preserveReaderGraphicPresentation.
                for attr in ["id", "x", "y", "width", "height", "preserveAspectRatio", "aria-label",
                             "transform", "opacity", "clip-path", "mask", "filter", "visibility", "display"] where element.hasAttr(attr) {
                    try image.attr(attr, element.attr(attr))
                }
                try image.attr("href", imageURL(raw, symbol: true))
                try element.before(image)
                try element.remove()
            }
        }
        if tag == "track", let url = URL(string: try element.attr("src")), url.isHTTP {
            let parent = element.parent()
            let crossOrigin = parent?.hasAttr("crossorigin") == true ? try parent?.attr("crossorigin") : "anonymous"
            let sameOrigin = readerResourceHasSameOrigin(url, presentation.sourceURL)
            let allowsCookies = crossOrigin?.lowercased() == "use-credentials" || sameOrigin
            if let id = try? presentation.register(.caption(url), referrerPolicy: documentPolicy, allowsCookies: allowsCookies) {
                try element.attr("src", nested ? "/asset/" + id : readerRegisteredResourceURL(id).absoluteString)
            } else {
                try element.removeAttr("src")
                try appendReaderSourceLink(after: element.parent() ?? element, url: url, document: doc, label: "Open captions")
            }
        }
        // Audio/video keep their real source URLs, source ordering and author
        // CORS settings. Adaptive streams retain their complete dependency
        // graph. No partial manifest rewriting or native audio changes.
        if ["audio", "video", "source", "track"].contains(tag), !(try element.attr("src")).isEmpty,
           (try element.attr("src")).lowercased().hasPrefix("blob:") {
            try element.removeAttr("src")
            try appendReaderSourceLink(after: element.parent() ?? element, url: presentation.sourceURL, document: doc, label: "View unavailable media in the original article")
        }
        if ["audio", "video"].contains(tag) {
            let candidates = [try element.attr("src")] + (try element.select("source[src]").array().map { try $0.attr("src") })
            let remote = candidates.compactMap(URL.init(string:)).first { $0.isHTTP && $0.user == nil && $0.password == nil }
            if let remote, let id = try? presentation.register(.remoteMedia(remote)) {
                let elementID = "mnb-media-" + id
                try preserveReaderFragmentAnchor(before: element, document: doc)
                try element.attr("id", elementID)
                media.append(["element": elementID, "registration": id])
            }
            // This source action remains useful even before playback is
            // requested, when offline, or when a provider requires credentials.
            try appendReaderSourceLink(after: element, url: remote ?? presentation.sourceURL, document: doc, label: "Open media source")
        }
        if tag == "canvas" {
            try preserveReaderFragmentAnchor(before: element, document: doc)
            try appendReaderSourceLink(after: element, url: presentation.sourceURL, document: doc, label: "View the interactive graphic in the original article")
            try element.unwrap()
        }
        if tag == "iframe" {
            try preserveReaderFragmentAnchor(before: element, document: doc)
            let id: String?
            if element.hasAttr("srcdoc"), depth < 3 {
                let html = try element.attr("srcdoc")
                if html.utf8.count <= 512 * 1_024 {
                    let child = try SwiftSoup.parse(html)
                    try child.select("head script, head style, head link, head meta[http-equiv]").remove()
                    try prepareReaderComponents(in: child, presentation: presentation, nested: true, depth: depth + 1, inheritedReferrerPolicy: documentPolicy)
                    id = try? presentation.register(.inlineHTML(child.outerHtml()))
                } else { id = nil }
            } else {
                var raw = try element.attr("src")
                if raw.isEmpty {
                    // These are explicit lazy iframe source attributes.
                    // Arbitrary data-url attributes remain inert.
                    for attr in ["data-src", "data-lazy-src"] where raw.isEmpty { raw = try element.attr(attr) }
                }
                if depth < 3, let html = readerDataHTML(raw) {
                    let child = try SwiftSoup.parse(html, presentation.sourceURL.absoluteString)
                    try normalizeReaderDocumentResourceURLs(in: child, sourceURL: presentation.sourceURL)
                    try child.select("head script, head style, head link, head meta[http-equiv]").remove()
                    try prepareReaderComponents(in: child, presentation: presentation, nested: true, depth: depth + 1, inheritedReferrerPolicy: documentPolicy)
                    id = try? presentation.register(.inlineHTML(child.outerHtml()))
                } else if let url = URL(string: raw), url.isHTTP, url.user == nil, url.password == nil {
                    id = try? presentation.register(.remoteHTML(url,
                        permissions: readerEmbedPermissions(try element.attr("allow")),
                        sandbox: readerEmbedSandbox(element.hasAttr("sandbox") ? try element.attr("sandbox") : nil),
                        referrerPolicy: normalizedReaderReferrerPolicy(try element.attr("referrerpolicy")) ?? documentPolicy))
                    try appendReaderSourceLink(after: element, url: url, document: doc, label: "Open embedded content")
                } else { id = nil }
            }
            try element.removeAttr("srcdoc")
            for attr in ["src", "data-src", "data-lazy-src", "data-url"] { try element.removeAttr(attr) }
            if let id {
                let elementID = "mnb-embed-" + id
                try element.attr("id", elementID)
                // Provider restrictions apply to the provider, not the trusted
                // HTTP shell. An opaque wrapper could not authenticate its port.
                if let entry = ReaderDocumentResourceRegistry.shared.entry(for: id), case .remoteHTML = entry.resource {
                    try element.removeAttr("sandbox")
                    try element.attr("allow", readerEmbedPermissions(""))
                } else {
                    try element.attr("allow", readerEmbedPermissions(try element.attr("allow")))
                }
                try element.attr("allowfullscreen", "")
                try element.attr("title", (try element.attr("title")).isEmpty ? "Embedded content" : element.attr("title"))
                // The bundled bootstrap resolves the server independently.
                // Article readiness never awaits this fetch or frame load.
                embeds.append(["element": elementID, "registration": id,
                    "resolve": nested ? "/resolve/" + id : readerRegisteredResourceURL(id, resolveEmbed: true).absoluteString])
            } else {
                try appendReaderSourceLink(after: element, url: presentation.sourceURL, document: doc, label: "View unavailable embedded content in the original article")
                try element.remove()
            }
        }
        if ["object", "embed"].contains(tag) {
            try preserveReaderFragmentAnchor(before: element, document: doc)
            let raw = try element.attr(tag == "object" ? "data" : "src")
            guard let url = URL(string: raw), url.isHTTP else { try element.removeAttr("src"); try element.removeAttr("data"); continue }
            let type = try element.attr("type").lowercased().split(separator: ";").first.map(String.init) ?? ""
            if type.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif"].contains(url.pathExtension.lowercased()) {
                let image = try doc.createElement("img")
                try image.attr("src", imageURL(raw)); try image.attr("alt", element.attr("title"))
                for attr in ["width", "height"] where element.hasAttr(attr) { try image.attr(attr, element.attr(attr)) }
                try element.before(image)
            } else if ["text/html", "application/xhtml+xml"].contains(type) || ["html", "htm"].contains(url.pathExtension.lowercased()) {
                if let id = try? presentation.register(.remoteHTML(url, permissions: readerEmbedPermissions(""), sandbox: readerEmbedSandbox(nil), referrerPolicy: documentPolicy)) {
                let frame = try doc.createElement("iframe")
                let elementID = "mnb-embed-" + id
                try frame.attr("id", elementID); try frame.attr("title", "Embedded content")
                try frame.attr("allow", readerEmbedPermissions("")); try frame.attr("allowfullscreen", "")
                for attr in ["width", "height"] where element.hasAttr(attr) { try frame.attr(attr, element.attr(attr)) }
                try element.before(frame)
                embeds.append(["element": elementID, "registration": id,
                    "resolve": nested ? "/resolve/" + id : readerRegisteredResourceURL(id, resolveEmbed: true).absoluteString])
                }
            }
            try appendReaderSourceLink(after: element, url: url, document: doc,
                label: type == "application/pdf" || url.pathExtension.lowercased() == "pdf" ? "Open PDF document" : "Open attached content")
            // Keep author fallback nodes, including meaningful labels.
            if tag == "object" { try element.unwrap() } else { try element.remove() }
        }
    }
    guard !embeds.isEmpty || !media.isEmpty else { return }
    let config = try doc.createElement("script")
    try config.attr("type", "application/json"); try config.attr("id", "mnb-reader-components")
    let json = String(decoding: try JSONSerialization.data(withJSONObject: ["generation": presentation.generation.uuidString, "embeds": embeds, "media": media]), as: UTF8.self)
        .replacingOccurrences(of: "<", with: "\\u003c")
    try config.appendChild(DataNode(Array(json.utf8), doc.getBaseUriUTF8()))
    try (doc.body() ?? doc).appendChild(config)
    let bootstrap = try doc.createElement("script")
    try bootstrap.attr("src", nested ? "/reader-components.js" : "internal://local/reader-components.js")
    try bootstrap.attr("defer", "")
    try (doc.head() ?? doc).appendChild(bootstrap)
}

/// Cached canonical-looking markup is still content, not executable authority.
/// Recreate shell code from the bundle instead of trusting tags or IDs saved in
/// a feed, import, or older cache. Native sidecars are appended after this step.
private func replaceReaderDocumentExecutableShell(in doc: SwiftSoup.Document) throws {
    try doc.select("script, style, link, meta[http-equiv], animate, animateTransform, animateMotion, set, mpath").remove()
    for element in [try doc.select("html").first(), doc.head()].compactMap({ $0 }) {
        for attribute in element.getAttributes()?.asList() ?? [] where attribute.getKey().lowercased().hasPrefix("on") || attribute.getKey().lowercased() == "style" {
            try element.removeAttr(attribute.getKey())
        }
    }
    for shell in try doc.select("html, head, body, #reader-content") {
        for attribute in ["hidden", "inert", "aria-hidden", "contenteditable", "background", "bgcolor"] { try shell.removeAttr(attribute) }
    }
    if let body = doc.body() {
        let fontSize = readerStoredFontSize() ?? 21
        let existingStyle = try body.attr("style")
        var properties = ["font-size": "\(fontSize)px"]
        for declaration in existingStyle.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if ["font-size", "--mnb-reader-content-font-size", "--mnb-reader-content-rt-size"].contains(name),
               value.range(of: #"^[0-9]+(?:\.[0-9]+)?px$"#, options: .regularExpression) != nil {
                properties[name] = value
            }
            if name == "font-weight", ["normal", "bold", "100", "200", "300", "400", "500", "600", "700", "800", "900"].contains(value) { properties[name] = value }
            if ["--mnb-content-font", "--mnb-content-vertical-font"].contains(name),
               !value.isEmpty, value.utf8.count <= 256,
               value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "'\" ,-_".unicodeScalars.contains($0) }) {
                properties[name] = value
            }
        }
        let safeStyle = properties.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value);" }.joined()
        try body.attr("style", safeStyle + readerAdaptiveMaxWidthStyleDeclaration(readerFontSize: fontSize))
    }
    let style = try doc.createElement("style")
    try style.attr("id", "swiftuiwebview-readability-styles")
    let css = Readability.shared.css + "\n" + readerDocumentCanvasCSS() + "\n" + """
    body.\(ReaderContentLoader.snippetReaderTitleSuppressionBodyClass) #reader-title { display:none!important; }
    body[data-mnb-mark-read-buttons-visible='false'] .mnb-mark-section-as-read-button,
    body[data-is-ebook='true'][data-mnb-lookup-popover-presented='true'] .mnb-mark-section-as-read-button { display:none!important;pointer-events:none!important; }
    """
    try style.appendChild(DataNode(Array(css.utf8), doc.getBaseUriUTF8()))
    try (doc.head() ?? doc).appendChild(style)
    let script = try doc.createElement("script")
    try script.attr("id", "mnb-trusted-readability-shell")
    try script.appendChild(DataNode(Array(Readability.shared.scripts.utf8), doc.getBaseUriUTF8()))
    try (doc.body() ?? doc).appendChild(script)
}

func readerEmbedPermissions(_ author: String) -> String {
    var directives = author.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    for name in ["autoplay", "fullscreen", "picture-in-picture", "encrypted-media"] {
        if !directives.contains(where: { $0.split(separator: " ").first == Substring(name) }) { directives.append(name) }
    }
    return directives.joined(separator: "; ")
}

func readerEmbedSandbox(_ author: String?) -> String {
    guard let author else {
        // Keep the real provider origin and script execution. Browser user
        // activation, rather than navigationType alone, gates top replacement.
        return "allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox allow-presentation allow-downloads allow-orientation-lock allow-storage-access-by-user-activation allow-top-navigation-by-user-activation"
    }
    var tokens = author.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
    if tokens.contains("allow-top-navigation") {
        tokens.removeAll { $0 == "allow-top-navigation" }
        if !tokens.contains("allow-top-navigation-by-user-activation") { tokens.append("allow-top-navigation-by-user-activation") }
    }
    tokens.removeAll { $0 == "allow-top-navigation-to-custom-protocols" }
    return tokens.joined(separator: " ")
}

private func preserveReaderFragmentAnchor(before element: Element, document: SwiftSoup.Document) throws {
    let identifier = try element.attr("id")
    guard !identifier.isEmpty else { return }
    let anchor = try document.createElement("span")
    try anchor.attr("id", identifier)
    try anchor.attr("aria-hidden", "true")
    try element.before(anchor)
    try element.removeAttr("id")
}

private func appendReaderSourceLink(after element: Element, url: URL, document: SwiftSoup.Document, label: String) throws {
    let link = try document.createElement("a")
    try link.attr("href", url.absoluteString); try link.attr("class", "mnb-embedded-source")
    try link.text(label)
    do {
        try element.after(link)
    } catch {
        // Only structural state; tag names/attributes may be publisher data.
        ReaderLoadTrace.event("readerMode.renderFailed", "phase=sourceLink attached=\(element.parent() != nil) sibling=\(element.siblingIndex) siblings=\(element.parent()?.childNodeSize() ?? 0)")
        throw error
    }
}

private func sanitizeReaderRetainedContent(_ root: Element) throws {
    try root.select("script, style, link, base, meta[http-equiv], animate, animateTransform, animateMotion, set, mpath").remove()
    for form in try root.select("form") { try form.unwrap() }
    for element in try root.getAllElements() {
        let mediaLayout = try preserveReaderGraphicPresentation(in: element)
        for attribute in element.getAttributes()?.asList() ?? [] {
            let name = attribute.getKey().lowercased()
            if name.hasPrefix("on") || ["style", "action", "formaction"].contains(name) || name == "srcdoc" && element.tagName() != "iframe"
                || ["src", "href", "xlink:href", "data", "poster"].contains(name) && readerURLIsExecutable(attribute.getValue()) {
                try element.removeAttr(attribute.getKey())
            }
        }
        if !mediaLayout.isEmpty { try element.attr("style", mediaLayout) }
    }
}

private func readerURLIsExecutable(_ value: String) -> Bool {
    // HTML URL parsing ignores ASCII tab/newline characters even within the
    // scheme. Entity decoding has already happened in the structured parser.
    let normalized = String(value.unicodeScalars.filter { $0.value > 0x20 }).lowercased()
    return normalized.hasPrefix("javascript:") || normalized.hasPrefix("vbscript:")
}

private func readerImageHasResponsiveSources(_ image: Element) -> Bool {
    let responsiveAttributes = ["srcset", "data-srcset", "data-lazy-srcset", "data-flickity-lazyload-srcset"]
    return responsiveAttributes.contains { image.hasAttr($0) }
        || image.parents().contains { $0.tagName() == "picture" }
}

/// Geometry belongs to the resolved source, never its discarded placeholder.
func applyReaderSelectedImageGeometry(_ image: Element, originalSource: String,
                                     selectedSource: String, headlineGeometry: ReaderImageGeometry?) throws {
    let geometry = headlineGeometry.flatMap { candidate in
        URL(string: selectedSource) == candidate.url && !readerImageHasResponsiveSources(image) ? candidate : nil
    }
    if selectedSource != originalSource || geometry != nil {
        // Even known real-image dimensions cannot inherit a placeholder's
        // max-height, max-width or aspect-ratio constraints.
        try image.removeAttr("style")
    }
    if let geometry {
        try image.attr("width", String(geometry.width))
        try image.attr("height", String(geometry.height))
    } else if selectedSource != originalSource {
        // The old box may describe a 1x1 placeholder. Unknown geometry follows
        // ordinary load/error/deadline handling, never an enforced stale ratio.
        try image.removeAttr("width")
        try image.removeAttr("height")
    }
}

/// Fix geometry before bytes arrive. Responsive pictures retain their existing
/// source-selection/load policy; unknown sources receive no fixed-layout marker.
@discardableResult
func prepareReaderImageGeometry(_ image: Element) throws -> Element {
    guard !readerImageHasResponsiveSources(image),
          let width = Int(try image.attr("width")), let height = Int(try image.attr("height")),
          ReaderImageGeometry.validDimensions(width: width, height: height),
          !(try image.attr("src")).isEmpty else { return image }
    // WebKit can ignore even an explicit image height after decode failure.
    // A non-replaced box owns geometry independently of the image's state.
    // Keep the original image (including links, IDs, maps and alternatives).
    let box: Element
    if let parent = image.parent(), parent.tagName() == "span",
       try parent.attr("data-mnb-image-box") == "fixed", parent.children().size() == 1 {
        box = parent
    } else {
        box = try Element(Tag.valueOf("span"), image.ownerDocument()?.getBaseUri() ?? "")
        try box.attr("data-mnb-image-box", "fixed")
        if image.parent() != nil { try image.before(box) }
        try box.appendChild(image)
    }
    try box.attr("style", "--mnb-image-width:\(width)px;--mnb-image-ratio:\(width)/\(height)")
    try image.attr("data-mnb-image-layout", "fixed")
    return box
}

private func readerDataHTML(_ value: String) -> String? {
    guard value.utf8.count <= 768 * 1_024, let comma = value.firstIndex(of: ",") else { return nil }
    let header = value[..<comma].lowercased()
    guard ["data:text/html", "data:text/html;charset=utf-8", "data:text/html;base64", "data:text/html;charset=utf-8;base64"].contains(header) else { return nil }
    let content = String(value[value.index(after: comma)...])
    let html: String?
    if header.hasSuffix(";base64") { html = Data(base64Encoded: content).flatMap { String(data: $0, encoding: .utf8) } }
    else { html = content.removingPercentEncoding }
    guard let html, html.utf8.count <= 512 * 1_024 else { return nil }
    return html
}

/// Retain graphic presentation without publisher CSS applications or external
/// CSS resource loads. Media layout accepts only literal lengths and ratios.
@discardableResult
func preserveReaderGraphicPresentation(in element: Element) throws -> String {
    let graphicReferences = ["fill", "stroke", "clip-path", "mask", "filter", "marker-start", "marker-mid", "marker-end"]
    guard element.hasAttr("style") || graphicReferences.contains(where: { element.hasAttr($0) }) else { return "" }
    let tag = element.tagName().lowercased()
    let media = ["img", "iframe", "video", "object", "embed"].contains(tag)
    let svg = tag == "svg" || element.parents().contains(where: { $0.tagName().lowercased() == "svg" })
    guard svg || media else { return "" }
    let style = try element.attr("style")
    guard style.utf8.count <= 8_192 else { return "" }
    let names: Set<String> = ["fill", "stroke", "stroke-width", "opacity", "fill-opacity", "stroke-opacity", "clip-path", "mask", "filter", "font-size", "font-family", "text-anchor"]
    var layout = [String]()
    for declaration in style.split(separator: ";") {
        guard let colon = declaration.firstIndex(of: ":") else { continue }
        let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if svg, names.contains(name), value.range(of: #"^(?:[A-Za-z][A-Za-z ]*|#[a-fA-F0-9]{3,8}|[0-9.]+(?:px|em|%)?|rgba?\([0-9.,% ]+\)|url\(#[\w:-]+\))$"#, options: .regularExpression) != nil { try element.attr(name, value) }
        if media {
            if ["width", "height", "max-width", "max-height"].contains(name), value.range(of: #"^[0-9]+(?:\.[0-9]+)?(?:px|%|em|rem|vw|vh)?$"#, options: .regularExpression) != nil { layout.append(name + ":" + value) }
            if name == "aspect-ratio", value.range(of: #"^[0-9]+(?:\.[0-9]+)?\s*/\s*[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil { layout.append(name + ":" + value) }
        }
    }
    if svg {
        for name in graphicReferences where element.hasAttr(name) {
            let value = try element.attr(name)
            if value.lowercased().contains("url("), value.range(of: #"^url\(#[\w:-]+\)$"#, options: .regularExpression) == nil { try element.removeAttr(name) }
        }
    }
    return layout.joined(separator: ";")
}

/// Resolve the effective base before removing it. SVG xml:base scopes are
/// inherited, so resolving every attribute against the article alone is wrong.
func normalizeReaderDocumentResourceURLs(in doc: SwiftSoup.Document, sourceURL: URL) throws {
    try normalizeReaderDocumentResourceURLs(in: doc, sourceURL: sourceURL, depth: 0)
}

private func normalizeReaderDocumentResourceURLs(in doc: SwiftSoup.Document, sourceURL: URL, depth: Int) throws {
    let declaredBase = try doc.select("base[href]").first()?.attr("href")
    let base = declaredBase.flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL } ?? sourceURL
    // Expand useful publisher fallbacks before resolving their URLs against
    // the still-available base. Avoid duplicating adjacent promoted images.
    for alternative in try doc.select("noscript").array() {
        let fallback = try SwiftSoup.parseBodyFragment(alternative.html(), base.absoluteString)
        let previous = try alternative.previousElementSibling()
        let children = fallback.body()?.children().array() ?? []
        let imageOnly = !children.isEmpty && children.allSatisfy { ["img", "picture"].contains($0.tagName().lowercased()) }
        var duplicatesPrevious = false
        if imageOnly, let previous, ["img", "picture"].contains(previous.tagName().lowercased()) {
            let fallbackSources = try readerImageSources(in: children, relativeTo: base)
            let previousSources = try readerImageSources(in: [previous], relativeTo: base)
            duplicatesPrevious = !fallbackSources.isEmpty && fallbackSources.isSubset(of: previousSources)
        }
        if duplicatesPrevious { try alternative.remove() }
        else { try alternative.before(alternative.html()); try alternative.remove() }
    }
    let elements = try doc.getAllElements()
    for element in elements {
        let tag = element.tagName().lowercased()
        guard ["img", "source", "iframe", "image", "use", "feimage", "a", "area", "object"].contains(tag)
            || element.hasAttr("src") || element.hasAttr("poster") || element.hasAttr("srcset") else { continue }
        var scopedBase = base
        for ancestor in Array(element.parents()).reversed() + [element] {
            if let value = try? ancestor.attr("xml:base"), !value.isEmpty,
               let resolved = URL(string: value, relativeTo: scopedBase)?.absoluteURL {
                scopedBase = resolved
            }
        }
        func absolute(_ raw: String) -> String {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return raw }
            if readerURLIsExecutable(value) { return "" }
            if value.lowercased().hasPrefix("data:") || value.lowercased().hasPrefix("blob:") { return value }
            return URL(string: value, relativeTo: scopedBase)?.absoluteURL.absoluteString ?? raw
        }
        let lazy = ["img", "source", "iframe"].contains(tag)
        var attributes = ["src", "poster"]
        if tag == "object" { attributes.append("data") }
        if ["a", "area", "image", "use", "feimage"].contains(tag) { attributes += ["href", "xlink:href"] }
        if lazy {
            attributes += ["data-src", "data-original", "data-lazy-src", "data-flickity-lazyload-src", "data-flickity-lazyload"]
            // data-url is a common image source, but is never an instruction
            // to execute a remote iframe application.
            if tag != "iframe" { attributes.append("data-url") }
        }
        for attribute in attributes where element.hasAttr(attribute) {
            let value = try element.attr(attribute)
            let svgLocal = ["image", "use", "feimage"].contains(tag) && value.hasPrefix("#")
            if svgLocal { continue }
            let resolved = absolute(value)
            if ["a", "area"].contains(tag), attribute == "href",
               !(try element.hasClass("reader-view-original")),
               let target = URL(string: resolved),
               let fragment = URLComponents(url: target, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
               target.removingFragmentIfNeeded() == sourceURL.removingFragmentIfNeeded() {
                try element.attr(attribute, "#" + fragment)
            } else {
                try element.attr(attribute, resolved)
            }
        }
        for attribute in ["srcset", "data-srcset", "data-lazy-srcset", "data-flickity-lazyload-srcset"] where element.hasAttr(attribute) {
            try element.attr(attribute, readerResolvedSrcset(try element.attr(attribute), resolve: absolute))
        }
        if tag == "iframe", (try element.attr("src")).isEmpty {
            for attribute in ["data-src", "data-lazy-src"] {
                if let url = URL(string: try element.attr(attribute)), url.isHTTP {
                    try element.attr("src", url.absoluteString)
                    break
                }
            }
        }
        if tag == "iframe", element.hasAttr("srcdoc") {
            let html = try element.attr("srcdoc")
            guard depth < 3, html.utf8.count <= 512 * 1_024 else {
                try element.removeAttr("srcdoc")
                try element.removeAttr("src")
                continue
            }
            let child = try SwiftSoup.parse(html, scopedBase.absoluteString)
            try normalizeReaderDocumentResourceURLs(in: child, sourceURL: scopedBase, depth: depth + 1)
            try element.attr("srcdoc", child.outerHtml())
        }
    }
    try doc.select("base").remove()
    for element in elements where element.hasAttr("xml:base") { try element.removeAttr("xml:base") }
}

/// Adjacent image markup is not necessarily the noscript image: it may be an
/// empty lazy placeholder, a tracking pixel, or another illustration entirely.
/// Suppress the fallback only when its sources are already represented.
private func readerImageSources(in roots: [Element], relativeTo base: URL) throws -> Set<String> {
    var sources = Set<String>()
    for root in roots {
        for element in try root.getAllElements() where ["img", "source"].contains(element.tagName().lowercased()) {
            var sourceAttributes = [["data-srcset", "data-lazy-srcset", "data-flickity-lazyload-srcset", "srcset"]]
            if element.tagName().lowercased() == "img" {
                sourceAttributes.append(["data-src", "data-original", "data-lazy-src", "data-url", "data-flickity-lazyload-src", "data-flickity-lazyload", "src"])
            }
            for attributes in sourceAttributes {
                guard let attribute = try attributes.first(where: { !(try element.attr($0)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
                let value = try element.attr(attribute)
                func capture(_ raw: String) -> String {
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty, let url = URL(string: value, relativeTo: base)?.absoluteURL {
                        sources.insert(url.absoluteString)
                    }
                    return raw
                }
                if attribute.hasSuffix("srcset") { _ = readerResolvedSrcset(value, resolve: capture) }
                else { _ = capture(value) }
            }
        }
    }
    return sources
}

// HTML srcset candidates end at whitespace or trailing commas. Commas inside
// a URL (including data URLs) belong to that URL, not a split-on-comma list.
func readerResolvedSrcset(_ value: String, resolve: (String) throws -> String) rethrows -> String {
    let characters = Array(value)
    var index = 0
    var candidates = [String]()
    while index < characters.count {
        while index < characters.count && (characters[index].isWhitespace || characters[index] == ",") { index += 1 }
        let start = index
        while index < characters.count && !characters[index].isWhitespace { index += 1 }
        guard start < index else { break }
        var url = String(characters[start..<index])
        if url.last == "," {
            while url.last == "," { url.removeLast() }
            candidates.append(try resolve(url))
            continue
        }
        let descriptorStart = index
        var parentheses = 0
        while index < characters.count {
            let character = characters[index]
            if character == "," && parentheses == 0 { break }
            if character == "(" { parentheses += 1 }
            if character == ")" { parentheses = max(0, parentheses - 1) }
            index += 1
        }
        let descriptor = String(characters[descriptorStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = try resolve(url)
        if !resolved.isEmpty { candidates.append(resolved + (descriptor.isEmpty ? "" : " " + descriptor)) }
        if index < characters.count { index += 1 }
    }
    return candidates.joined(separator: ", ")
}

