import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import SwiftUIWebView
import SwiftSoup
import SwiftReadability
import CryptoKit
import RealmSwift
import Combine
import RealmSwiftGaps
import LakeKit
import WebKit
import SwiftUtilities
import Perception

private func stripTemplateTagsForSanitize(_ html: String) -> String {
    guard html.range(of: "<template", options: .caseInsensitive) != nil else {
        return html
    }
    return html.replacingOccurrences(
        of: #"(?is)<template\b[^>]*>.*?</template>"#,
        with: "",
        options: .regularExpression
    )
}

private func sanitizeReadabilityFragment(_ html: String) -> String {
    stripTemplateTagsForSanitize(html)
}

extension URL {
    func canonicalReaderContentURLForHotfix() -> URL {
        ReaderContentLoader.getContentURL(fromLoaderURL: self) ?? self
    }

    func removingFragmentIfNeededForHotfix() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              components.fragment != nil else {
            return self
        }
        components.fragment = nil
        return components.url ?? self
    }
}

private func urlsMatchWithoutHashForHotfix(_ lhs: URL?, _ rhs: URL?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (.some(lhsURL), .some(rhsURL)):
        if lhsURL == rhsURL {
            return true
        }
        return lhsURL.removingFragmentIfNeededForHotfix() == rhsURL.removingFragmentIfNeededForHotfix()
    default:
        return false
    }
}

private func currentReaderFontCSSValues() -> (
    horizontalFamily: String,
    verticalFamily: String,
    horizontalCSSValue: String,
    verticalCSSValue: String
) {
    let horizontalFamily = UserDefaults.standard.string(forKey: "readerFont") ?? "YuKyokasho"
    let verticalFamily = horizontalFamily == "YuKyokasho" ? "YuKyokasho Yoko" : horizontalFamily
    return (
        horizontalFamily,
        verticalFamily,
        "'\(horizontalFamily)'",
        "'\(verticalFamily)'"
    )
}

private struct ReaderModeSharedFontCSSValues: Equatable {
    var horizontalFamily: String
    var verticalFamily: String
    var horizontalCSSValue: String
    var verticalCSSValue: String
}

private struct ReaderModeSharedFontInlinePayload {
    var combinedCSS: String
    var bootstrapScript: String
    var fontValues: ReaderModeSharedFontCSSValues
}

private struct ReaderModeSharedFontBlobPayload {
    var base64CSS: String
    var identity: String

    init(base64CSS: String, identity: String) {
        self.base64CSS = base64CSS
        self.identity = identity
    }
}

private enum ReaderModeSharedFontPayloadIdentity {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func shortSHA256Hex(for payload: String) -> String {
        let digest = SHA256.hash(data: Data(payload.utf8))
        var hex = [UInt8]()
        hex.reserveCapacity(16)
        for byte in digest.prefix(8) {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}

private final class ReaderModeSharedFontInlinePayloadCache {
    private let lock = NSLock()
    private var cachedCSS: String?
    private var cachedFontValues: ReaderModeSharedFontCSSValues?
    private var cachedPayload: ReaderModeSharedFontInlinePayload?

    func payload(css: String, fontValues: ReaderModeSharedFontCSSValues) -> ReaderModeSharedFontInlinePayload {
        lock.lock()
        if cachedCSS == css, cachedFontValues == fontValues, let cachedPayload {
            lock.unlock()
            return cachedPayload
        }
        lock.unlock()

        let combinedCSS = readerModeSharedFontCSSWithVerticalAlias(css)
        let bootstrapScript = """
        {
        const style = document.getElementById('mnb-custom-fonts-inline');
        globalThis.manabiReaderFontCSSText = style?.textContent || '';
        globalThis.manabiReaderFontInjectionMode = 'inline';
        globalThis.manabiHorizontalFontFamilyName = \(readerModeJSONStringLiteral(fontValues.horizontalFamily));
        globalThis.manabiVerticalFontFamilyName = \(readerModeJSONStringLiteral(fontValues.verticalFamily));
        }
        """
        let payload = ReaderModeSharedFontInlinePayload(
            combinedCSS: combinedCSS,
            bootstrapScript: bootstrapScript,
            fontValues: fontValues
        )

        lock.lock()
        cachedCSS = css
        cachedFontValues = fontValues
        cachedPayload = payload
        lock.unlock()
        return payload
    }
}

private final class ReaderModeSharedFontBlobPayloadCache {
    private let lock = NSLock()
    private var cachedBase64CSS: String?
    private var cachedPayload: ReaderModeSharedFontBlobPayload?

    func payload(base64CSS: String?) -> ReaderModeSharedFontBlobPayload? {
        guard let base64CSS, !base64CSS.isEmpty else { return nil }
        lock.lock()
        if cachedBase64CSS == base64CSS, let cachedPayload {
            lock.unlock()
            return cachedPayload
        }
        lock.unlock()

        let payload = ReaderModeSharedFontBlobPayload(
            base64CSS: base64CSS,
            identity: ReaderModeSharedFontPayloadIdentity.shortSHA256Hex(for: base64CSS)
        )

        lock.lock()
        cachedBase64CSS = base64CSS
        cachedPayload = payload
        lock.unlock()
        return payload
    }
}

private let readerModeReadabilityCSS = Readability.shared.css
private let readerModeSharedFontInlinePayloadCache = ReaderModeSharedFontInlinePayloadCache()
private let readerModeSharedFontBlobPayloadCache = ReaderModeSharedFontBlobPayloadCache()
private let readerModeSharedFontFamilyRegex = try! NSRegularExpression(
    pattern: #"font-family:\s*['"]YuKyokasho['"]\s*;"#,
    options: []
)

private enum ReaderModeJSONStringByte {
    static let backspace = UInt8(ascii: "\u{08}")
    static let tab = UInt8(ascii: "\t")
    static let newline = UInt8(ascii: "\n")
    static let formFeed = UInt8(ascii: "\u{0C}")
    static let carriageReturn = UInt8(ascii: "\r")
    static let doubleQuote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let lowercaseB = UInt8(ascii: "b")
    static let lowercaseF = UInt8(ascii: "f")
    static let lowercaseN = UInt8(ascii: "n")
    static let lowercaseR = UInt8(ascii: "r")
    static let lowercaseT = UInt8(ascii: "t")
    static let lowercaseU = UInt8(ascii: "u")
    static let digit0 = UInt8(ascii: "0")
    static let digit2 = UInt8(ascii: "2")
    static let digit8 = UInt8(ascii: "8")
    static let digit9 = UInt8(ascii: "9")
    static let utf8LineSeparator0 = UInt8(0xE2)
    static let utf8LineSeparator1 = UInt8(0x80)
    static let utf8LineSeparator2 = UInt8(0xA8)
    static let utf8ParagraphSeparator2 = UInt8(0xA9)
    static let hexDigits = Array("0123456789ABCDEF".utf8)
}

private func readerModeJSONStringLiteral(_ string: String) -> String {
    let source = string.utf8
    var literal = [UInt8]()
    literal.reserveCapacity(source.count + 2)
    literal.append(ReaderModeJSONStringByte.doubleQuote)

    var index = source.startIndex
    while index < source.endIndex {
        let byte = source[index]
        switch byte {
        case ReaderModeJSONStringByte.backspace:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseB)
        case ReaderModeJSONStringByte.tab:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseT)
        case ReaderModeJSONStringByte.newline:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseN)
        case ReaderModeJSONStringByte.formFeed:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseF)
        case ReaderModeJSONStringByte.carriageReturn:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseR)
        case ReaderModeJSONStringByte.doubleQuote, ReaderModeJSONStringByte.backslash:
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(byte)
        case 0x00...0x1F:
            appendReaderModeJSONUnicodeEscape(byte, to: &literal)
        case ReaderModeJSONStringByte.utf8LineSeparator0
            where readerModeJSONLineOrParagraphSeparatorThirdByte(in: source, at: index) != nil:
            let separatorThirdByte = readerModeJSONLineOrParagraphSeparatorThirdByte(in: source, at: index)!
            literal.append(ReaderModeJSONStringByte.backslash)
            literal.append(ReaderModeJSONStringByte.lowercaseU)
            literal.append(ReaderModeJSONStringByte.digit2)
            literal.append(ReaderModeJSONStringByte.digit0)
            literal.append(ReaderModeJSONStringByte.digit2)
            literal.append(separatorThirdByte == ReaderModeJSONStringByte.utf8LineSeparator2
                           ? ReaderModeJSONStringByte.digit8
                           : ReaderModeJSONStringByte.digit9)
            index = source.index(index, offsetBy: 2)
        default:
            literal.append(byte)
        }
        source.formIndex(after: &index)
    }

    literal.append(ReaderModeJSONStringByte.doubleQuote)
    return String(decoding: literal, as: UTF8.self)
}

private func readerModeJSONLineOrParagraphSeparatorThirdByte(
    in source: String.UTF8View,
    at index: String.UTF8View.Index
) -> UInt8? {
    let secondIndex = source.index(after: index)
    guard secondIndex < source.endIndex,
          source[secondIndex] == ReaderModeJSONStringByte.utf8LineSeparator1 else {
        return nil
    }
    let thirdIndex = source.index(after: secondIndex)
    guard thirdIndex < source.endIndex,
          source[thirdIndex] == ReaderModeJSONStringByte.utf8LineSeparator2
            || source[thirdIndex] == ReaderModeJSONStringByte.utf8ParagraphSeparator2 else {
        return nil
    }
    return source[thirdIndex]
}

private func appendReaderModeJSONUnicodeEscape(_ byte: UInt8, to output: inout [UInt8]) {
    output.append(ReaderModeJSONStringByte.backslash)
    output.append(ReaderModeJSONStringByte.lowercaseU)
    output.append(ReaderModeJSONStringByte.digit0)
    output.append(ReaderModeJSONStringByte.digit0)
    output.append(ReaderModeJSONStringByte.hexDigits[Int(byte >> 4)])
    output.append(ReaderModeJSONStringByte.hexDigits[Int(byte & 0xF)])
}

private func readerModeSharedFontCSSWithVerticalAlias(_ css: String) -> String {
    let fullRange = NSRange(css.startIndex..<css.endIndex, in: css)
    let yokoCSS = readerModeSharedFontFamilyRegex.stringByReplacingMatches(
        in: css,
        options: [],
        range: fullRange,
        withTemplate: "font-family: 'YuKyokasho Yoko';"
    )
    return yokoCSS == css ? css : css + "\n" + yokoCSS
}

internal func upsertDeferredSharedReaderFontGate(in doc: SwiftSoup.Document) throws {
    let gateCSS = """
    html[data-mnb-font-pending="1"] body.readability-mode {
        visibility: hidden !important;
    }
    """

    let htmlElement = try doc.getElementsByTag("html").first()
    try htmlElement?.attr("data-mnb-font-pending", "1")
    try htmlElement?.attr("data-mnb-font-ready", "0")

    if let existingStyle = try doc.getElementById("mnb-custom-font-gate") {
        try existingStyle.text(gateCSS)
        return
    }

    let styleElement = try doc.createElement("style")
    try styleElement.attr("id", "mnb-custom-font-gate")
    try styleElement.text(gateCSS)

    if let head = doc.head() {
        try head.appendChild(styleElement)
        return
    }

    if let html = try doc.getElementsByTag("html").first() {
        try html.prepend("<head></head>")
        if let head = doc.head() {
            try head.appendChild(styleElement)
            return
        }
    }

    try doc.appendChild(styleElement)
}

internal func upsertInlineSharedReaderFontCSS(_ css: String, in doc: SwiftSoup.Document) throws {
    guard !css.isEmpty else { return }
    let rawFontValues = currentReaderFontCSSValues()
    let payload = readerModeSharedFontInlinePayloadCache.payload(
        css: css,
        fontValues: ReaderModeSharedFontCSSValues(
            horizontalFamily: rawFontValues.horizontalFamily,
            verticalFamily: rawFontValues.verticalFamily,
            horizontalCSSValue: rawFontValues.horizontalCSSValue,
            verticalCSSValue: rawFontValues.verticalCSSValue
        )
    )
    let fontValues = payload.fontValues

    let head: Element
    if let existingHead = doc.head() {
        head = existingHead
    } else if let html = try doc.getElementsByTag("html").first() {
        try html.prepend("<head></head>")
        if let insertedHead = doc.head() {
            head = insertedHead
        } else {
            head = try doc.appendElement("head")
        }
    } else {
        head = try doc.appendElement("head")
    }

    let styleElement: Element
    if let existingStyle = try doc.getElementById("mnb-custom-fonts-inline") {
        styleElement = existingStyle
    } else {
        styleElement = try doc.createElement("style")
        try styleElement.attr("id", "mnb-custom-fonts-inline")
        try head.appendChild(styleElement)
    }
    try styleElement.attr("data-mnb-font-source", "inline")
    try styleElement.text(payload.combinedCSS)

    let scriptElement: Element
    if let existingScript = try doc.getElementById("mnb-custom-fonts-inline-bootstrap") {
        scriptElement = existingScript
    } else {
        scriptElement = try doc.createElement("script")
        try scriptElement.attr("id", "mnb-custom-fonts-inline-bootstrap")
        try head.appendChild(scriptElement)
    }
    try scriptElement.text(payload.bootstrapScript)

    if let htmlElement = try doc.getElementsByTag("html").first() {
        try htmlElement.attr("data-mnb-horizontal-font-family", fontValues.horizontalFamily)
        try htmlElement.attr("data-mnb-vertical-font-family", fontValues.verticalFamily)
        try htmlElement.attr("data-mnb-injected-font-family", fontValues.horizontalFamily)
        try htmlElement.attr("data-mnb-font-injected", "1")
        let existingStyle = (try? htmlElement.attr("style")) ?? ""
        try htmlElement.attr("style", readerModeStyleDeclaration(
            existingStyle,
            additions: [
                "--mnb-content-font": fontValues.horizontalCSSValue,
                "--mnb-content-vertical-font": fontValues.verticalCSSValue,
            ]
        ))
    }
    if let bodyElement = doc.body() {
        let existingStyle = (try? bodyElement.attr("style")) ?? ""
        try bodyElement.attr("style", readerModeStyleDeclaration(
            existingStyle,
            additions: [
                "--mnb-content-font": fontValues.horizontalCSSValue,
                "--mnb-content-vertical-font": fontValues.verticalCSSValue,
            ]
        ))
    }
}

