import Foundation

private let ebookHTMLEscapedAmpersand = Array("&amp;".utf8)
private let ebookHTMLEscapedDoubleQuote = Array("&quot;".utf8)
private let ebookHTMLEscapedSingleQuote = Array("&#39;".utf8)
private let ebookHTMLEscapedLessThan = Array("&lt;".utf8)
private let ebookHTMLEscapedGreaterThan = Array("&gt;".utf8)

fileprivate func appendEbookHTMLAttributeEscapedBytes(
    _ string: String,
    to output: inout Data
) {
    for byte in string.utf8 {
        switch byte {
        case EbookHTMLByte.ampersand:
            output.append(contentsOf: ebookHTMLEscapedAmpersand)
        case EbookHTMLByte.doubleQuote:
            output.append(contentsOf: ebookHTMLEscapedDoubleQuote)
        case EbookHTMLByte.singleQuote:
            output.append(contentsOf: ebookHTMLEscapedSingleQuote)
        case EbookHTMLByte.lessThan:
            output.append(contentsOf: ebookHTMLEscapedLessThan)
        case EbookHTMLByte.greaterThan:
            output.append(contentsOf: ebookHTMLEscapedGreaterThan)
        default:
            output.append(byte)
        }
    }
}

struct EBookProcessedSectionWritingHint {
    let direction: String
    let writingMode: String
}

func ebookProcessedSectionWritingHint(from url: URL) -> EBookProcessedSectionWritingHint? {
    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let directionItems = queryItems.filter { $0.name == "mnbWritingDirection" }
    let writingModeItems = queryItems.filter { $0.name == "mnbWritingMode" }
    guard directionItems.count == 1,
          writingModeItems.count == 1 else {
        return nil
    }
    let direction = directionItems[0].value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard direction == "vertical" else { return nil }
    guard let requestedWritingMode = writingModeItems[0].value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
          requestedWritingMode == "vertical-lr" || requestedWritingMode == "vertical-rl" else {
        return nil
    }
    return EBookProcessedSectionWritingHint(
        direction: "vertical",
        writingMode: requestedWritingMode
    )
}

public struct EbookSectionPresentation: Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let revision: String
    public let bodyAttributes: [String: String]
    public let bodyStyleProperties: [String: String]

    public init(
        schemaVersion: Int = EbookSectionPresentation.currentSchemaVersion,
        revision: String,
        bodyAttributes: [String: String],
        bodyStyleProperties: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.bodyAttributes = bodyAttributes
        self.bodyStyleProperties = bodyStyleProperties
    }
}

private struct EbookHTMLDocumentTagLocations {
    var htmlOpenTagEnd: Int?
    var headOpenTagEnd: Int?
    var headCloseTagStart: Int?
    var bodyOpenTagStart: Int?
    var bodyOpenTagEnd: Int?
    var bodyStyleValueRange: Range<Int>?
}

private enum EbookHTMLByte {
    static let lessThan = UInt8(ascii: "<")
    static let greaterThan = UInt8(ascii: ">")
    static let slash = UInt8(ascii: "/")
    static let equals = UInt8(ascii: "=")
    static let singleQuote = UInt8(ascii: "'")
    static let doubleQuote = UInt8(ascii: "\"")
    static let ampersand = UInt8(ascii: "&")
    static let semicolon = UInt8(ascii: ";")
    static let openingBrace = UInt8(ascii: "{")
    static let closingBrace = UInt8(ascii: "}")
    static let space = UInt8(ascii: " ")
    static let horizontalTab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let uppercaseA = UInt8(ascii: "A")
    static let uppercaseZ = UInt8(ascii: "Z")
    static let lowercaseOffset = UInt8(ascii: "a") - UInt8(ascii: "A")
}

private let ebookHTMLTagName = Array("html".utf8)
private let ebookHeadTagName = Array("head".utf8)
private let ebookBodyTagName = Array("body".utf8)
private let ebookMetaTagName = Array("meta".utf8)
private let ebookNameAttributeName = Array("name".utf8)
private let ebookStyleAttributeName = Array("style".utf8)
private let ebookScriptTagName = Array("script".utf8)
private let ebookStyleTagName = Array("style".utf8)

