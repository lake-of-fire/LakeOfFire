import Foundation
import SwiftSoup

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
    let direction = queryItems
        .first(where: { $0.name == "mnbWritingDirection" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard direction == "vertical" else { return nil }
    let requestedWritingMode = queryItems
        .first(where: { $0.name == "mnbWritingMode" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let writingMode = requestedWritingMode == "vertical-lr" ? "vertical-lr" : "vertical-rl"
    return EBookProcessedSectionWritingHint(direction: "vertical", writingMode: writingMode)
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
    var bodyOpenTagStart: Int?
    var bodyOpenTagEnd: Int?
    var bodyStyleValueEnd: Int?
}

private enum EbookHTMLDocumentTag {
    case html
    case head
    case body
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

private let ebookHTMLTagName = UTF8Arrays.html
private let ebookHeadTagName = UTF8Arrays.head
private let ebookBodyTagName = UTF8Arrays.body
private let ebookStyleAttributeName = UTF8Arrays.style

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
        bodyAttributeBytes.append(contentsOf: UTF8Arrays.attributeEqualsQuoteMark)
        appendEbookHTMLAttributeEscapedBytes(value, to: &bodyAttributeBytes)
        bodyAttributeBytes.append(EbookHTMLByte.doubleQuote)
    }
    var headPayload = Data("<base href=\"".utf8)
    appendEbookHTMLAttributeEscapedBytes(baseURL, to: &headPayload)
    headPayload.append(contentsOf: "\">".utf8)
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

    let authoritativeHTMLData = ebookHTMLDataRemovingBodyAttributes(
        named: Set(encodedBodyAttributes.keys.map { Array($0.lowercased().utf8) }),
        from: htmlData
    )
    let tags = ebookHTMLDocumentTagLocations(in: authoritativeHTMLData)
    var insertions = [(index: Int, data: Data)]()
    if let headTagEnd = tags.headOpenTagEnd {
        insertions.append((headTagEnd, headPayload))
    } else if let htmlTagEnd = tags.htmlOpenTagEnd {
        var head = Data("<head>".utf8)
        head.append(headPayload)
        head.append(Data("</head>".utf8))
        insertions.append((htmlTagEnd, head))
    } else {
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
            if let styleValueEnd = tags.bodyStyleValueEnd {
                var styleSuffix = Data([EbookHTMLByte.semicolon])
                styleSuffix.append(contentsOf: escapedBodyStyleDeclarations)
                insertions.append((styleValueEnd, styleSuffix))
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

private func ebookHTMLDocumentTagLocations(in data: Data) -> EbookHTMLDocumentTagLocations {
    data.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        var locations = EbookHTMLDocumentTagLocations()
        var index = 0
        while index < bytes.count {
            guard bytes[index] == EbookHTMLByte.lessThan else {
                index += 1
                continue
            }
            let nameStart = index + 1
            guard nameStart < bytes.count,
                  bytes[nameStart] != EbookHTMLByte.slash else {
                index += 1
                continue
            }
            let matchingTag: EbookHTMLDocumentTag?
            if locations.htmlOpenTagEnd == nil,
               ebookHTMLTagNameMatches(ebookHTMLTagName, in: bytes, startingAt: nameStart) {
                matchingTag = .html
            } else if locations.headOpenTagEnd == nil,
                      ebookHTMLTagNameMatches(ebookHeadTagName, in: bytes, startingAt: nameStart) {
                matchingTag = .head
            } else if locations.bodyOpenTagEnd == nil,
                      ebookHTMLTagNameMatches(ebookBodyTagName, in: bytes, startingAt: nameStart) {
                matchingTag = .body
            } else {
                matchingTag = nil
            }
            guard let matchingTag,
                  let tagEnd = ebookHTMLOpenTagEnd(in: bytes, startingAt: nameStart) else {
                index += 1
                continue
            }
            switch matchingTag {
            case .html:
                locations.htmlOpenTagEnd = tagEnd
            case .head:
                locations.headOpenTagEnd = tagEnd
            case .body:
                locations.bodyOpenTagStart = index
                locations.bodyOpenTagEnd = tagEnd
                locations.bodyStyleValueEnd = ebookHTMLQuotedStyleValueEnd(
                    in: bytes,
                    attributesStart: nameStart + ebookBodyTagName.count,
                    tagEnd: tagEnd
                )
            }
            if locations.htmlOpenTagEnd != nil,
               locations.headOpenTagEnd != nil,
               locations.bodyOpenTagEnd != nil {
                return locations
            }
            index = tagEnd
        }
        return locations
    }
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

private func ebookHTMLQuotedStyleValueEnd(
    in bytes: UnsafeBufferPointer<UInt8>,
    attributesStart: Int,
    tagEnd: Int
) -> Int? {
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
            while index < contentEnd, bytes[index] != quote {
                index += 1
            }
            if isStyle, index < contentEnd {
                return index
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