private func readerModeStyleDeclaration(
    _ style: String,
    additions: [String: String]
) -> String {
    var declarations: [(String, String)] = []
    let existingDeclarations = style
        .split(separator: ";")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let additionKeys = Set(additions.keys.map { $0.lowercased() })
    for declaration in existingDeclarations {
        guard let separator = declaration.firstIndex(of: ":") else {
            declarations.append((declaration, ""))
            continue
        }
        let name = declaration[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        if additionKeys.contains(name.lowercased()) {
            continue
        }
        let value = declaration[declaration.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        declarations.append((name, value))
    }
    for (name, value) in additions.sorted(by: { $0.key < $1.key }) {
        declarations.append((name, value))
    }
    return declarations
        .map { name, value in
            value.isEmpty ? "\(name);" : "\(name): \(value);"
        }
        .joined(separator: " ")
}

private let readabilityViewportMetaContent = "width=device-width, user-scalable=no, minimum-scale=1.0, maximum-scale=1.0, initial-scale=1.0"
private let readabilityBylinePrefixRegex = try! NSRegularExpression(pattern: "^(by|par)\\s+", options: [.caseInsensitive])
private let readerContentPublicationDateFallbackFormatter: DateFormatter = {
    ReaderDateFormatter.makeAbsoluteFormatter(dateStyle: .short)
}()
private let readabilityClassesToPreserve: [String] = [
    "caption",
    "emoji",
    "hidden",
    "invisible",
    "sr-only",
    "visually-hidden",
    "visuallyhidden",
    "wp-caption",
    "wp-caption-text",
    "wp-smiley",
]

private enum SwiftReadabilityProcessingOutcome {
    case success(SwiftReadabilityProcessingResult)
    case unavailable
    case failed
}


private extension String {
    var debugTitleFragment: String {
        let normalized = replacingOccurrences(of: "\n", with: "\\n")
        if normalized.isEmpty {
            return "\"\""
        }
        return "\"\(normalized.truncate(120, trailing: "…"))\""
    }
}

private extension Optional where Wrapped == String {
    var debugTitleFragment: String {
        guard let value = self else { return "<nil>" }
        return value.debugTitleFragment
    }
}

private struct SwiftReadabilityProcessingResult {
    let outputHTML: String
}

private func normalizeReadabilityBodyOrder(_ doc: SwiftSoup.Document) {
    guard let body = doc.body(),
          let readerHeader = try? doc.getElementById("reader-header"),
          let readerContent = try? doc.getElementById("reader-content") else {
        return
    }

    var nodesToMove: [SwiftSoup.Element] = []
    for child in body.children().array() {
        if child === readerHeader {
            break
        }
        if child === readerContent {
            continue
        }
        nodesToMove.append(child)
    }

    for node in nodesToMove.reversed() {
        try? readerContent.prependChild(node)
    }
}

private func hasReaderContentMedia(in doc: SwiftSoup.Document) -> Bool {
    guard let readerContent = try? doc.getElementById("reader-content") else {
        return false
    }
    let selector = [
        "[data-readability-carousel=\"true\"]",
        "[data-readability-carousel=true]",
        "img",
        "picture",
        "video",
        "figure",
    ].joined(separator: ",")
    return ((try? readerContent.select(selector).isEmpty()) == false)
}

private enum ReadabilityHTMLEscapeBytes {
    static let ampersand = UInt8(ascii: "&")
    static let lessThan = UInt8(ascii: "<")
    static let greaterThan = UInt8(ascii: ">")
    static let quotationMark = UInt8(ascii: "\"")
    static let ampersandEntity = Array("&amp;".utf8)
    static let lessThanEntity = Array("&lt;".utf8)
    static let greaterThanEntity = Array("&gt;".utf8)
    static let quotationMarkEntity = Array("&quot;".utf8)
}

private func escapeReadabilityUTF8(
    _ bytes: UnsafeBufferPointer<UInt8>,
    original: String
) -> String {
    guard let firstEscapeIndex = bytes.firstIndex(where: { byte in
        byte == ReadabilityHTMLEscapeBytes.ampersand
            || byte == ReadabilityHTMLEscapeBytes.lessThan
            || byte == ReadabilityHTMLEscapeBytes.greaterThan
            || byte == ReadabilityHTMLEscapeBytes.quotationMark
    }) else {
        return original
    }

    var escaped = [UInt8]()
    escaped.reserveCapacity(bytes.count + 16)
    escaped.append(contentsOf: bytes[..<firstEscapeIndex])
    for byte in bytes[firstEscapeIndex...] {
        switch byte {
        case ReadabilityHTMLEscapeBytes.ampersand:
            escaped.append(contentsOf: ReadabilityHTMLEscapeBytes.ampersandEntity)
        case ReadabilityHTMLEscapeBytes.lessThan:
            escaped.append(contentsOf: ReadabilityHTMLEscapeBytes.lessThanEntity)
        case ReadabilityHTMLEscapeBytes.greaterThan:
            escaped.append(contentsOf: ReadabilityHTMLEscapeBytes.greaterThanEntity)
        case ReadabilityHTMLEscapeBytes.quotationMark:
            escaped.append(contentsOf: ReadabilityHTMLEscapeBytes.quotationMarkEntity)
        default:
            escaped.append(byte)
        }
    }
    return String(decoding: escaped, as: UTF8.self)
}

private func escapeReadabilityText(_ raw: String) -> String {
    if let escaped = raw.utf8.withContiguousStorageIfAvailable({ bytes in
        escapeReadabilityUTF8(bytes, original: raw)
    }) {
        return escaped
    }
    let bytes = Array(raw.utf8)
    return bytes.withUnsafeBufferPointer { buffer in
        escapeReadabilityUTF8(buffer, original: raw)
    }
}

private func escapeReadabilityHTMLAttribute(_ raw: String) -> String {
    escapeReadabilityText(raw)
}

private func normalizeReadabilityBylineText(_ rawByline: String) -> String {
    let trimmed = rawByline.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let nsByline = trimmed as NSString
    let range = NSRange(location: 0, length: nsByline.length)
    let stripped = readabilityBylinePrefixRegex.stringByReplacingMatches(
        in: trimmed,
        options: [],
        range: range,
        withTemplate: ""
    )
    let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? trimmed : cleaned
}

private func isInternalReaderURL(_ url: URL) -> Bool {
    url.scheme == "internal" && url.host == "local"
}

private struct ReaderContentPublicationDateSnapshot: Sendable {
    let publicationDate: Date
    let displayAbsolutePublicationDate: Bool
    let contentType: String
}

private struct ReaderContentRenderSnapshot: Sendable {
    let url: URL
    let title: String
    let isTitlePrefixOfContent: Bool
}

private func formattedReaderContentPublicationDate(_ snapshot: ReaderContentPublicationDateSnapshot) -> String {
    if snapshot.displayAbsolutePublicationDate {
        return ReaderDateFormatter.absoluteString(from: snapshot.publicationDate, dateFormatter: readerContentPublicationDateFallbackFormatter)
    }
    return ReaderDateFormatter.relativeString(from: snapshot.publicationDate)
        ?? ReaderDateFormatter.absoluteString(from: snapshot.publicationDate, dateFormatter: readerContentPublicationDateFallbackFormatter)
}

internal func readerContentPublicationDateFallback(for url: URL) async -> String? {
    let resolvedURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
    let snapshot = try? await { @RealmBackgroundActor () -> ReaderContentPublicationDateSnapshot? in
        let matches = try await ReaderContentLoader.loadAll(url: resolvedURL)
        let candidates = matches.compactMap { content -> ReaderContentPublicationDateSnapshot? in
            guard content.displayPublicationDate || content.isPhysicalMedia,
                  let publicationDate = content.publicationDate else {
                return nil
            }
            return ReaderContentPublicationDateSnapshot(
                publicationDate: publicationDate,
                displayAbsolutePublicationDate: content.displayAbsolutePublicationDate,
                contentType: String(describing: type(of: content))
            )
        }
        return candidates.first { $0.contentType != String(describing: HistoryRecord.self) } ?? candidates.first
    }()

    guard let snapshot else {
        return nil
    }

    let fallback = formattedReaderContentPublicationDate(snapshot)
    return fallback
}

internal func readerContentPublicationDateFallback(
    for content: any ReaderContentProtocol
) async -> String? {
    if !(content is HistoryRecord),
       (content.displayPublicationDate || content.isPhysicalMedia),
       let publicationDate = content.publicationDate {
        return formattedReaderContentPublicationDate(
            ReaderContentPublicationDateSnapshot(
                publicationDate: publicationDate,
                displayAbsolutePublicationDate: content.displayAbsolutePublicationDate,
                contentType: String(describing: type(of: content))
            )
        )
    }
    return await readerContentPublicationDateFallback(for: content.url)
}

internal func buildCanonicalReadabilityHTML(
    title: String,
    byline: String,
    publishedTime: String?,
    content: String,
    contentURL: URL,
    hideReaderTitle: Bool = false
) -> String {
    let resolvedTitle = escapeReadabilityText(title)
    let resolvedByline = escapeReadabilityText(normalizeReadabilityBylineText(byline))
    let readerFontSize = UserDefaults.standard.object(forKey: "readerFontSize") as? Double
    let viewOriginal = isInternalReaderURL(contentURL) ? nil : "<a class=\"reader-view-original\" href=\"\(escapeReadabilityHTMLAttribute(contentURL.absoluteString))\">View Original</a>"
    let bylineLine = resolvedByline.isEmpty
        ? ""
        : "<div id=\"reader-byline-line\" class=\"byline-line\"><span class=\"byline-label\">By</span> <span id=\"reader-byline\" class=\"byline\">\(resolvedByline)</span></div>"
    let publicationDateText = publishedTime.map(escapeReadabilityText)
    let metaItems = [
        publicationDateText.map { "<span id=\"reader-publication-date\">\($0)</span>" },
        viewOriginal,
    ]
        .compactMap { $0 }
    let metaLine = metaItems.isEmpty
        ? ""
        : """
        <div id="reader-meta-line" class="byline-meta-line">\(metaItems.joined(separator: "<span class=\"reader-meta-divider\">·</span>"))</div>
        """
    let actionLine = """
        <div id="reader-header-actions"></div>
        """
    let availabilityAttributes = "data-mnb-reader-mode-available=\"true\" data-mnb-reader-mode-available-for=\"\(escapeReadabilityHTMLAttribute(contentURL.absoluteString))\" data-mnb-reader-render-ready=\"1\""
    let suppressionBodyClass = ReaderContentLoader.snippetReaderTitleSuppressionBodyClass
    let bodyStyle = readerAdaptiveMaxWidthStyleDeclaration(readerFontSize: readerFontSize)
    let titleSuppressionCSS = """
    body.\(suppressionBodyClass) #reader-title {
        display: none !important;
    }
    """
    let bodyClass = hideReaderTitle
        ? "readability-mode \(suppressionBodyClass)"
        : "readability-mode"
    return """
    <!DOCTYPE html>
    <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="\(readabilityViewportMetaContent)">
            <style type="text/css" id="swiftuiwebview-readability-styles">\(readerModeReadabilityCSS)
            \(titleSuppressionCSS)</style>
            <title>\(resolvedTitle)</title>
        </head>
        <body class="\(bodyClass)" style="\(escapeReadabilityHTMLAttribute(bodyStyle))" \(availabilityAttributes)>
            <div id="reader-header" class="header">
                <h1 id="reader-title">\(resolvedTitle)</h1>
                <div id="reader-byline-container">
                    \(bylineLine)
                    \(metaLine)
                </div>
                \(actionLine)
            </div>
            <div id="reader-content">
                \(content)
            </div>
            <script>
                \(Readability.shared.scripts)
            </script>
        </body>
    </html>
    """
}

internal func bodyInnerHTML(from html: String) -> String? {
    guard let doc = try? SwiftSoup.parse(html) else {
        return nil
    }
    return try? doc.body()?.html()
}

internal func hasReadabilityModeBodyClassMarkup(in html: String) -> Bool {
    html.range(of: #"<body[^>]*class=['"][^'"]*\breadability-mode\b[^'"]*['"]"#, options: .regularExpression) != nil
}

internal func hasReaderContentNodeMarkup(in html: String) -> Bool {
    html.range(of: #"<[^>]+id=['"]reader-content['"]"#, options: .regularExpression) != nil
}

internal func hasCanonicalReadabilityMarkup(in html: String) -> Bool {
    hasReadabilityModeBodyClassMarkup(in: html) && hasReaderContentNodeMarkup(in: html)
}

private func stripRuntimeReadabilityAssets(from html: String) -> String {
    guard hasCanonicalReadabilityMarkup(in: html),
          let doc = try? SwiftSoup.parse(html) else {
        return html
    }

    try? doc.select("script").remove()
    try? doc.select([
        "style#swiftuiwebview-readability-styles",
        "style#mnb-mark-read-buttons-visibility-style",
        "style#mnb-readability-styles",
    ].joined(separator: ",")).remove()
    return (try? doc.outerHtml()) ?? html
}

private func readabilitySubstringCount(_ needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, options: [.caseInsensitive], range: searchRange) {
        count += 1
        searchRange = range.upperBound..<haystack.endIndex
    }
    return count
}

private func looksLikeStaleCachedCanonicalReadabilityHTML(_ html: String, url: URL) -> Bool {
    guard hasCanonicalReadabilityMarkup(in: html),
          let host = url.host?.lowercased(),
          host == "hypebeast.com" || host.hasSuffix(".hypebeast.com") else {
        return false
    }
    return readabilitySubstringCount("data-readability-carousel", in: html) == 0
}

internal func markReaderRenderReady(in doc: SwiftSoup.Document) {
    try? doc.select("html").first()?.attr("data-mnb-reader-render-ready", "1")
    try? doc.body()?.attr("data-mnb-reader-render-ready", "1")
}

internal func markReaderSubscriptionInactiveByDefault(in doc: SwiftSoup.Document) {
    guard let body = doc.body(),
          ((try? body.hasAttr("data-mnb-subscription-is-active")) ?? false) == false else {
        return
    }
    try? body.attr("data-mnb-subscription-is-active", "false")
}

internal func titleFromReadabilityHTML(_ html: String) -> String? {
    if let doc = try? SwiftSoup.parse(html),
       let title = titleFromReadabilityDocument(doc) {
        return title
    }

    func normalisedTitle(_ raw: String?) -> String? {
        let trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.truncate(36)
    }

    let stripped = html.strippingHTML().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stripped.isEmpty else { return nil }
    let candidate = stripped.components(separatedBy: "\n").first ?? stripped
    return normalisedTitle(candidate)
}

internal func titleFromReadabilityDocument(_ doc: SwiftSoup.Document) -> String? {
    func normalisedTitle(_ raw: String?) -> String? {
        let trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.truncate(36)
    }

    if let readerTitleText = try? doc.getElementById("reader-title")?.text(),
       let title = normalisedTitle(readerTitleText) {
        return title
    }

    if let headingText = try? doc.getElementsByTag("h1").first()?.text(),
       let title = normalisedTitle(headingText) {
        return title
    }

    if let headTitle = try? doc.title(),
       let title = normalisedTitle(headTitle) {
        return title
    }

    if let body = doc.body(),
       let bodyText = bodyTextExcludingReaderContent(from: body),
       let title = normalisedTitle(bodyText) {
        return title
    }
    return nil
}

private func bodyTextExcludingReaderContent(from body: SwiftSoup.Element) -> String? {
    let children = body.children().array()
    guard !children.isEmpty else {
        return try? body.text()
    }

    var candidates: [String] = []
    candidates.reserveCapacity(children.count)
    for child in children {
        if (try? child.attr("id")) == "reader-content" { continue }
        if (try? child.getElementById("reader-content")) != nil { continue }
        let text = (try? child.text())?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
            candidates.append(text)
        }
    }
    if candidates.isEmpty {
        return try? body.text()
    }
    return candidates.joined(separator: " ")
}

private func canHaveReadabilityContent(for url: URL) -> Bool {
    if url.absoluteString == "about:blank" || url.isEBookURL {
        return false
    }
    return url.scheme?.lowercased() != "about"
}

private func ensureReadabilityBodyExists(_ html: String) -> String {
    if html.range(of: "<body", options: .caseInsensitive) != nil {
        return html
    }
    return """
    <html>
    <head></head>
    <body>
    \(html)
    </body>
    </html>
    """
}

private func stripTemplateTagsForReadability(_ html: String) -> String {
    guard html.range(of: "<template", options: .caseInsensitive) != nil else {
        return html
    }
    return html.replacingOccurrences(
        of: #"(?is)<template\b[^>]*>.*?</template>"#,
        with: "",
        options: .regularExpression
    )
}

private func trimmedNonEmptyReadabilityText(_ raw: String?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

func buildSnippetCanonicalReadabilityHTML(
    html: String,
    contentURL: URL,
    fallbackTitle: String?,
    publishedTime: String? = nil,
    preferredTitle: String? = nil,
    hideReaderTitleOverride: Bool? = nil
) -> String? {
    let normalizedHTML = ensureReadabilityBodyExists(html)
    if hasCanonicalReadabilityMarkup(in: normalizedHTML) {
        return rebuildCanonicalSnippetReadabilityHTML(
            html: normalizedHTML,
            contentURL: contentURL,
            fallbackTitle: fallbackTitle,
            publishedTime: publishedTime,
            preferredTitle: preferredTitle,
            hideReaderTitleOverride: hideReaderTitleOverride
        )
    }
    guard let rawContent = bodyInnerHTML(from: normalizedHTML)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawContent.isEmpty else {
        return nil
    }
    let resolvedTitle = trimmedNonEmptyReadabilityText(preferredTitle)
        ?? trimmedNonEmptyReadabilityText(fallbackTitle)
        ?? ""
    let sanitizedTitle = sanitizeReadabilityFragment(resolvedTitle)
    let sanitizedContent = sanitizeReadabilityFragment(rawContent)
    let shouldHideReaderTitle = hideReaderTitleOverride
        ?? ReaderContentLoader.snippetTitleMatchesGeneratedPrefix(
            resolvedTitle,
            sourceHTML: normalizedHTML
        )
    guard !sanitizedContent.isEmpty else {
        return nil
    }
    return buildCanonicalReadabilityHTML(
        title: sanitizedTitle,
        byline: "",
        publishedTime: publishedTime,
        content: sanitizedContent,
        contentURL: contentURL.canonicalReaderContentURLForHotfix(),
        hideReaderTitle: shouldHideReaderTitle
    )
}

private func rebuildCanonicalSnippetReadabilityHTML(
    html: String,
    contentURL: URL,
    fallbackTitle: String?,
    publishedTime: String? = nil,
    preferredTitle: String? = nil,
    hideReaderTitleOverride: Bool? = nil
) -> String? {
    guard let document = try? SwiftSoup.parse(html) else {
        return nil
    }
    let extractedTitle = (try? document.getElementById("reader-title")?.text(trimAndNormaliseWhitespace: false))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let extractedByline = (try? document.getElementById("reader-byline")?.text(trimAndNormaliseWhitespace: false))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let extractedPublicationDate = (try? document.getElementById("reader-publication-date")?.text(trimAndNormaliseWhitespace: false))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let extractedContent = (try? document.getElementById("reader-content")?.html())
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let extractedContent, !extractedContent.isEmpty else {
        return nil
    }

    let resolvedTitle = trimmedNonEmptyReadabilityText(preferredTitle)
        ?? trimmedNonEmptyReadabilityText(extractedTitle)
        ?? trimmedNonEmptyReadabilityText(fallbackTitle)
        ?? ""
    let sanitizedTitle = sanitizeReadabilityFragment(resolvedTitle)
    let sanitizedByline = sanitizeReadabilityFragment(extractedByline ?? "")
    let resolvedPublishedTime = trimmedNonEmptyReadabilityText(publishedTime)
        ?? trimmedNonEmptyReadabilityText(extractedPublicationDate)
    let sanitizedContent = sanitizeReadabilityFragment(extractedContent)
    let shouldHideReaderTitle = hideReaderTitleOverride
        ?? ReaderContentLoader.snippetTitleMatchesGeneratedPrefix(
            resolvedTitle,
            sourceHTML: extractedContent
        )
    guard !sanitizedContent.isEmpty else {
        return nil
    }

    return buildCanonicalReadabilityHTML(
        title: sanitizedTitle,
        byline: sanitizedByline,
        publishedTime: resolvedPublishedTime,
        content: sanitizedContent,
        contentURL: contentURL.canonicalReaderContentURLForHotfix(),
        hideReaderTitle: shouldHideReaderTitle
    )
}

@MainActor
private func locallyRetrievableReaderHTML(
    for content: any ReaderContentProtocol,
    readerFileManager: ReaderFileManager
) async throws -> String? {
    var html = try await content.htmlToDisplay(readerFileManager: readerFileManager)
    if html == nil, content.url.isSnippetURL {
        html = content.html
    }
    guard let html else {
        return nil
    }
    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = trimmed.isEmpty ? nil : trimmed
    return result
}

private func propagateReaderModeDefaults(
    for url: URL,
    primaryKey: String,
    readabilityHTML: String,
    fallbackTitle: String?,
    derivedTitle: String? = nil
) async {
    if url.isSnippetURL {
        return
    }
    let storageReadabilityHTML = stripRuntimeReadabilityAssets(from: readabilityHTML)
    let resolvedTitle = derivedTitle ?? titleFromReadabilityHTML(storageReadabilityHTML) ?? fallbackTitle
    do {
        try await propagateReaderModeDefaultsOnBackgroundActor(
            for: url,
            primaryKey: primaryKey,
            readabilityHTML: storageReadabilityHTML,
            resolvedTitle: resolvedTitle
        )
    } catch {
    }
}

@RealmBackgroundActor
private func propagateReaderModeDefaultsOnBackgroundActor(
    for url: URL,
    primaryKey: String,
    readabilityHTML: String,
    resolvedTitle: String?
) async throws {
    let relatedRecords = try await ReaderContentLoader.loadAll(url: url)

    let writableRecords = relatedRecords.filter { $0.compoundKey != primaryKey && $0.realm != nil }
    guard !writableRecords.isEmpty else {
        return
    }

    for record in writableRecords {
        guard let realm = record.realm else { continue }
        try await realm.asyncWrite {
            record.isReaderModeByDefault = true
            record.isReaderModeAvailable = false
            if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
                if !url.isReaderFileURL && (record.content?.isEmpty ?? true) {
                    record.html = readabilityHTML
                }
                if let resolvedTitle,
                   record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.title = resolvedTitle
                }
                record.rssContainsFullContent = true
            }
            record.refreshChangeMetadata(explicitlyModified: true)
        }
    }
}

@MainActor
@Perceptible
public final class ReaderModeLoadingState {
    public struct Snapshot: Equatable {
        public var isReaderModeLoading: Bool
        public var lastRenderedURL: URL?
        public var expectedSyntheticReaderLoaderURL: URL?
        public var pendingReaderModeURL: URL?

        public static let empty = Snapshot(
            isReaderModeLoading: false,
            lastRenderedURL: nil,
            expectedSyntheticReaderLoaderURL: nil,
            pendingReaderModeURL: nil
        )

        public var hasRenderedReadabilityContent: Bool {
            lastRenderedURL != nil
        }
    }

    public private(set) var snapshot: Snapshot = .empty

    public init() {}

    public var isReaderModeLoading: Bool { snapshot.isReaderModeLoading }
    public var lastRenderedURL: URL? { snapshot.lastRenderedURL }
    public var expectedSyntheticReaderLoaderURL: URL? { snapshot.expectedSyntheticReaderLoaderURL }
    public var pendingReaderModeURL: URL? { snapshot.pendingReaderModeURL }
    public var hasRenderedReadabilityContent: Bool { snapshot.hasRenderedReadabilityContent }

    fileprivate func set(
        isReaderModeLoading: Bool,
        lastRenderedURL: URL?,
        expectedSyntheticReaderLoaderURL: URL?,
        pendingReaderModeURL: URL?
    ) {
        snapshot = Snapshot(
            isReaderModeLoading: isReaderModeLoading,
            lastRenderedURL: lastRenderedURL,
            expectedSyntheticReaderLoaderURL: expectedSyntheticReaderLoaderURL,
            pendingReaderModeURL: pendingReaderModeURL
        )
    }
}

@MainActor
public class ReaderModeViewModel: ObservableObject {
    public var readerFileManager: ReaderFileManager?
    @Published public var ebookProcessedTextCacheReader: EbookProcessedTextCacheReader? = nil
    @Published public var ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter? = nil
    @Published public var nativeEbookSectionPrewarmer: ((URL, String, Bool) async throws -> EBookNativeSectionPrewarmResult)? = nil
    @Published public var processReadabilityContent: ((String, URL, URL?, Bool, Bool, String?, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async throws -> SwiftSoup.Document)? = nil
    @Published public var processHTMLDocument: ((SwiftSoup.Document, Bool) async throws -> [UInt8])? = nil
    @Published public var processHTMLBytes: (([UInt8], Bool) async -> [UInt8])? = nil
    @Published public var processHTML: ((String, Bool) async -> String)? = nil
    public var navigator: WebViewNavigator?
    public var defaultFontSize: Double?
    @Published public var sharedFontCSSBase64: String?
    @Published public var sharedFontCSSBase64Provider: (() async -> String?)?
    @Published public var sharedReaderFontAsset: SharedReaderFontAsset?
    public var readerModeLoadCompletionHandler: ((URL) -> Void)?
    
    @Published public var isReaderMode = false
    public let loadingState = ReaderModeLoadingState()
    @Published public var isReaderModeLoading = false {
        didSet { updateLoadingStateSnapshot() }
    }
    @Published public private(set) var lastRenderedURL: URL? {
        didSet { updateLoadingStateSnapshot() }
    }
    @Published public private(set) var expectedSyntheticReaderLoaderURL: URL? {
        didSet { updateLoadingStateSnapshot() }
    }
    @Published public private(set) var pendingReaderModeURL: URL? {
        didSet { updateLoadingStateSnapshot() }
    }
    @Published var readabilityContent: String? = nil
    @Published var readabilityContainerSelector: String? = nil
    @Published var readabilityContainerFrameInfo: WKFrameInfo? = nil
    @Published var readabilityFrames = Set<WKFrameInfo>()

    public var hasRenderedReadabilityContent: Bool { lastRenderedURL != nil }

    private func updateLoadingStateSnapshot() {
        loadingState.set(
            isReaderModeLoading: isReaderModeLoading,
            lastRenderedURL: lastRenderedURL,
            expectedSyntheticReaderLoaderURL: expectedSyntheticReaderLoaderURL,
            pendingReaderModeURL: pendingReaderModeURL
        )
    }

    public func shouldIgnoreHideNavigationDueToScrollForNativeWebChrome(
        pageURL: URL,
        contentURL: URL?
    ) -> Bool {
        false
    }

    public func effectiveHideNavigationDueToScrollForNativeWebChrome(
        _ hidden: Bool,
        pageURL: URL,
        contentURL: URL?
    ) -> Bool {
        shouldIgnoreHideNavigationDueToScrollForNativeWebChrome(pageURL: pageURL, contentURL: contentURL)
            ? false
            : hidden
    }
    
//    @Published var contentRules: String? = nil

    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    private var lastFallbackLoaderURL: URL?
    private var activeRenderTaskByURL: [String: Task<Void, Never>] = [:]
    private var activeRenderGenerationByURL: [String: UUID] = [:]
    private var completedRenderGenerationByURL: [String: UUID] = [:]

//    private var contentRulesForReadabilityLoading = """
//    [\(["image", "style-sheet", "font", "media", "popup", "svg-document", "websocket", "other"].map {
//        """
//        {
//             "trigger": {
//                 "url-filter": ".*",
//                 "resource-type": ["\($0)"]
//             },
//             "action": {
//                 "type": "block"
//             }
//         }
//        """
//    } .joined(separator: ", "))
//    ]
//    """
    
    internal func readerModeLoading(_ isLoading: Bool) {
        if isLoading && !isReaderModeLoading {
            isReaderModeLoading = true
            if !isReaderMode {
                lastRenderedURL = nil
            }
        } else if !isLoading && isReaderModeLoading {
            isReaderModeLoading = false
        }
    }

    @MainActor
    public func beginReaderModeLoad(for url: URL, suppressSpinner: Bool = false) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let pendingMatches = pendingReaderModeURL.map { pendingKeysMatch($0, canonicalURL) } ?? false
        if !pendingMatches {
            updatePendingReaderModeURL(canonicalURL)
            lastFallbackLoaderURL = nil
        }
        if let rendered = lastRenderedURL, !pendingKeysMatch(rendered, canonicalURL) {
            lastRenderedURL = nil
        }
        if !suppressSpinner {
            readerModeLoading(true)
        }
    }

    @MainActor
    public func cancelReaderModeLoad(for url: URL? = nil) {
        if let url, let pendingReaderModeURL, !pendingKeysMatch(pendingReaderModeURL, url) {
            return
        }
        let completedURL = pendingReaderModeURL ?? url ?? lastRenderedURL
        if let url {
            cancelActiveRender(for: url)
        }
        updatePendingReaderModeURL(nil)
        expectedSyntheticReaderLoaderURL = nil
        lastRenderedURL = nil
        if let completedURL {
            completedRenderGenerationByURL.removeValue(forKey: canonicalRenderKey(completedURL))
        }
        readerModeLoading(false)
    }

    @MainActor
    public func markReaderModeLoadComplete(for url: URL) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let matchesPending = pendingKeysMatch(pendingReaderModeURL, canonicalURL)
        let matchesLastRendered = pendingKeysMatch(lastRenderedURL, canonicalURL)
        let matchesExpected = expectedSyntheticReaderLoaderURL.map {
            urlsMatchWithoutHashForHotfix($0, canonicalURL)
        } ?? false
        let syntheticCompletionInFlight = isReaderModeLoading && !canonicalURL.isReaderURLLoaderURL
        guard matchesPending || matchesLastRendered || matchesExpected || syntheticCompletionInFlight else {
            return
        }
        if let pendingReaderModeURL, (readabilityContent?.utf8.count ?? 0) == 0 {
            if handleEmptyReadabilityCompletion(url: canonicalURL, pendingReaderModeURL: pendingReaderModeURL) {
                return
            }
        }
        updatePendingReaderModeURL(nil)
        expectedSyntheticReaderLoaderURL = nil
        readerModeLoading(false)
        let renderKey = canonicalRenderKey(canonicalURL)
        if let activeGeneration = activeRenderGenerationByURL[renderKey] {
            completedRenderGenerationByURL[renderKey] = activeGeneration
        }
        lastRenderedURL = canonicalURL
        readerModeLoadCompletionHandler?(canonicalURL)
    }

    @MainActor
    public func isReaderModeLoadPending(for url: URL) -> Bool {
        pendingKeysMatch(pendingReaderModeURL, url)
    }

    @MainActor
    public func clearReadabilityCache(for url: URL) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let matchesLastRendered = pendingKeysMatch(lastRenderedURL, canonicalURL)
        let matchesPending = pendingKeysMatch(pendingReaderModeURL, canonicalURL)
        let isHandling = isReaderModeHandlingURL(canonicalURL)
        let shouldClear = matchesLastRendered || matchesPending || isHandling || readabilityContent != nil
        guard shouldClear else { return }
        cancelActiveRender(for: canonicalURL)
        readabilityContent = nil
        readabilityContainerSelector = nil
        readabilityContainerFrameInfo = nil
        expectedSyntheticReaderLoaderURL = nil
        if matchesLastRendered {
            lastRenderedURL = nil
            completedRenderGenerationByURL.removeValue(forKey: canonicalRenderKey(canonicalURL))
        }
        if matchesPending {
            updatePendingReaderModeURL(nil)
        }
    }

    @MainActor
    public func handleRenderedReaderDocumentReady(pageURL: URL, hasReaderContent: Bool) {
        let canonicalURL = pageURL.canonicalReaderContentURLForHotfix()
        guard hasReaderContent, !pageURL.isReaderURLLoaderURL else { return }

        let pendingMatches = pendingReaderModeURL.map { pendingKeysMatch($0, canonicalURL) } ?? false
        let expectedMatches = expectedSyntheticReaderLoaderURL.map { urlsMatchWithoutHashForHotfix($0, pageURL) } ?? false
        let syntheticCompletionInFlight = isReaderModeLoading && !pageURL.isReaderURLLoaderURL
        guard pendingMatches || expectedMatches || syntheticCompletionInFlight else { return }

        navigator?.forceClearLoadingIndicators(
            reason: "readerMode.syntheticLoad.renderReady",
            pageURL: canonicalURL
        )

        if expectedMatches {
            expectedSyntheticReaderLoaderURL = nil
        }
        markReaderModeLoadComplete(for: canonicalURL)
    }

    private func handleEmptyReadabilityCompletion(url: URL, pendingReaderModeURL: URL) -> Bool {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()

        if urlMatchesLastRendered(canonicalURL) {
            updatePendingReaderModeURL(nil)
            readerModeLoading(false)
            readerModeLoadCompletionHandler?(canonicalURL)
            return true
        }

        if canonicalURL.isSnippetURL {
            updatePendingReaderModeURL(nil)
            expectedSyntheticReaderLoaderURL = nil
            lastFallbackLoaderURL = canonicalURL
            readerModeLoading(false)
            readerModeLoadCompletionHandler?(canonicalURL)
            return true
        }

        if expectedSyntheticReaderLoaderURL != nil {
            return true
        }

        updatePendingReaderModeURL(nil)
        lastFallbackLoaderURL = canonicalURL
        readerModeLoading(false)
        readerModeLoadCompletionHandler?(canonicalURL)
        return true
    }

    func isReaderModeHandlingURL(_ url: URL) -> Bool {
        if let pendingReaderModeURL, pendingKeysMatch(pendingReaderModeURL, url) {
            return true
        }
        if let lastRenderedURL, pendingKeysMatch(lastRenderedURL, url) {
            return true
        }
        if hasActiveRender(for: url) {
            return true
        }
        return false
    }

    func resolveSharedReaderFontCSSBase64() async -> String? {
        if let sharedFontCSSBase64, !sharedFontCSSBase64.isEmpty {
            return sharedFontCSSBase64
        }
        if let sharedFontCSSBase64Provider {
            let base64 = await sharedFontCSSBase64Provider()
            guard let base64, !base64.isEmpty else {
                return nil
            }
            return base64
        }
        return nil
    }

    private func shouldUseDeferredSharedReaderFontGate(for pageURL: URL) async -> Bool {
        if sharedReaderFontUsesLocalScheme(for: pageURL) {
            return true
        }
        return false
    }

    func injectSharedFontIfNeeded(scriptCaller: WebViewScriptCaller, pageURL: URL) async {
        guard pageURL.absoluteString != "about:blank" else {
            return
        }
        guard #available(iOS 16.4, macOS 14, *) else {
            return
        }
        if let stylesheetURLTemplate = sharedReaderFontStylesheetURLTemplate(for: pageURL) {
            let js = """
            (function() {
                const postLog = (_message) => {};
                const setFontPendingState = (pending) => {
                    const root = document.documentElement;
                    if (!root) return;
                    if (pending) {
                        root.dataset.mnbFontPending = '1';
                        root.dataset.mnbFontReady = '0';
                    } else {
                        delete root.dataset.mnbFontPending;
                        root.dataset.mnbFontReady = '1';
                    }
                    postLog('pending=' + (pending ? '1' : '0')
                        + ' mode=local-scheme'
                        + ' href=' + window.location.href
                        + ' fontsStatus=' + (document.fonts?.status || 'nil'));
                };
                const resolveStylesheetURL = (desiredFamily) => {
                    const family = desiredFamily || 'YuKyokasho';
                    return stylesheetURLTemplate.replace('__MANABI_FONT_FAMILY__', encodeURIComponent(family));
                };
                const ensureReaderFontStyle = (desiredFamily) => {
                    const root = document.documentElement;
                    if (!root) return null;
                    const family = desiredFamily
                        || root?.dataset?.mnbHorizontalFontFamily
                        || globalThis.manabiHorizontalFontFamilyName
                        || 'YuKyokasho';
                    const stylesheetURL = resolveStylesheetURL(family);
                    let style = document.getElementById('mnb-custom-fonts-inline');
                    if (!style) {
                        style = document.createElement('link');
                        style.id = 'mnb-custom-fonts-inline';
                        style.rel = 'stylesheet';
                        (document.head || document.documentElement).appendChild(style);
                    }
                    style.href = stylesheetURL;
                    style.dataset.mnbInjectedFontFamily = family;
                    style.dataset.mnbFontSource = 'local-scheme';
                    root.dataset.mnbInjectedFontFamily = family;
                    root.dataset.mnbFontInjected = '1';
                    style.onload = () => postLog('stylesheetLoaded mode=local-scheme family=' + family + ' href=' + window.location.href);
                    style.onerror = () => {
                        postLog('stylesheetError mode=local-scheme family=' + family + ' href=' + window.location.href);
                        setFontPendingState(false);
                    };
                    postLog('stylesheetPrepared mode=local-scheme family=' + family + ' href=' + window.location.href);
                    return style;
                };
                globalThis.manabiReaderFontInjectionMode = 'local-scheme';
                globalThis.manabiResolveReaderFontStylesheetURL = resolveStylesheetURL;
                globalThis.manabiEnsureReaderFontStyle = ensureReaderFontStyle;
                let gateTimeout = null;
                const scheduleGateTimeout = () => {
                    if (gateTimeout) {
                        clearTimeout(gateTimeout);
                    }
                    gateTimeout = setTimeout(() => {
                        postLog('timeoutClear mode=local-scheme href=' + window.location.href);
                        setFontPendingState(false);
                    }, 4000);
                };
                const waitForFontReady = async (desiredFamily) => {
                    const fontSet = document.fonts;
                    if (!fontSet) return;
                    if (desiredFamily && typeof fontSet.load === 'function') {
                        try {
                            await fontSet.load("1em '" + desiredFamily + "'");
                        } catch (_) {}
                    }
                    if (typeof fontSet.ready === 'object' && fontSet.ready && typeof fontSet.ready.then === 'function') {
                        try {
                            await fontSet.ready;
                        } catch (_) {}
                    }
                };
                return (async () => {
                    const root = document.documentElement;
                    const desiredFamily =
                        root?.dataset?.mnbHorizontalFontFamily
                        || globalThis.manabiHorizontalFontFamilyName
                        || 'YuKyokasho';
                    setFontPendingState(true);
                    scheduleGateTimeout();
                    ensureReaderFontStyle(desiredFamily);
                    try { globalThis.manabiForwardReaderFontToEbookDocuments?.('readerMode-local-scheme-inject'); } catch (_) {}
                    try { window.parent?.manabiForwardReaderFontToEbookDocuments?.('readerMode-local-scheme-inject-child'); } catch (_) {}
                    if (typeof window.manabiApplyDirectionalInjectedFont === 'function') {
                        window.manabiApplyDirectionalInjectedFont();
                    }
                    const resolvedFamily =
                        document.documentElement?.dataset?.mnbInjectedFontFamily
                        || desiredFamily
                        || null;
                    await waitForFontReady(resolvedFamily);
                    if (gateTimeout) {
                        clearTimeout(gateTimeout);
                        gateTimeout = null;
                    }
                    postLog('fontsReady mode=local-scheme family=' + (resolvedFamily || 'nil') + ' href=' + window.location.href);
                    setFontPendingState(false);
                })().catch((e) => {
                    if (gateTimeout) {
                        clearTimeout(gateTimeout);
                        gateTimeout = null;
                    }
                    postLog('error mode=local-scheme href=' + window.location.href + ' error=' + String(e));
                    setFontPendingState(false);
                });
            })();
            """
            try? await scriptCaller.evaluateJavaScript(
                js,
                arguments: ["stylesheetURLTemplate": stylesheetURLTemplate],
                duplicateInMultiTargetFrames: true
            )
            return
        }

        guard !pageURL.isReaderURLLoaderURL else {
            return
        }
        guard let blobPayload = readerModeSharedFontBlobPayloadCache.payload(
            base64CSS: await resolveSharedReaderFontCSSBase64()
        ) else {
            return
        }
        let fontHash = blobPayload.identity
        let js = """
            (function() {
                const postLog = (_message) => {};
                const isLoaderShellDocument = () => {
                    const href = window.location.href || '';
                    return href.startsWith('internal://local/load/reader');
                };
                const setFontPendingState = (pending) => {
                    const root = document.documentElement;
                    if (!root) return;
                if (pending) {
                    root.dataset.mnbFontPending = '1';
                    root.dataset.mnbFontReady = '0';
                } else {
                    delete root.dataset.mnbFontPending;
                    root.dataset.mnbFontReady = '1';
                }
                postLog('pending=' + (pending ? '1' : '0')
                    + ' mode=blob'
                    + ' href=' + window.location.href
                    + ' fontsStatus=' + (document.fonts?.status || 'nil'));
            };
            const replaceFontBlob = (css, fontHash, desiredFamily) => {
                if (!css) return null;
                const resolvedCSS = desiredFamily
                    ? css.replace(/font-family:\\s*['"][^'"]+['"]\\s*;/g, "font-family: '" + desiredFamily + "';")
                    : css;
                const blob = new Blob([resolvedCSS], { type: 'text/css' });
                const nextBlobURL = URL.createObjectURL(blob);
                const previousBlobURL = globalThis.manabiReaderFontCSSBlobURL || null;
                globalThis.manabiReaderFontCSSBlobURL = nextBlobURL;
                globalThis.manabiReaderFontCSSHash = fontHash;
                globalThis.manabiReaderFontInjectionMode = 'blob';
                if (previousBlobURL && previousBlobURL !== nextBlobURL) {
                    try { URL.revokeObjectURL(previousBlobURL); } catch (_) {}
                }
                return nextBlobURL;
                };
                const ensureReaderFontStyle = (desiredFamily) => {
                    if (isLoaderShellDocument()) {
                        postLog('skipLoaderShell mode=blob href=' + window.location.href);
                        return null;
                    }
                    const root = document.documentElement;
                    if (!root) return null;
                let style = document.getElementById('mnb-custom-fonts-inline');
                if (style) return style;
                const css = globalThis.manabiReaderFontCSSText || '';
                if (!css) return null;
                const blobURL = replaceFontBlob(css, fontHash, desiredFamily);
                if (!blobURL) return null;
                style = document.createElement('link');
                style.id = 'mnb-custom-fonts-inline';
                style.rel = 'stylesheet';
                style.href = blobURL;
                style.dataset.mnbFontHash = fontHash;
                if (desiredFamily) {
                    style.dataset.mnbInjectedFontFamily = desiredFamily;
                }
                style.onload = () => postLog('stylesheetLoaded mode=blob family=' + (desiredFamily || 'nil') + ' href=' + window.location.href);
                style.onerror = () => {
                    postLog('stylesheetError mode=blob family=' + (desiredFamily || 'nil') + ' href=' + window.location.href);
                    setFontPendingState(false);
                };
                (document.head || document.documentElement).appendChild(style);
                postLog('stylesheetPrepared mode=blob family=' + (desiredFamily || 'nil') + ' href=' + window.location.href);
                return style;
                };
                if (isLoaderShellDocument()) {
                    postLog('skipLoaderShell mode=blob href=' + window.location.href);
                    return;
                }
                globalThis.manabiEnsureReaderFontStyle = ensureReaderFontStyle;
                let gateTimeout = null;
            const scheduleGateTimeout = () => {
                if (gateTimeout) {
                    clearTimeout(gateTimeout);
                }
                gateTimeout = setTimeout(() => {
                    postLog('timeoutClear mode=blob href=' + window.location.href);
                    setFontPendingState(false);
                }, 4000);
            };
            const waitForFontReady = async (desiredFamily) => {
                const fontSet = document.fonts;
                if (!fontSet) return;
                if (desiredFamily && typeof fontSet.load === 'function') {
                    try {
                        await fontSet.load("1em '" + desiredFamily + "'");
                    } catch (_) {}
                }
                if (typeof fontSet.ready === 'object' && fontSet.ready && typeof fontSet.ready.then === 'function') {
                    try {
                        await fontSet.ready;
                    } catch (_) {}
                }
            };
            return (async () => {
                const root = document.documentElement;
                const desiredFamily =
                    root?.dataset?.mnbHorizontalFontFamily
                    || globalThis.manabiHorizontalFontFamilyName
                    || null;
                setFontPendingState(true);
                scheduleGateTimeout();
                let style = ensureReaderFontStyle(desiredFamily);
                if (!style) {
                    const css = atob(fontCSSBase64);
                    globalThis.manabiReaderFontCSSText = css;
                    const blobURL = replaceFontBlob(css, fontHash, desiredFamily);
                    style = document.createElement('link');
                    style.id = 'mnb-custom-fonts-inline';
                    style.rel = 'stylesheet';
                    style.href = blobURL;
                    style.dataset.mnbFontHash = fontHash;
                    if (desiredFamily) {
                        style.dataset.mnbInjectedFontFamily = desiredFamily;
                    }
                    (document.head || document.documentElement).appendChild(style);
                    root.dataset.mnbFontInjected = '1';
                }
                if (typeof window.manabiApplyDirectionalInjectedFont === 'function') {
                    window.manabiApplyDirectionalInjectedFont();
                }
                try { globalThis.manabiForwardReaderFontToEbookDocuments?.('readerMode-blob-inject'); } catch (_) {}
                try { window.parent?.manabiForwardReaderFontToEbookDocuments?.('readerMode-blob-inject-child'); } catch (_) {}
                const resolvedFamily =
                    document.documentElement?.dataset?.mnbInjectedFontFamily
                    || desiredFamily
                    || null;
                await waitForFontReady(resolvedFamily);
                if (gateTimeout) {
                    clearTimeout(gateTimeout);
                    gateTimeout = null;
                }
                postLog('fontsReady mode=blob family=' + (resolvedFamily || 'nil') + ' href=' + window.location.href);
                setFontPendingState(false);
            })().catch((e) => {
                if (gateTimeout) {
                    clearTimeout(gateTimeout);
                    gateTimeout = null;
                }
                postLog('error mode=blob href=' + window.location.href + ' error=' + String(e));
                setFontPendingState(false);
            });
        })();
        """
        try? await scriptCaller.evaluateJavaScript(
            js,
            arguments: [
                "fontCSSBase64": blobPayload.base64CSS,
                "fontHash": fontHash,
            ],
            duplicateInMultiTargetFrames: true
        )
    }
    
    public func isReaderModeVisibleInMenu(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeOfferHidden && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }
    
    public init() { }

    private func expectSyntheticReaderLoaderCommit(for baseURL: URL?) {
        expectedSyntheticReaderLoaderURL = baseURL
    }

    @discardableResult
    private func consumeSyntheticReaderLoaderExpectationIfNeeded(for url: URL) -> Bool {
        guard let expectedSyntheticReaderLoaderURL else { return false }
        if urlsMatchWithoutHashForHotfix(expectedSyntheticReaderLoaderURL, url) {
            self.expectedSyntheticReaderLoaderURL = nil
            return true
        }
        return false
    }

    private func updatePendingReaderModeURL(_ newValue: URL?) {
        if let newValue, newValue.absoluteString == "about:blank" {
            return
        }
        let canonicalNewValue = newValue?.canonicalReaderContentURLForHotfix()
        pendingReaderModeURL = canonicalNewValue
    }

    private func normalizedPendingMatchKey(for url: URL?) -> String? {
        guard let url else { return nil }

        if let snippetKey = url.snippetKey {
            return "snippet:\(snippetKey)"
        }

        if url.isReaderURLLoaderURL,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let readerValue = components.queryItems?.first(where: { $0.name == "reader-url" })?.value {
            let decodedReaderURLString = readerValue.removingPercentEncoding ?? readerValue
            guard let readerURL = URL(string: decodedReaderURLString) else {
                return url.absoluteString
            }
            if let snippetKey = readerURL.snippetKey {
                return "snippet:\(snippetKey)"
            }
            return readerURL.removingFragmentIfNeeded().absoluteString
        }

        return url.canonicalReaderContentURLForHotfix().removingFragmentIfNeeded().absoluteString
    }

    private func pendingKeysMatch(_ lhs: URL?, _ rhs: URL?) -> Bool {
        normalizedPendingMatchKey(for: lhs) == normalizedPendingMatchKey(for: rhs)
    }

    private func canonicalRenderKey(_ url: URL) -> String {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        return normalizedPendingMatchKey(for: canonicalURL) ?? canonicalURL.absoluteString
    }

    @MainActor
    public func currentRenderGenerationDescription(for url: URL) -> String {
        renderGenerationDescription(for: canonicalRenderKey(url))
    }

    private func renderGenerationDescription(for key: String) -> String {
        if let activeGeneration = activeRenderGenerationByURL[key] {
            return activeGeneration.uuidString
        }
        if let completedGeneration = completedRenderGenerationByURL[key] {
            return completedGeneration.uuidString
        }
        return "nil"
    }

    private func urlMatchesLastRendered(_ url: URL) -> Bool {
        guard let lastRenderedURL else { return false }
        return pendingKeysMatch(lastRenderedURL, url)
    }

    private func hasActiveRender(for url: URL) -> Bool {
        let key = canonicalRenderKey(url)
        guard let task = activeRenderTaskByURL[key] else {
            return false
        }
        if task.isCancelled {
            activeRenderTaskByURL.removeValue(forKey: key)
            activeRenderGenerationByURL.removeValue(forKey: key)
            return false
        }
        return true
    }

    @MainActor
    private func shouldSkipDuplicateLoaderRender(for url: URL) -> (skip: Bool, reason: String) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        if hasActiveRender(for: canonicalURL) {
            return (true, "activeRender")
        }
        if pendingKeysMatch(pendingReaderModeURL, canonicalURL), readabilityContent != nil {
            return (true, "pendingWithReadability")
        }
        if pendingKeysMatch(lastRenderedURL, canonicalURL), readabilityContent != nil {
            return (true, "alreadyRenderedWithReadability")
        }
        return (false, "none")
    }

    private func finishRenderTask(for url: URL, generation: UUID) {
        let key = canonicalRenderKey(url)
        guard let activeGeneration = activeRenderGenerationByURL[key], activeGeneration == generation else {
            return
        }
        completedRenderGenerationByURL[key] = generation
        activeRenderTaskByURL.removeValue(forKey: key)
        activeRenderGenerationByURL.removeValue(forKey: key)
    }

    private func cancelActiveRender(for url: URL) {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let key = canonicalRenderKey(canonicalURL)
        guard let task = activeRenderTaskByURL[key] else {
            return
        }
        task.cancel()
        activeRenderTaskByURL.removeValue(forKey: key)
        activeRenderGenerationByURL.removeValue(forKey: key)
    }

    private func cancelOtherActiveRenders(except keyToKeep: String) {
        let staleKeys = activeRenderTaskByURL.keys.filter { $0 != keyToKeep }
        for staleKey in staleKeys {
            activeRenderTaskByURL[staleKey]?.cancel()
            activeRenderTaskByURL.removeValue(forKey: staleKey)
            activeRenderGenerationByURL.removeValue(forKey: staleKey)
        }
    }

    @discardableResult
    @MainActor
    private func startRenderTaskIfNeeded(
        for url: URL,
        operation: @escaping @ReaderViewModelActor (_ generation: UUID) async -> Void
    ) -> Bool {
        let canonicalURL = url.canonicalReaderContentURLForHotfix()
        let key = canonicalRenderKey(canonicalURL)
        cancelOtherActiveRenders(except: key)

        if let existingTask = activeRenderTaskByURL[key], !existingTask.isCancelled {
            return false
        }

        let generation = UUID()
        activeRenderGenerationByURL[key] = generation
        completedRenderGenerationByURL.removeValue(forKey: key)
        let task = Task { @ReaderViewModelActor [weak self] in
            guard let self else { return }
            await operation(generation)
            await self.finishRenderTask(for: canonicalURL, generation: generation)
        }
        activeRenderTaskByURL[key] = task
        return true
    }

    private enum ReaderModeRoute: String {
        case localHTML = "swiftFinalLoad"
        case capturedReadability = "webviewReadability"
        case unavailable = "unavailable"
    }

    private struct ReaderModeRouteDecision {
        let route: ReaderModeRoute
        let prefetchedContent: (any ReaderContentProtocol)?
        let prefetchedLocalHTML: String?
    }
    
    func isReaderModeLoadPending(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeAvailable && content.isReaderModeByDefault
    }
    
    @MainActor
    private func resolveReaderModeRoute(readerContent: ReaderContent) async -> ReaderModeRoute {
        await resolveReaderModeRouteDecision(readerContent: readerContent).route
    }

    @MainActor
    private func resolveReaderModeRouteDecision(readerContent: ReaderContent) async -> ReaderModeRouteDecision {
        let activeReaderFileManager = readerFileManager ?? .shared
        if let content = try? await readerContent.getContent(),
           content.rssContainsFullContent,
           !content.isReaderModeByDefault {
            if let html = try? await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
            ),
               !html.isEmpty {
                if !looksLikeStaleCachedCanonicalReadabilityHTML(html, url: content.url) {
                    return ReaderModeRouteDecision(
                        route: .localHTML,
                        prefetchedContent: content,
                        prefetchedLocalHTML: html
                    )
                }
            }
        }
        if let readabilityContent, !readabilityContent.isEmpty {
            let contentURL = readerContent.pageURL
            if !looksLikeStaleCachedCanonicalReadabilityHTML(readabilityContent, url: contentURL) {
                return ReaderModeRouteDecision(
                    route: .capturedReadability,
                    prefetchedContent: nil,
                    prefetchedLocalHTML: nil
                )
            }
        }
        if let content = try? await readerContent.getContent(),
           let html = try? await locallyRetrievableReaderHTML(
                for: content,
                readerFileManager: activeReaderFileManager
           ),
           !html.isEmpty {
            if !looksLikeStaleCachedCanonicalReadabilityHTML(html, url: content.url) {
                return ReaderModeRouteDecision(
                    route: .localHTML,
                    prefetchedContent: content,
                    prefetchedLocalHTML: html
                )
            }
        }
        return ReaderModeRouteDecision(
            route: .unavailable,
            prefetchedContent: nil,
            prefetchedLocalHTML: nil
        )
    }

    @MainActor
    func readerModeRouteForTesting(readerContent: ReaderContent) async -> String {
        await resolveReaderModeRoute(readerContent: readerContent).rawValue
    }

    @MainActor
    private func readerContentRenderSnapshot(readerContent: ReaderContent) async throws -> ReaderContentRenderSnapshot? {
        guard let content = try await readerContent.getContent() else {
            return nil
        }
        return ReaderContentRenderSnapshot(
            url: content.url,
            title: content.title,
            isTitlePrefixOfContent: content.isTitlePrefixOfContent
        )
    }
    
    @MainActor
    public func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        let contentURL = readerContent.pageURL
        let cachedReadabilityContent = readabilityContent
        let cachedContainerSelector = readabilityContainerSelector
        let cachedContainerFrameInfo = readabilityContainerFrameInfo
        beginReaderModeLoad(for: contentURL)
        _ = startRenderTaskIfNeeded(for: contentURL) { [weak self] generation in
            guard let self else { return }
            let currentPageURL = await MainActor.run { readerContent.pageURL }
            guard urlsMatchWithoutHashForHotfix(contentURL, currentPageURL) else {
                await self.cancelReaderModeLoad(for: contentURL)
                return
            }
            let routeDecision = await self.resolveReaderModeRouteDecision(readerContent: readerContent)
            switch routeDecision.route {
            case .localHTML:
                await self.showReaderViewUsingSwiftProcessing(
                    readerContent: readerContent,
                    scriptCaller: scriptCaller,
                    renderGeneration: generation,
                    prefetchedContent: routeDecision.prefetchedContent,
                    prefetchedLocalHTML: routeDecision.prefetchedLocalHTML
                )
            case .capturedReadability:
                guard let cachedReadabilityContent else {
                    await self.cancelReaderModeLoad(for: contentURL)
                    return
                }
                do {
                    let contentSnapshot = try await self.readerContentRenderSnapshot(readerContent: readerContent)
                    let publicationDateFallback = cachedReadabilityContent.contains("id=\"reader-publication-date\"")
                        ? nil
                        : await readerContentPublicationDateFallback(for: contentURL)
                    let resolvedReadabilityContent = rebuildCanonicalSnippetReadabilityHTML(
                        html: cachedReadabilityContent,
                        contentURL: contentSnapshot?.url ?? contentURL,
                        fallbackTitle: titleFromReadabilityHTML(cachedReadabilityContent) ?? contentSnapshot?.title,
                        publishedTime: publicationDateFallback,
                        preferredTitle: contentSnapshot?.title,
                        hideReaderTitleOverride: contentSnapshot?.isTitlePrefixOfContent
                    )
                    guard let resolvedReadabilityContent else {
                        await self.cancelReaderModeLoad(for: contentURL)
                        return
                    }
                    try await self.showReadabilityContent(
                        readerContent: readerContent,
                        readabilityContent: resolvedReadabilityContent,
                        renderToSelector: cachedContainerSelector,
                        in: cachedContainerFrameInfo,
                        scriptCaller: scriptCaller,
                        renderGeneration: generation
                    )
                } catch is CancellationError {
                    await self.cancelReaderModeLoad(for: contentURL)
                } catch {
                    print(error)
                    await self.cancelReaderModeLoad(for: contentURL)
                }
            case .unavailable:
                await self.cancelReaderModeLoad(for: contentURL)
            }
        }
    }

    @MainActor
    public func beginSyntheticLoadForCurrentContentIfPossible(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller
    ) async -> Bool {
        guard let content = try? await readerContent.getContent() else {
            return false
        }
        guard content.url.isSnippetURL else {
            return false
        }
        guard readerContent.pageURL.matchesReaderURL(content.url) else {
            return false
        }
        showReaderView(readerContent: readerContent, scriptCaller: scriptCaller)
        return true
    }

    @MainActor
    private func showReaderViewUsingSwiftProcessing(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller,
        renderGeneration: UUID? = nil,
        prefetchedContent: (any ReaderContentProtocol)? = nil,
        prefetchedLocalHTML: String? = nil
    ) async {
        do {
            let content: any ReaderContentProtocol
            if let prefetchedContent {
                content = prefetchedContent
            } else {
                guard let resolvedContent = try await readerContent.getContent() else {
                    cancelReaderModeLoad(for: readerContent.pageURL)
                    return
                }
                content = resolvedContent
            }
            let activeReaderFileManager = readerFileManager ?? .shared
            let html: String
            if let prefetchedLocalHTML {
                html = prefetchedLocalHTML
            } else {
                guard let resolvedHTML = try await locallyRetrievableReaderHTML(
                    for: content,
                    readerFileManager: activeReaderFileManager
                ) else {
                    cancelReaderModeLoad(for: content.url)
                    return
                }
                html = resolvedHTML
            }

            let resolvedReadabilityHTML: String?
            if hasCanonicalReadabilityMarkup(in: html) {
                resolvedReadabilityHTML = rebuildCanonicalSnippetReadabilityHTML(
                    html: html,
                    contentURL: content.url,
                    fallbackTitle: titleFromReadabilityHTML(html)
                )
            } else {
                let publicationDateFallback = await readerContentPublicationDateFallback(for: content)
                let swiftReadability = await processReadabilityHTMLInSwift(
                    html: html,
                    url: content.url,
                    snippetPublishedTime: publicationDateFallback,
                    meaningfulContentMinChars: max(content.meaningfulContentMinLength, 1)
                )
                switch swiftReadability {
                case .success(let result):
                    resolvedReadabilityHTML = result.outputHTML
                case .unavailable, .failed:
                    resolvedReadabilityHTML = nil
                }
            }

            if let resolvedReadabilityHTML {
                readabilityContent = resolvedReadabilityHTML
                try await showReadabilityContent(
                    readerContent: readerContent,
                    readabilityContent: resolvedReadabilityHTML,
                    renderToSelector: nil,
                    in: nil,
                    scriptCaller: scriptCaller,
                    renderGeneration: renderGeneration
                )
                return
            }

            readabilityContent = nil
            let directHTML = prepareHTMLForDirectLoad(html)
            if let htmlData = directHTML.data(using: .utf8) {
                navigator?.load(
                    htmlData,
                    mimeType: "text/html",
                    characterEncodingName: "UTF-8",
                    baseURL: content.url
                )
            } else {
                navigator?.loadHTML(directHTML, baseURL: content.url)
            }
        } catch {
            print(error)
            cancelReaderModeLoad(for: readerContent.pageURL)
        }
    }
    
    /// `readerContent` is used to verify current reader state before loading processed `content`
    @MainActor
    internal func showReadabilityContent(
        readerContent: ReaderContent,
        readabilityContent: String,
        renderToSelector: String?,
        in frameInfo: WKFrameInfo?,
        scriptCaller: WebViewScriptCaller,
        renderGeneration: UUID? = nil
    ) async throws {
        guard let content = try await readerContent.getContent() else {
            print("No content set to show in reader mode")
            cancelReaderModeLoad(for: readerContent.pageURL)
            return
        }
        let url = content.url
        let renderBaseURL: URL
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || url.isSnippetURL {
            renderBaseURL = url
        } else if url.absoluteString == "about:blank" {
            renderBaseURL = readerContent.pageURL
        } else {
            renderBaseURL = url
        }
        let shouldStoreReaderHTML = !url.isEBookURL
            && !url.isFileURL
            && !url.isNativeReaderView
            && !url.isReaderFileURL
            && (content.content?.isEmpty ?? true)
        let resolvedStoredHTML = shouldStoreReaderHTML ? stripRuntimeReadabilityAssets(from: readabilityContent) : nil
        let resolvedTitleIfNeeded: String? = {
            guard content.title.isEmpty else { return nil }
            return (resolvedStoredHTML ?? content.html)?
                .strippingHTML()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .first?
                .truncate(36) ?? ""
        }()
        let titleForDisplay = content.titleForDisplay
        let needsAsyncWrite =
            content.isReaderModeByDefault == false
            || content.isReaderModeAvailable == true
            || content.isReaderModeOfferHidden == true
            || (
                !url.isEBookURL
                && !url.isFileURL
                && !url.isNativeReaderView
                && content.rssContainsFullContent == false
            )
            || (resolvedStoredHTML != nil && content.html != resolvedStoredHTML)
            || (resolvedTitleIfNeeded != nil && content.title != resolvedTitleIfNeeded)

        if needsAsyncWrite {
            try await content.asyncWrite { _, content in
                content.isReaderModeByDefault = true
                content.isReaderModeAvailable = false
                content.isReaderModeOfferHidden = false
                if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
                    if let resolvedStoredHTML {
                        content.html = resolvedStoredHTML
                    }
                    if let resolvedTitleIfNeeded {
                        content.title = resolvedTitleIfNeeded
                    }
                    content.rssContainsFullContent = true
                }
                content.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        
        if !isReaderMode {
            isReaderMode = true
        }

        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let imageURLToDisplay = try await content.imageURLToDisplay()
        let processReadabilityContent = processReadabilityContent
        let processHTMLBytes = processHTMLBytes
        let processHTML = processHTML
        let prefersDirectSnippetReadabilityParse = url.isSnippetURL && hasCanonicalReadabilityMarkup(in: readabilityContent)
        let snippetRawTitle = content.title
        let snippetNeedsClipboardIndicator = content.needsClipboardIndicator
        let hideRedundantSnippetTitle = content.isTitlePrefixOfContent
        let tracksReadingProgress = content.tracksReadingProgress
        let primaryRecordCompoundKey = await MainActor.run { content.compoundKey }
        
        try await { @ReaderViewModelActor [weak self] in
            var doc: SwiftSoup.Document?
            
            if let processReadabilityContent, !prefersDirectSnippetReadabilityParse {
                doc = try await processReadabilityContent(
                    readabilityContent,
                    url,
                    nil,
                    false,
                    tracksReadingProgress,
                    nil,
                    { doc in
                        do {
                            return try await preprocessWebContentForReaderMode(
                                doc: doc,
                                url: url,
                                fallbackTitle: titleForDisplay
                            )
                        } catch {
                            print(error)
                            return doc
                        }
                    }
                )
            } else {
                let isXML = readabilityContent.hasPrefix("<?xml") || readabilityContent.hasPrefix("<?XML") // TODO: Case insensitive
                let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
                doc = try SwiftSoup.parse(readabilityContent, url.absoluteString, parser)
                doc?.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
                doc?.outputSettings().charset(.utf8)
                if isXML {
                    doc?.outputSettings().escapeMode(.xhtml)
                }
            }

            guard let doc else {
                print("Error: Unexpectedly failed to receive doc")
                return
            }
            let derivedTitle = titleFromReadabilityDocument(doc) ?? titleForDisplay
            await propagateReaderModeDefaults(
                for: url,
                primaryKey: primaryRecordCompoundKey,
                readabilityHTML: readabilityContent,
                fallbackTitle: titleForDisplay,
                derivedTitle: derivedTitle
            )
            try await processForReaderMode(
                doc: doc,
                url: url,
                contentSectionLocationIdentifier: nil,
                isEBook: false,
                isCacheWarmer: false,
                defaultTitle: titleForDisplay,
                imageURL: imageURLToDisplay,
                injectEntryImageIntoHeader: injectEntryImageIntoHeader,
                defaultFontSize: defaultFontSize ?? 21
            )
            normalizeReadabilityBodyOrder(doc)
            if url.isSnippetURL {
                let cleanedSnippetTitle = ReaderContentLoader.resolvedDisplayTitle(
                    snippetRawTitle,
                    needsClipboardIndicator: snippetNeedsClipboardIndicator
                )
                if let titleElement = try? doc.getElementById("reader-title") {
                    try? titleElement.text(cleanedSnippetTitle)
                }
                if let body = doc.body() {
                    let existingClassNames = ((try? body.className()) ?? "")
                        .split(separator: " ")
                        .map(String.init)
                    var classNames = existingClassNames.filter { !$0.isEmpty }
                    if !classNames.contains("readability-mode") {
                        classNames.insert("readability-mode", at: 0)
                    }
                    let suppressionClass = ReaderContentLoader.snippetReaderTitleSuppressionBodyClass
                    classNames.removeAll { $0 == suppressionClass }
                    if hideRedundantSnippetTitle {
                        classNames.append(suppressionClass)
                    }
                    try? body.attr("class", classNames.joined(separator: " "))
                }
            }

            let processedIsEbook = ((try? doc.body()?.attr("data-is-ebook")) ?? "") == "true"
            let shouldInjectProcessedStyles = !(processedIsEbook && readerModeDisableInjectedStylingForEbookLayoutDiagnosis)
            let processedBodyClasses = (try? doc.body()?.className()) ?? ""
            let processedBodyClassesForFrameInjection: String = {
                let trimmed = processedBodyClasses.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "readability-mode" : trimmed
            }()
            let processedStyleTextForFrameInjection: String = {
                guard shouldInjectProcessedStyles else {
                    return ""
                }
                guard let styleElement = try? doc.getElementById("swiftuiwebview-readability-styles"),
                      let styleHTML = try? styleElement.html() else {
                    return readerModeReadabilityCSS
                }
                return styleHTML.isEmpty ? readerModeReadabilityCSS : styleHTML
            }()
            if await shouldUseDeferredSharedReaderFontGate(for: url) {
                try? upsertDeferredSharedReaderFontGate(in: doc)
            }

            markReaderRenderReady(in: doc)

            let serializedHTMLBytes = try doc.outerHtmlUTF8()

            var transformedHTMLBytes = serializedHTMLBytes
            var transformedHTMLString: String?
            if let processHTMLBytes {
                transformedHTMLBytes = await processHTMLBytes(
                    transformedHTMLBytes,
                    false
                )
            }
            if let processHTML {
                let serializedHTML = String(decoding: transformedHTMLBytes, as: UTF8.self)
                let processedHTML = await processHTML(
                    serializedHTML,
                    false
                )
                transformedHTMLString = processedHTML
                transformedHTMLBytes = Array(processedHTML.utf8)
            }

            let transformedContentForFrameInjection: String?
            let transformedBodyClassesForFrameInjection: String?
            let transformedStyleTextForFrameInjection: String?
            if let frameInfo, !frameInfo.isMainFrame {
                let transformedContent = transformedHTMLString ?? String(decoding: transformedHTMLBytes, as: UTF8.self)
                transformedContentForFrameInjection = transformedContent
                if processHTML == nil {
                    transformedBodyClassesForFrameInjection = processedBodyClassesForFrameInjection
                    transformedStyleTextForFrameInjection = processedStyleTextForFrameInjection
                } else {
                    let transformedDocument = try? SwiftSoup.parse(transformedContent)
                    let transformedBodyClasses = {
                        guard let transformedDocument,
                              let bodyElement = transformedDocument.body(),
                              let bodyClassNames = try? bodyElement.className() else {
                            return processedBodyClassesForFrameInjection
                        }
                        let trimmed = bodyClassNames.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? "readability-mode" : trimmed
                    }()
                    let transformedStyleText = {
                        guard shouldInjectProcessedStyles else {
                            return ""
                        }
                        guard let transformedDocument,
                              let styleElement = try? transformedDocument.getElementById("swiftuiwebview-readability-styles"),
                              let styleHTML = try? styleElement.html() else {
                            return processedStyleTextForFrameInjection
                        }
                        return styleHTML.isEmpty ? processedStyleTextForFrameInjection : styleHTML
                    }()
                    transformedBodyClassesForFrameInjection = transformedBodyClasses
                    transformedStyleTextForFrameInjection = transformedStyleText
                }
            } else {
                transformedContentForFrameInjection = nil
                transformedBodyClassesForFrameInjection = nil
                transformedStyleTextForFrameInjection = nil
            }
            let transformedHTMLData = Data(transformedHTMLBytes)
            try await { @MainActor in
                guard url.matchesReaderURL(readerContent.pageURL) else {
                    cancelReaderModeLoad(for: url)
                    return
                }
                if let frameInfo = frameInfo, !frameInfo.isMainFrame {
                    let transformedContent = transformedContentForFrameInjection ?? ""
                    let transformedBodyClasses = transformedBodyClassesForFrameInjection ?? "readability-mode"
                    let transformedStyleText = shouldInjectProcessedStyles
                        ? (transformedStyleTextForFrameInjection ?? "")
                        : ""
                    try await scriptCaller.evaluateJavaScript(
                        """
                        var root = document.body
                        if (renderToSelector) {
                            root = document.querySelector(renderToSelector)
                        }
                        var serialized = html
                        
                        let xmlns = document.body?.getAttribute('xmlns')
                        if (xmlns) {
                            let parser = new DOMParser()
                            let doc = parser.parseFromString(serialized, 'text/html')
                            let readabilityNode = doc.body
                            let replacementNode = root.cloneNode()
                            replacementNode.innerHTML = ''
                            for (let innerNode of readabilityNode.childNodes) {
                                serialized = new XMLSerializer().serializeToString(innerNode)
                                replacementNode.innerHTML += serialized
                            }
                            root.innerHTML = replacementNode.innerHTML
                        } else if (root) {
                            root.outerHTML = serialized
                        }
                        
                        let existingStyle = document.getElementById('swiftuiwebview-readability-styles')
                        if (existingStyle) {
                            existingStyle.textContent = css
                        } else {
                            let style = document.createElement('style')
                            style.id = 'swiftuiwebview-readability-styles'
                            style.textContent = css
                            document.head.appendChild(style)
                        }
                        const manabiStyle = document.getElementById('mnb-readability-styles')
                        if (manabiStyle && document.head) {
                            document.head.appendChild(manabiStyle)
                        }
                        if (document.body) {
                            document.body.className = bodyClassNames || 'readability-mode'
                        }
                        if (readerModeScript) {
                            try {
                                new Function(readerModeScript)()
                            } catch (error) {
                                console.error(error)
                            }
                        }
                        """,
                        arguments: [
                            "renderToSelector": renderToSelector ?? "",
                            "html": transformedContent,
                            "css": transformedStyleText,
                            "bodyClassNames": transformedBodyClasses,
                            "readerModeScript": Readability.shared.scripts,
                        ], in: frameInfo)
                    self?.markReaderModeLoadComplete(for: url)
                } else {
                    self?.expectSyntheticReaderLoaderCommit(for: renderBaseURL)
                    navigator?.load(
                        transformedHTMLData,
                        mimeType: "text/html",
                        characterEncodingName: "UTF-8",
                        baseURL: renderBaseURL
                    )
                }
//                try await { @MainActor in
//                    readerModeLoading(false)
//                }()
            }()
        }()

    }

    @ReaderViewModelActor
    private func processReadabilityHTMLInSwift(
        html: String,
        url: URL,
        snippetPublishedTime: String? = nil,
        meaningfulContentMinChars: Int
    ) async -> SwiftReadabilityProcessingOutcome {
        guard canHaveReadabilityContent(for: url) else {
            return .unavailable
        }

        let normalizedHTML = ensureReadabilityBodyExists(html)
        if url.isSnippetURL {
            if let snippetHTML = buildSnippetCanonicalReadabilityHTML(
                html: normalizedHTML,
                contentURL: url,
                fallbackTitle: titleFromReadabilityHTML(normalizedHTML),
                publishedTime: snippetPublishedTime
            ) {
                return .success(SwiftReadabilityProcessingResult(outputHTML: snippetHTML))
            }
        }
        let options = SwiftReadability.ReadabilityOptions(
            charThreshold: max(meaningfulContentMinChars, 1),
            classesToPreserve: readabilityClassesToPreserve
        )
        let parser = SwiftReadability.Readability(
            html: normalizedHTML,
            url: url,
            options: options
        )
        guard let result = try? parser.parse() else {
            if url.isSnippetURL,
               let snippetHTML = buildSnippetCanonicalReadabilityHTML(
                    html: normalizedHTML,
                    contentURL: url,
                    fallbackTitle: titleFromReadabilityHTML(normalizedHTML),
                    publishedTime: snippetPublishedTime
               ) {
                return .success(SwiftReadabilityProcessingResult(outputHTML: snippetHTML))
            }
            return .failed
        }
        let rawContent = stripTemplateTagsForReadability(result.content)
        guard !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed
        }

        let resolvedPublishedTime = trimmedNonEmptyReadabilityText(result.publishedTime)
            ?? trimmedNonEmptyReadabilityText(snippetPublishedTime)
        let outputHTML = buildCanonicalReadabilityHTML(
            title: stripTemplateTagsForReadability(result.title ?? ""),
            byline: stripTemplateTagsForReadability(result.byline ?? ""),
            publishedTime: resolvedPublishedTime,
            content: rawContent,
            contentURL: url
        )
        return .success(SwiftReadabilityProcessingResult(outputHTML: outputHTML))
    }
    
    @MainActor
    public func onNavigationCommitted(
        readerContent: ReaderContent,
        newState: WebViewState,
        scriptCaller: WebViewScriptCaller
    ) async throws {
        readabilityContainerFrameInfo = nil
        readabilityContent = nil
        readabilityContainerSelector = nil
//        contentRules = nil
        try Task.checkCancellation()

        guard let content = readerContent.content else {
            print("No content to display in ReaderModeViewModel onNavigationCommitted")
            cancelReaderModeLoad(for: newState.pageURL)
            return
        }
        try Task.checkCancellation()
        
        let committedURL = content.url
        guard committedURL.matchesReaderURL(newState.pageURL) else {
            print("URL mismatch in ReaderModeViewModel onNavigationCommitted", committedURL, newState.pageURL)
            cancelReaderModeLoad(for: committedURL)
            return
        }
        try Task.checkCancellation()

        await injectSharedFontIfNeeded(scriptCaller: scriptCaller, pageURL: committedURL)
        if !scriptCaller.hasAsyncCaller {
        } else {
            do {
                try await scriptCaller.evaluateJavaScript(
                    "window.paginationTrackingBookKey = bookKey;",
                    arguments: ["bookKey": newState.pageURL.absoluteString],
                    in: nil,
                    duplicateInMultiTargetFrames: true
                )
            } catch {
            }
        }

        if consumeSyntheticReaderLoaderExpectationIfNeeded(for: newState.pageURL) {
            return
        }

        // FIXME: Mokuro? check plugins thing for reader mode url instead of hardcoding methods here
        let isReaderModeVerified = content.isReaderModeByDefault
        try Task.checkCancellation()
        
        if isReaderMode != isReaderModeVerified && !newState.pageURL.isEBookURL {
            withAnimation {
                readerModeLoading(isReaderModeVerified)
                isReaderMode = isReaderModeVerified // Reset and confirm via JS later
            }
            try Task.checkCancellation()
        }
        
        if newState.pageURL.isReaderURLLoaderURL {
            let duplicateLoaderRender = shouldSkipDuplicateLoaderRender(for: committedURL)
            if duplicateLoaderRender.skip {
                return
            }
            if let readerFileManager {
                let html = try await content.htmlToDisplay(readerFileManager: readerFileManager)
                if let html {
                    try Task.checkCancellation()

                    let currentURL = readerContent.pageURL
                    guard committedURL.matchesReaderURL(currentURL) else {
                        print("URL mismatch in ReaderModeViewModel onNavigationCommitted", currentURL, committedURL)
                        cancelReaderModeLoad(for: committedURL)
                        return
                    }
                    let publicationDateFallback = await readerContentPublicationDateFallback(for: content)
                    if committedURL.isSnippetURL,
                       let snippetHTML = buildSnippetCanonicalReadabilityHTML(
                        html: html,
                        contentURL: committedURL,
                        fallbackTitle: titleFromReadabilityHTML(html) ?? content.title,
                        publishedTime: publicationDateFallback,
                        preferredTitle: content.title,
                        hideReaderTitleOverride: content.isTitlePrefixOfContent
                       ) {
                        readabilityContent = snippetHTML
                    } else if hasCanonicalReadabilityMarkup(in: html) {
                        readabilityContent = html
                    } else {
                        readabilityContent = nil
                    }
                    readerContent.isRenderingReaderHTML = true
                    showReaderView(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller
                    )
                } else {
                    guard let navigator else {
                        print("Error: No navigator set in ReaderModeViewModel onNavigationCommitted")
                        return
                    }
                    navigator.load(URLRequest(url: committedURL))
                }
            } else {
                guard let navigator else {
                    print("Error: No navigator set in ReaderModeViewModel onNavigationCommitted")
                    return
                }
                navigator.load(URLRequest(url: committedURL))
            }
        }
    }
    
    @MainActor
    public func onNavigationFinished(
        newState: WebViewState,
        scriptCaller: WebViewScriptCaller
    ) async {
        await injectSharedFontIfNeeded(scriptCaller: scriptCaller, pageURL: newState.pageURL)
        if navigationFinishedDeferral(newState: newState) != nil {
            return
        }

        let pendingMatchesPage: Bool = {
            guard let pendingReaderModeURL else { return false }
            let pendingKey = normalizedPendingMatchKey(for: pendingReaderModeURL)
            let pendingLoaderKey = ReaderContentLoader.readerLoaderURL(for: pendingReaderModeURL).flatMap { normalizedPendingMatchKey(for: $0) }
            let pageKey = normalizedPendingMatchKey(for: newState.pageURL)
            let pageLoaderKey = ReaderContentLoader.readerLoaderURL(for: newState.pageURL).flatMap { normalizedPendingMatchKey(for: $0) }
            if let pendingKey, pendingKey == pageKey || pendingKey == pageLoaderKey {
                return true
            }
            if let pendingLoaderKey, pendingLoaderKey == pageKey || pendingLoaderKey == pendingKey {
                return true
            }
            return false
        }()

        if pendingMatchesPage, let pendingReaderModeURL {
            markReaderModeLoadComplete(for: pendingReaderModeURL)
        } else {
            readerModeLoading(false)
        }
        if !newState.pageURL.isReaderURLLoaderURL {
            do {
                let isNextReaderMode = try await scriptCaller.evaluateJavaScript("return document.body?.dataset.isNextLoadInReaderMode === 'true'") as? Bool ?? false
                if !isNextReaderMode {
                    readerModeLoading(false)
                }
            } catch {
                readerModeLoading(false)
            }
        }
    }

    private enum NavigationFinishedDeferral {
        case loader
        case synthetic
        case pending
    }

    private func navigationFinishedDeferral(newState: WebViewState) -> NavigationFinishedDeferral? {
        guard let pendingReaderModeURL else { return nil }

        if newState.pageURL.isReaderURLLoaderURL {
            let pageMatchesPending = pendingKeysMatch(pendingReaderModeURL, newState.pageURL)
            if !(hasRenderedReadabilityContent && pageMatchesPending) {
                return .loader
            }
        }

        if expectedSyntheticReaderLoaderURL != nil {
            let pageURL = newState.pageURL
            let pageMatchesPending = pendingKeysMatch(pendingReaderModeURL, pageURL)
            if hasRenderedReadabilityContent && pageMatchesPending {
                self.expectedSyntheticReaderLoaderURL = nil
            } else {
                return .synthetic
            }
        }

        if pendingReaderModeURL.isSnippetURL && !hasRenderedReadabilityContent {
            return .pending
        }

        if !hasRenderedReadabilityContent {
            let pageURL = newState.pageURL
            let pageMatchesPending = pendingKeysMatch(pendingReaderModeURL, pageURL)
            let pageIsRealPendingContent = pageMatchesPending && !pageURL.isReaderURLLoaderURL
            if !pageIsRealPendingContent || expectedSyntheticReaderLoaderURL != nil {
                return .pending
            }
        }

        return nil
    }
    
    @MainActor
    public func onNavigationFailed(newState: WebViewState) {
        cancelReaderModeLoad(for: newState.pageURL)
    }
}