private enum EbookSectionPresentationPolicy {
    static let bodyAttributeNames: Set<String> = [
        "data-mnb-auto-scroll-on-read",
        "data-mnb-dark-theme",
        "data-mnb-ebook-title-location-visibility",
        "data-mnb-familiar-furigana-enabled",
        "data-mnb-furigana-enabled",
        "data-mnb-furigana-original-only",
        "data-mnb-jlpt-levels-enabled",
        "data-mnb-known-furigana-enabled",
        "data-mnb-learning-furigana-enabled",
        "data-mnb-learning-status-visibility",
        "data-mnb-light-theme",
        "data-mnb-mark-read-buttons-hide-with-navigation",
        "data-mnb-mark-read-buttons-visible",
        "data-mnb-presentation-revision",
        "data-mnb-presentation-schema-version",
        "data-mnb-reading-progress-enabled",
        "data-mnb-romaji-mode-enabled",
        "data-mnb-settings-initialized",
        "data-mnb-show-familiar",
        "data-mnb-show-known",
        "data-mnb-subscription-is-active",
        "data-mnb-tracking-highlights-enabled",
    ]
    static let bodyStyleNames: Set<String> = [
        "--mnb-content-font",
        "--mnb-content-vertical-font",
        "--mnb-reader-content-font-size",
        "--mnb-reader-content-rt-size",
        "--mnb-reader-max-width-override",
        "font-size",
        "font-weight",
    ]

    static func validated(_ presentation: EbookSectionPresentation?) -> EbookSectionPresentation? {
        guard let presentation,
              presentation.schemaVersion == EbookSectionPresentation.currentSchemaVersion,
              !presentation.revision.isEmpty else {
            return nil
        }
        return presentation
    }

    static func filteredBodyAttributes(
        from presentation: EbookSectionPresentation
    ) -> [String: String] {
        presentation.bodyAttributes.filter { bodyAttributeNames.contains($0.key.lowercased()) }
    }

    static func styleDeclarations(from presentation: EbookSectionPresentation) -> String {
        presentation.bodyStyleProperties
            .filter { bodyStyleNames.contains($0.key.lowercased()) && isSafeStyleValue($0.value) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)!important" }
            .joined(separator: ";")
    }

    private static func isSafeStyleValue(_ value: String) -> Bool {
        !value.utf8.contains { byte in
            byte == EbookHTMLByte.semicolon
                || byte == EbookHTMLByte.openingBrace
                || byte == EbookHTMLByte.closingBrace
                || byte == EbookHTMLByte.carriageReturn
                || byte == EbookHTMLByte.lineFeed
        }
    }
}
private let ebookPaginatorLayoutBootstrapMarkup = Data(
    #"<style id="mnb-paginator-layout-bootstrap">html{display:none!important}</style>"#.utf8
)

func ebookHTMLDataWithInjectedResponseMetadata(
    _ htmlData: Data,
    baseURL: String,
    writingHint: EBookProcessedSectionWritingHint?,
    bodyAttributes: [String: String],
    presentation: EbookSectionPresentation? = nil,
    additionalHeadMarkup: Data? = nil,
    suppressesInitialPaginatorLayout: Bool = false
) -> Data {
    ebookHTMLDataWithInjectedMetadata(
        htmlData,
        baseURL: baseURL,
        writingHint: writingHint,
        bodyAttributes: bodyAttributes,
        presentation: presentation,
        additionalHeadMarkup: additionalHeadMarkup,
        suppressesInitialPaginatorLayout: suppressesInitialPaginatorLayout
    )
}

private func ebookHTMLDataWithInjectedMetadata(
    _ htmlData: Data,
    baseURL: String?,
    writingHint: EBookProcessedSectionWritingHint?,
    bodyAttributes: [String: String],
    presentation: EbookSectionPresentation?,
    additionalHeadMarkup: Data?,
    suppressesInitialPaginatorLayout: Bool
) -> Data {
    let validPresentation = EbookSectionPresentationPolicy.validated(presentation)
    var encodedBodyAttributes = validPresentation.map(
        EbookSectionPresentationPolicy.filteredBodyAttributes(from:)
    ) ?? [:]
    if let validPresentation {
        encodedBodyAttributes["data-mnb-presentation-schema-version"] = String(validPresentation.schemaVersion)
        encodedBodyAttributes["data-mnb-presentation-revision"] = validPresentation.revision
    }
    encodedBodyAttributes.merge(bodyAttributes) { _, responseValue in responseValue }
    if let writingHint {
        encodedBodyAttributes["data-mnb-writing-direction"] = writingHint.direction
        encodedBodyAttributes["data-mnb-writing-mode"] = writingHint.writingMode
        encodedBodyAttributes["data-mnb-foliate-writing-direction"] = writingHint.direction
        encodedBodyAttributes["data-mnb-foliate-writing-mode"] = writingHint.writingMode
    }
    var bodyAttributeBytes = Data()
    for (key, value) in encodedBodyAttributes.sorted(by: { $0.key < $1.key }) {
        if !bodyAttributeBytes.isEmpty {
            bodyAttributeBytes.append(EbookHTMLByte.space)
        }
        bodyAttributeBytes.append(contentsOf: key.utf8)
        bodyAttributeBytes.append(contentsOf: "=\"".utf8)
        appendEbookHTMLAttributeEscapedBytes(value, to: &bodyAttributeBytes)
        bodyAttributeBytes.append(EbookHTMLByte.doubleQuote)
    }
    var headPayload = Data()
    if let baseURL {
        headPayload.append(contentsOf: "<base href=\"".utf8)
        appendEbookHTMLAttributeEscapedBytes(baseURL, to: &headPayload)
        headPayload.append(contentsOf: "\">".utf8)
    }
    if suppressesInitialPaginatorLayout {
        // Foliate removes this after installing final column geometry, avoiding an
        // otherwise wasted whole-document layout in the source document's styles.
        headPayload.append(ebookPaginatorLayoutBootstrapMarkup)
    }
    if let additionalHeadMarkup {
        headPayload.append(additionalHeadMarkup)
    }
    let bodyStyleDeclarations = validPresentation.map(
        EbookSectionPresentationPolicy.styleDeclarations(from:)
    ) ?? ""
    let terminatedBodyStyleDeclarations = bodyStyleDeclarations.isEmpty
        ? ""
        : bodyStyleDeclarations + ";"
    var escapedBodyStyleDeclarations = Data()
    escapedBodyStyleDeclarations.reserveCapacity(terminatedBodyStyleDeclarations.utf8.count)
    appendEbookHTMLAttributeEscapedBytes(terminatedBodyStyleDeclarations, to: &escapedBodyStyleDeclarations)

    let htmlWithoutManagedAttributes = ebookHTMLDataRemovingBodyAttributes(
        named: Set(encodedBodyAttributes.keys.map { Array($0.lowercased().utf8) }),
        from: htmlData
    )
    let authoritativeHTMLData = ebookHTMLDataRemovingBodyStyleProperties(
        named: EbookSectionPresentationPolicy.bodyStyleNames,
        from: htmlWithoutManagedAttributes,
        when: validPresentation != nil
    )
    let tags = ebookHTMLDocumentTagLocations(in: authoritativeHTMLData)
    var insertions = [(index: Int, data: Data)]()
    if !headPayload.isEmpty, let headTagEnd = tags.headOpenTagEnd {
        insertions.append((headTagEnd, headPayload))
    } else if !headPayload.isEmpty, let htmlTagEnd = tags.htmlOpenTagEnd {
        var head = Data("<head>".utf8)
        head.append(headPayload)
        head.append(Data("</head>".utf8))
        insertions.append((htmlTagEnd, head))
    } else if tags.htmlOpenTagEnd == nil, !headPayload.isEmpty {
        var wrapped = Data("<!doctype html><html><head>".utf8)
        wrapped.append(headPayload)
        wrapped.append(Data("</head><body".utf8))
        if !escapedBodyStyleDeclarations.isEmpty {
            wrapped.append(Data(" style=\"".utf8))
            wrapped.append(contentsOf: escapedBodyStyleDeclarations)
            wrapped.append(EbookHTMLByte.doubleQuote)
        }
        if !bodyAttributeBytes.isEmpty {
            wrapped.append(EbookHTMLByte.space)
            wrapped.append(contentsOf: bodyAttributeBytes)
        }
        wrapped.append(EbookHTMLByte.greaterThan)
        wrapped.append(authoritativeHTMLData)
        wrapped.append(Data("</body></html>".utf8))
        return wrapped
    }
    if let bodyTagEnd = tags.bodyOpenTagEnd {
        var closingTagInsertion = Data()
        if !escapedBodyStyleDeclarations.isEmpty {
            if let styleValueRange = tags.bodyStyleValueRange {
                var styleSuffix = Data()
                if !styleValueRange.isEmpty {
                    styleSuffix.append(EbookHTMLByte.semicolon)
                }
                styleSuffix.append(contentsOf: escapedBodyStyleDeclarations)
                insertions.append((styleValueRange.upperBound, styleSuffix))
            } else {
                closingTagInsertion.append(Data(" style=\"".utf8))
                closingTagInsertion.append(contentsOf: escapedBodyStyleDeclarations)
                closingTagInsertion.append(EbookHTMLByte.doubleQuote)
            }
        }
        if !bodyAttributeBytes.isEmpty {
            closingTagInsertion.append(EbookHTMLByte.space)
            closingTagInsertion.append(contentsOf: bodyAttributeBytes)
        }
        if !closingTagInsertion.isEmpty {
            insertions.append((bodyTagEnd - 1, closingTagInsertion))
        }
    }

    var result = Data()
    result.reserveCapacity(authoritativeHTMLData.count + insertions.reduce(0) { $0 + $1.data.count })
    var sourceIndex = 0
    for insertion in insertions.sorted(by: { $0.index < $1.index }) {
        result.append(authoritativeHTMLData[sourceIndex..<insertion.index])
        result.append(insertion.data)
        sourceIndex = insertion.index
    }
    result.append(authoritativeHTMLData[sourceIndex...])
    return result
}