private let readerModeDisableInjectedStylingForEbookLayoutDiagnosis = false

func prepareHTMLForDirectLoad(_ html: String) -> String {
    var updatedHTML = html
    let markerPatterns = [
        #"data-is-next-load-in-reader-mode=['\"][^'"]*['\"]"#,
        #"data-mnb-reader-mode-available=['\"][^'"]*['\"]"#,
        #"data-mnb-reader-mode-available-for=['\"][^'"]*['\"]"#
    ]
    for pattern in markerPatterns {
        updatedHTML = updatedHTML.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }

    if updatedHTML.range(of: "<body", options: .caseInsensitive) == nil {
        return """
        <html>
        <head></head>
        <body data-mnb-subscription-is-active="false">
        \(updatedHTML)
        </body>
        </html>
        """
    }
    if updatedHTML.range(of: #"(?i)<body\b[^>]*\bdata-mnb-subscription-is-active\s*=\s*['"]"#, options: .regularExpression) == nil,
       let bodyRange = updatedHTML.range(of: #"(?i)<body\b"#, options: .regularExpression) {
        updatedHTML.insert(contentsOf: #" data-mnb-subscription-is-active="false""#, at: bodyRange.upperBound)
    }
    return updatedHTML
}

fileprivate let readerFontSizeStylePattern = #"(?i)(<body[^>]*\bstyle="[^"]*)font-size:\s*[\d.]+px"#
fileprivate let readerFontSizeStyleRegex = try! NSRegularExpression(pattern: readerFontSizeStylePattern, options: .caseInsensitive)

fileprivate let bodyStylePattern = #"(?i)(<body[^>]*\bstyle=")([^"]*)(")"#
fileprivate let bodyStyleRegex = try! NSRegularExpression(pattern: bodyStylePattern, options: .caseInsensitive)

fileprivate func rewriteManabiReaderFontSizeStyle(in htmlBytes: [UInt8], newFontSize: Double) -> [UInt8] {
    // Convert the UTF8 bytes to a String.
    guard let html = String(bytes: htmlBytes, encoding: .utf8) else {
        return htmlBytes
    }
    
    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    let nsHTML = html as NSString
    var updatedHtml: String
    let newFontSizeStr = "font-size: " + String(newFontSize) + "px"
    // If a font-size exists in the style, replace it.
    if let firstMatch = readerFontSizeStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let replacement = readerFontSizeStyleRegex.replacementString(
            for: firstMatch,
            in: html,
            offset: 0,
            template: "$1" + newFontSizeStr
        )
        updatedHtml = nsHTML.replacingCharacters(in: firstMatch.range, with: replacement)
    }
    // Otherwise, if a <body ... style="..."> exists, insert the font-size.
    else if let styleMatch = bodyStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let prefix = nsHTML.substring(with: styleMatch.range(at: 1))
        let content = nsHTML.substring(with: styleMatch.range(at: 2))
        let suffix = nsHTML.substring(with: styleMatch.range(at: 3))
        let newContent = newFontSizeStr + "; " + content
        let replacement = prefix + newContent + suffix
        updatedHtml = nsHTML.replacingCharacters(in: styleMatch.range, with: replacement)
    }
    else {
        updatedHtml = html
    }
    
    // Convert the updated HTML string back to UTF8 bytes.
    return Array(updatedHtml.utf8)
}