func ebookHTMLWithInjectedDirectSectionMetadata(
    _ html: String,
    baseURL: String,
    sourceHref: String
) -> String {
    String(decoding: ebookHTMLDataWithInjectedDirectSectionResponseMetadata(
        Data(html.utf8),
        baseURL: baseURL,
        sourceHref: sourceHref,
        writingHint: nil,
        presentation: nil,
        additionalHeadMarkup: nil
    ), as: UTF8.self)
}

func ebookHTMLDataWithInjectedDirectSectionResponseMetadata(
    _ htmlData: Data,
    baseURL: String,
    sourceHref: String,
    writingHint: EBookProcessedSectionWritingHint?,
    presentation: EbookSectionPresentation?,
    additionalHeadMarkup: Data?
) -> Data {
    var bodyAttributes = ["data-mnb-source-href": sourceHref]
    if ebookHTMLContainsOpeningTag(named: Array("m-s".utf8), in: htmlData) {
        bodyAttributes["data-mnb-has-sentences"] = "true"
    }
    if ebookHTMLContainsOpeningTag(named: Array("m-m".utf8), in: htmlData) {
        bodyAttributes["data-mnb-has-segments"] = "true"
    }
    return ebookHTMLDataWithInjectedMetadata(
        htmlData,
        baseURL: baseURL,
        writingHint: writingHint,
        bodyAttributes: bodyAttributes,
        presentation: presentation,
        additionalHeadMarkup: additionalHeadMarkup,
        suppressesInitialPaginatorLayout: true
    )
}

func ebookHTMLApplyingSectionPresentation(
    _ html: String,
    presentation: EbookSectionPresentation?
) -> String {
    guard EbookSectionPresentationPolicy.validated(presentation) != nil else {
        return html
    }
    return String(decoding: ebookHTMLDataWithInjectedMetadata(
        Data(html.utf8),
        baseURL: nil,
        writingHint: nil,
        bodyAttributes: [:],
        presentation: presentation,
        additionalHeadMarkup: nil,
        suppressesInitialPaginatorLayout: false
    ), as: UTF8.self)
}

func ebookHTMLWithInjectedPresentationHints(
    _ html: String,
    writingHint: EBookProcessedSectionWritingHint?
) -> String {
    guard let writingHint else { return html }
    return String(decoding: ebookHTMLDataWithInjectedMetadata(
        Data(html.utf8),
        baseURL: nil,
        writingHint: writingHint,
        bodyAttributes: [:],
        presentation: nil,
        additionalHeadMarkup: nil,
        suppressesInitialPaginatorLayout: false
    ), as: UTF8.self)
}

func ebookHTMLDataByInjectingHeadMarkup(_ markup: Data, into documentHTML: Data) -> Data {
    guard !markup.isEmpty else { return documentHTML }
    let tags = ebookHTMLDocumentTagLocations(in: documentHTML)
    let insertionIndex: Int
    var prefix = Data()
    var suffix = Data()
    if let headCloseTagStart = tags.headCloseTagStart {
        insertionIndex = headCloseTagStart
    } else if let headOpenTagEnd = tags.headOpenTagEnd {
        insertionIndex = headOpenTagEnd
    } else if let bodyOpenTagStart = tags.bodyOpenTagStart {
        insertionIndex = bodyOpenTagStart
        prefix = Data("<head>".utf8)
        suffix = Data("</head>".utf8)
    } else if let htmlOpenTagEnd = tags.htmlOpenTagEnd {
        insertionIndex = htmlOpenTagEnd
        prefix = Data("<head>".utf8)
        suffix = Data("</head>".utf8)
    } else {
        insertionIndex = documentHTML.startIndex
    }

    var result = Data()
    result.reserveCapacity(
        documentHTML.count + prefix.count + markup.count + suffix.count
    )
    result.append(documentHTML[..<insertionIndex])
    result.append(prefix)
    result.append(markup)
    result.append(suffix)
    result.append(documentHTML[insertionIndex...])
    return result
}

func ebookHTMLDataReplacingHeadMetaElement(
    named metaName: String,
    with markup: Data,
    in documentHTML: Data
) -> Data {
    let metaNameBytes = Array(metaName.lowercased().utf8)
    let removalRanges: [Range<Int>] = documentHTML.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var ranges = [Range<Int>]()
        ebookHTMLScanTags(in: bytes) { tagStart, tagEnd, nameRange, isClosing in
            guard !isClosing,
                  ebookHTMLASCIIEquals(ebookMetaTagName, bytes: bytes, range: nameRange),
                  let valueRange = ebookHTMLAttributeValueRange(
                    named: ebookNameAttributeName,
                    in: bytes,
                    attributesStart: nameRange.upperBound,
                    tagEnd: tagEnd
                  ),
                  ebookHTMLASCIIEquals(metaNameBytes, bytes: bytes, range: valueRange) else {
                return false
            }
            ranges.append(tagStart..<tagEnd)
            return false
        }
        return ranges
    }
    guard !removalRanges.isEmpty else {
        return ebookHTMLDataByInjectingHeadMarkup(markup, into: documentHTML)
    }

    var documentWithoutManagedMeta = Data()
    documentWithoutManagedMeta.reserveCapacity(
        documentHTML.count - removalRanges.reduce(0) { $0 + $1.count }
    )
    var sourceIndex = documentHTML.startIndex
    for range in removalRanges {
        documentWithoutManagedMeta.append(documentHTML[sourceIndex..<range.lowerBound])
        sourceIndex = range.upperBound
    }
    documentWithoutManagedMeta.append(documentHTML[sourceIndex...])
    return ebookHTMLDataByInjectingHeadMarkup(markup, into: documentWithoutManagedMeta)
}

private func ebookHTMLDocumentTagLocations(in data: Data) -> EbookHTMLDocumentTagLocations {
    data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var locations = EbookHTMLDocumentTagLocations()
        ebookHTMLScanTags(in: bytes) { tagStart, tagEnd, nameRange, isClosing in
            if ebookHTMLASCIIEquals(ebookHTMLTagName, bytes: bytes, range: nameRange) {
                if !isClosing, locations.htmlOpenTagEnd == nil {
                    locations.htmlOpenTagEnd = tagEnd
                }
            } else if ebookHTMLASCIIEquals(ebookHeadTagName, bytes: bytes, range: nameRange) {
                if isClosing {
                    if locations.headCloseTagStart == nil {
                        locations.headCloseTagStart = tagStart
                    }
                } else if locations.headOpenTagEnd == nil {
                    locations.headOpenTagEnd = tagEnd
                }
            } else if !isClosing,
                      locations.bodyOpenTagEnd == nil,
                      ebookHTMLASCIIEquals(ebookBodyTagName, bytes: bytes, range: nameRange) {
                locations.bodyOpenTagStart = tagStart
                locations.bodyOpenTagEnd = tagEnd
                locations.bodyStyleValueRange = ebookHTMLQuotedStyleValueRange(
                    in: bytes,
                    attributesStart: nameRange.upperBound,
                    tagEnd: tagEnd
                )
            }
            return locations.bodyOpenTagEnd != nil
                && (locations.headOpenTagEnd == nil || locations.headCloseTagStart != nil)
        }
        return locations
    }
}

private func ebookHTMLContainsOpeningTag(named tagName: [UInt8], in data: Data) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var found = false
        ebookHTMLScanTags(in: bytes) { _, _, nameRange, isClosing in
            found = !isClosing && ebookHTMLASCIIEquals(tagName, bytes: bytes, range: nameRange)
            return found
        }
        return found
    }
}

private func ebookHTMLScanTags(
    in bytes: UnsafeBufferPointer<UInt8>,
    visit: (_ tagStart: Int, _ tagEnd: Int, _ nameRange: Range<Int>, _ isClosing: Bool) -> Bool
) {
    var index = 0
    while index < bytes.count {
        guard bytes[index] == EbookHTMLByte.lessThan else {
            index += 1
            continue
        }
        if ebookHTMLBytesMatch(Array("<!--".utf8), in: bytes, startingAt: index) {
            index = ebookHTMLIndex(
                after: Array("-->".utf8),
                in: bytes,
                startingAt: index + 4
            ) ?? bytes.count
            continue
        }

        var nameStart = index + 1
        guard nameStart < bytes.count else { return }
        let isClosing = bytes[nameStart] == EbookHTMLByte.slash
        if isClosing {
            nameStart += 1
        }
        guard nameStart < bytes.count,
              ebookHTMLTagNameByte(bytes[nameStart]) else {
            index = ebookHTMLOpenTagEnd(in: bytes, startingAt: nameStart) ?? (index + 1)
            continue
        }
        var nameEnd = nameStart + 1
        while nameEnd < bytes.count, ebookHTMLTagNameByte(bytes[nameEnd]) {
            nameEnd += 1
        }
        guard nameEnd < bytes.count,
              ebookHTMLTagBoundary(bytes[nameEnd]),
              let tagEnd = ebookHTMLOpenTagEnd(in: bytes, startingAt: nameEnd) else {
            index += 1
            continue
        }
        let nameRange = nameStart..<nameEnd
        if visit(index, tagEnd, nameRange, isClosing) {
            return
        }
        if !isClosing,
           (
            ebookHTMLASCIIEquals(ebookScriptTagName, bytes: bytes, range: nameRange)
                || ebookHTMLASCIIEquals(ebookStyleTagName, bytes: bytes, range: nameRange)
           ) {
            index = ebookHTMLRawTextElementEnd(
                named: Array(bytes[nameRange]),
                in: bytes,
                startingAt: tagEnd
            ) ?? bytes.count
        } else {
            index = tagEnd
        }
    }
}