public func preprocessWebContentForReaderMode(
    doc: SwiftSoup.Document,
    url: URL,
    fallbackTitle: String? = nil
) throws -> SwiftSoup.Document {
    transformContentSpecificToFeed(doc: doc, url: url)
    do {
        try wireViewOriginalLinks(doc: doc, url: url)
    } catch { }

    if let fallbackTitle, !fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let titleElement = try doc.getElementById("reader-title") {
            let currentTitleText = try titleElement.text(trimAndNormaliseWhitespace: false)
            if currentTitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try titleElement.text(fallbackTitle)
                if let headTitle = try doc.head()?.getElementsByTag("title").first() {
                    let currentHeadTitle = try headTitle.text()
                    if currentHeadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try headTitle.text(fallbackTitle)
                    }
                }
            }
        }
    }
    return doc
}

nonisolated public func processForReaderMode(
    doc: SwiftSoup.Document,
    url: URL,
    contentSectionLocationIdentifier: String?,
    isEBook: Bool,
    isCacheWarmer: Bool,
    defaultTitle: String?,
    imageURL: URL?,
    injectEntryImageIntoHeader: Bool,
    defaultFontSize: CGFloat
) throws {
    // Migrate old cached versions
    // TODO: Update cache, if this is a performance issue.
    if !isEBook,
       try doc.getElementById("reader-content") == nil,
       let oldElement = try doc.getElementsByClass("reader-content").first() {
        try oldElement.attr("id", "reader-content")
        try oldElement.removeAttr("class")
    }
    
    if isEBook {
        try doc.body()?.attr("data-is-ebook", "true")
        if readerModeDisableInjectedStylingForEbookLayoutDiagnosis {
            try? doc.getElementById("swiftuiwebview-readability-styles")?.remove()
            try? doc.getElementById("mnb-mark-read-buttons-visibility-style")?.remove()
            try? doc.getElementById("mnb-readability-styles")?.remove()
            try? doc.body()?.removeAttr("style")
        }
    }
    
    if !isCacheWarmer {
        if let bodyTag = doc.body() {
            markReaderSubscriptionInactiveByDefault(in: doc)
            // TODO: font size and theme set elsewhere already..?
            let readerFontSize = (UserDefaults.standard.object(forKey: "readerFontSize") as? Double) ?? defaultFontSize
            let lightModeTheme = (UserDefaults.standard.object(forKey: "lightModeTheme") as? LightModeTheme) ?? .white
            let darkModeTheme = (UserDefaults.standard.object(forKey: "darkModeTheme") as? DarkModeTheme) ?? .black
            
            var bodyStyle = "font-size: \(readerFontSize)px;"
            if !(isEBook && readerModeDisableInjectedStylingForEbookLayoutDiagnosis) {
                bodyStyle += " \(readerAdaptiveMaxWidthStyleDeclaration(readerFontSize: readerFontSize))"
                if let existingBodyStyle = try? bodyTag.attr("style"), !existingBodyStyle.isEmpty {
                    bodyStyle = "\(bodyStyle); \(existingBodyStyle)"
                }
            }
            _ = try? bodyTag.attr("style", bodyStyle)
            _ = try? bodyTag.attr("data-mnb-light-theme", lightModeTheme.rawValue)
            _ = try? bodyTag.attr("data-mnb-dark-theme", darkModeTheme.rawValue)
        }
        
        if let defaultTitle = defaultTitle, let existing = try? doc.getElementById("reader-title"), !existing.hasText() {
            do {
                try existing.html(escapeReadabilityText(defaultTitle))
            } catch { }
        }
        
        if !isEBook {
            do {
                try fixAnnoyingTitlesWithPipes(doc: doc, url: url)
            } catch { }
        }
        
        if let imageURL {
            let readerContentAlreadyHasMedia = hasReaderContentMedia(in: doc)
            let documentHasImages = try !(doc.body()?.getElementsByTag(UTF8Arrays.img).isEmpty() ?? true)
            let shouldInjectHeaderImage = (injectEntryImageIntoHeader && !readerContentAlreadyHasMedia)
                || !documentHasImages
            if shouldInjectHeaderImage,
               let existing = try? doc.select("img[src='\(imageURL.absoluteString)'"),
               existing.isEmpty() {
                do {
                    try doc.getElementById("reader-header")?.prepend("<img src='\(imageURL.absoluteString)'>")
                } catch { }
            }
        }
    }
}