private func ebookHTMLRawTextElementEnd(
    named tagName: [UInt8],
    in bytes: UnsafeBufferPointer<UInt8>,
    startingAt start: Int
) -> Int? {
    var index = start
    while index < bytes.count {
        guard bytes[index] == EbookHTMLByte.lessThan,
              index + 2 <= bytes.count,
              bytes[index + 1] == EbookHTMLByte.slash,
              ebookHTMLTagNameMatches(tagName, in: bytes, startingAt: index + 2),
              let tagEnd = ebookHTMLOpenTagEnd(
                in: bytes,
                startingAt: index + 2 + tagName.count
              ) else {
            index += 1
            continue
        }
        return tagEnd
    }
    return nil
}

private func ebookHTMLIndex(
    after sequence: [UInt8],
    in bytes: UnsafeBufferPointer<UInt8>,
    startingAt start: Int
) -> Int? {
    guard !sequence.isEmpty else { return start }
    var index = start
    while index <= bytes.count - sequence.count {
        if ebookHTMLBytesMatch(sequence, in: bytes, startingAt: index) {
            return index + sequence.count
        }
        index += 1
    }
    return nil
}

@inline(__always)
private func ebookHTMLBytesMatch(
    _ expected: [UInt8],
    in bytes: UnsafeBufferPointer<UInt8>,
    startingAt start: Int
) -> Bool {
    guard start >= 0, start <= bytes.count - expected.count else { return false }
    for offset in expected.indices where bytes[start + offset] != expected[offset] {
        return false
    }
    return true
}

@inline(__always)
private func ebookHTMLTagNameByte(_ byte: UInt8) -> Bool {
    (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
        || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
        || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
        || byte == UInt8(ascii: "-")
        || byte == UInt8(ascii: ":")
}

private func ebookHTMLDataRemovingBodyAttributes(
    named attributeNames: Set<[UInt8]>,
    from data: Data
) -> Data {
    guard !attributeNames.isEmpty else { return data }
    let locations = ebookHTMLDocumentTagLocations(in: data)
    guard let tagStart = locations.bodyOpenTagStart,
          let tagEnd = locations.bodyOpenTagEnd else {
        return data
    }

    let removalRanges: [Range<Int>] = data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        let contentEnd = tagEnd - 1
        var ranges = [Range<Int>]()
        var index = tagStart + 1 + ebookBodyTagName.count
        while index < contentEnd {
            let whitespaceStart = index
            while index < contentEnd, ebookHTMLAttributeWhitespace(bytes[index]) {
                index += 1
            }
            guard index < contentEnd, bytes[index] != EbookHTMLByte.slash else { break }

            let nameStart = index
            while index < contentEnd,
                  !ebookHTMLAttributeWhitespace(bytes[index]),
                  bytes[index] != EbookHTMLByte.equals,
                  bytes[index] != EbookHTMLByte.greaterThan {
                index += 1
            }
            let nameEnd = index
            guard nameStart < nameEnd else {
                index += 1
                continue
            }

            var valueCursor = index
            while valueCursor < contentEnd, ebookHTMLAttributeWhitespace(bytes[valueCursor]) {
                valueCursor += 1
            }
            var attributeEnd = nameEnd
            if valueCursor < contentEnd, bytes[valueCursor] == EbookHTMLByte.equals {
                valueCursor += 1
                while valueCursor < contentEnd, ebookHTMLAttributeWhitespace(bytes[valueCursor]) {
                    valueCursor += 1
                }
                if valueCursor < contentEnd {
                    let quote = bytes[valueCursor]
                    if quote == EbookHTMLByte.singleQuote || quote == EbookHTMLByte.doubleQuote {
                        valueCursor += 1
                        while valueCursor < contentEnd, bytes[valueCursor] != quote {
                            valueCursor += 1
                        }
                        if valueCursor < contentEnd { valueCursor += 1 }
                    } else {
                        while valueCursor < contentEnd,
                              !ebookHTMLAttributeWhitespace(bytes[valueCursor]),
                              bytes[valueCursor] != EbookHTMLByte.greaterThan {
                            valueCursor += 1
                        }
                    }
                    attributeEnd = valueCursor
                }
            }

            let nameRange = nameStart..<nameEnd
            if attributeNames.contains(where: {
                ebookHTMLASCIIEquals($0, bytes: bytes, range: nameRange)
            }) {
                ranges.append(whitespaceStart..<attributeEnd)
            }
            index = max(attributeEnd, nameEnd)
        }
        return ranges
    }
    guard !removalRanges.isEmpty else { return data }

    var result = Data()
    result.reserveCapacity(data.count - removalRanges.reduce(0) { $0 + $1.count })
    var sourceIndex = 0
    for range in removalRanges {
        result.append(data[sourceIndex..<range.lowerBound])
        sourceIndex = range.upperBound
    }
    result.append(data[sourceIndex...])
    return result
}

private func ebookHTMLDataRemovingBodyStyleProperties(
    named propertyNames: Set<String>,
    from data: Data,
    when shouldRemove: Bool
) -> Data {
    guard shouldRemove,
          !propertyNames.isEmpty,
          let styleRange = ebookHTMLDocumentTagLocations(in: data).bodyStyleValueRange else {
        return data
    }
    let style = String(decoding: data[styleRange], as: UTF8.self)
    let retainedDeclarations = ebookCSSDeclarations(in: style).filter { declaration in
        guard let colon = declaration.firstIndex(of: ":") else { return true }
        let name = declaration[..<colon]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !propertyNames.contains(name)
    }
    let replacement = retainedDeclarations.joined(separator: ";")
    guard replacement != style else { return data }

    var result = Data()
    result.reserveCapacity(data.count - styleRange.count + replacement.utf8.count)
    result.append(data[..<styleRange.lowerBound])
    result.append(contentsOf: replacement.utf8)
    result.append(data[styleRange.upperBound...])
    return result
}

private func ebookCSSDeclarations(in style: String) -> [String] {
    var declarations = [String]()
    var declarationStart = style.startIndex
    var index = style.startIndex
    var quote: Character?
    var escaped = false
    var parenthesisDepth = 0

    func appendDeclaration(endingAt end: String.Index) {
        let declaration = style[declarationStart..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !declaration.isEmpty {
            declarations.append(declaration)
        }
    }

    while index < style.endIndex {
        let character = style[index]
        if let activeQuote = quote {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == activeQuote {
                quote = nil
            }
        } else {
            switch character {
            case "\"", "'":
                quote = character
            case "(":
                parenthesisDepth += 1
            case ")":
                parenthesisDepth = max(0, parenthesisDepth - 1)
            case ";" where parenthesisDepth == 0:
                appendDeclaration(endingAt: index)
                declarationStart = style.index(after: index)
            default:
                break
            }
        }
        index = style.index(after: index)
    }
    appendDeclaration(endingAt: style.endIndex)
    return declarations
}

private func ebookHTMLAttributeValueRange(
    named attributeName: [UInt8],
    in bytes: UnsafeBufferPointer<UInt8>,
    attributesStart: Int,
    tagEnd: Int
) -> Range<Int>? {
    var index = attributesStart
    let contentEnd = tagEnd - 1
    while index < contentEnd {
        while index < contentEnd, ebookHTMLAttributeWhitespace(bytes[index]) {
            index += 1
        }
        guard index < contentEnd, bytes[index] != EbookHTMLByte.slash else {
            return nil
        }
        let nameStart = index
        while index < contentEnd,
              !ebookHTMLAttributeWhitespace(bytes[index]),
              bytes[index] != EbookHTMLByte.equals,
              bytes[index] != EbookHTMLByte.greaterThan {
            index += 1
        }
        let nameRange = nameStart..<index
        let isRequestedAttribute = ebookHTMLASCIIEquals(
            attributeName,
            bytes: bytes,
            range: nameRange
        )
        while index < contentEnd, ebookHTMLAttributeWhitespace(bytes[index]) {
            index += 1
        }
        guard index < contentEnd, bytes[index] == EbookHTMLByte.equals else {
            if isRequestedAttribute {
                return nil
            }
            continue
        }
        index += 1
        while index < contentEnd, ebookHTMLAttributeWhitespace(bytes[index]) {
            index += 1
        }
        guard index < contentEnd else { return nil }
        let quote = bytes[index]
        let valueStart: Int
        let valueEnd: Int
        if quote == EbookHTMLByte.singleQuote || quote == EbookHTMLByte.doubleQuote {
            valueStart = index + 1
            index = valueStart
            while index < contentEnd, bytes[index] != quote {
                index += 1
            }
            valueEnd = index
            if index < contentEnd {
                index += 1
            }
        } else {
            valueStart = index
            while index < contentEnd,
                  !ebookHTMLAttributeWhitespace(bytes[index]),
                  bytes[index] != EbookHTMLByte.greaterThan {
                index += 1
            }
            valueEnd = index
        }
        if isRequestedAttribute {
            return valueStart..<valueEnd
        }
    }
    return nil
}

private func ebookHTMLQuotedStyleValueRange(
    in bytes: UnsafeBufferPointer<UInt8>,
    attributesStart: Int,
    tagEnd: Int
) -> Range<Int>? {
    var index = attributesStart
    let contentEnd = tagEnd - 1
    while index < contentEnd {
        while index < contentEnd, ebookHTMLAttributeWhitespace(bytes[index]) {
            index += 1
        }
        guard index < contentEnd, bytes[index] != EbookHTMLByte.slash else {
            index += 1
            continue
        }
        let nameStart = index
        while index < contentEnd,
              !ebookHTMLAttributeWhitespace(bytes[index]),
              bytes[index] != EbookHTMLByte.equals,
              bytes[index] != EbookHTMLByte.greaterThan {
            index += 1
        }
        let isStyle = ebookHTMLASCIIEquals(ebookStyleAttributeName, bytes: bytes, range: nameStart..<index)
        while index < contentEnd, ebookHTMLAttributeWhitespace(bytes[index]) {
            index += 1
        }
        guard index < contentEnd, bytes[index] == EbookHTMLByte.equals else {
            continue
        }
        index += 1
        while index < contentEnd, ebookHTMLAttributeWhitespace(bytes[index]) {
            index += 1
        }
        guard index < contentEnd else { return nil }
        let quote = bytes[index]
        if quote == EbookHTMLByte.singleQuote || quote == EbookHTMLByte.doubleQuote {
            index += 1
            let valueStart = index
            while index < contentEnd, bytes[index] != quote {
                index += 1
            }
            if isStyle, index < contentEnd {
                return valueStart..<index
            }
            index += index < contentEnd ? 1 : 0
        } else {
            while index < contentEnd, !ebookHTMLAttributeWhitespace(bytes[index]) {
                index += 1
            }
        }
    }
    return nil
}

@inline(__always)
private func ebookHTMLAttributeWhitespace(_ byte: UInt8) -> Bool {
    byte == EbookHTMLByte.space
        || byte == EbookHTMLByte.horizontalTab
        || byte == EbookHTMLByte.lineFeed
        || byte == EbookHTMLByte.carriageReturn
}

@inline(__always)
private func ebookHTMLASCIIEquals(
    _ expected: [UInt8],
    bytes: UnsafeBufferPointer<UInt8>,
    range: Range<Int>
) -> Bool {
    guard range.count == expected.count else { return false }
    for (offset, expectedByte) in expected.enumerated() {
        if ebookLowercasedASCII(bytes[range.lowerBound + offset]) != expectedByte {
            return false
        }
    }
    return true
}

@inline(__always)
private func ebookHTMLTagNameMatches(
    _ tagName: [UInt8],
    in bytes: UnsafeBufferPointer<UInt8>,
    startingAt start: Int
) -> Bool {
    guard start <= bytes.count - tagName.count else { return false }
    for offset in tagName.indices {
        if ebookLowercasedASCII(bytes[start + offset]) != tagName[offset] {
            return false
        }
    }
    let boundaryIndex = start + tagName.count
    guard boundaryIndex < bytes.count else { return false }
    return ebookHTMLTagBoundary(bytes[boundaryIndex])
}

@inline(__always)
private func ebookLowercasedASCII(_ byte: UInt8) -> UInt8 {
    byte >= EbookHTMLByte.uppercaseA && byte <= EbookHTMLByte.uppercaseZ
        ? byte + EbookHTMLByte.lowercaseOffset
        : byte
}

@inline(__always)
private func ebookHTMLTagBoundary(_ byte: UInt8) -> Bool {
    byte == EbookHTMLByte.greaterThan
        || byte == EbookHTMLByte.slash
        || byte == EbookHTMLByte.space
        || byte == EbookHTMLByte.horizontalTab
        || byte == EbookHTMLByte.lineFeed
        || byte == EbookHTMLByte.carriageReturn
}

private func ebookHTMLOpenTagEnd(
    in bytes: UnsafeBufferPointer<UInt8>,
    startingAt start: Int
) -> Int? {
    var quote: UInt8?
    var index = start
    while index < bytes.count {
        let byte = bytes[index]
        if let activeQuote = quote {
            if byte == activeQuote {
                quote = nil
            }
        } else if byte == EbookHTMLByte.singleQuote || byte == EbookHTMLByte.doubleQuote {
            quote = byte
        } else if byte == EbookHTMLByte.greaterThan {
            return index + 1
        }
        index += 1
    }
    return nil
}
