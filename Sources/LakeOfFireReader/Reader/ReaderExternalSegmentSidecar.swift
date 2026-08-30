import CryptoKit
import CoreFoundation
import Foundation
import SwiftSoup
import SwiftUtilities

public enum ReaderCompactSegmentSidecarSchema {
    public static let currentVersion = 12
}

public struct EbookProcessedSectionPayload: Sendable {
    public let documentHTML: Data
    public let segmentSidecar: Data
    public let isAuthoritativelyProcessed: Bool

    public init(
        documentHTML: Data,
        segmentSidecar: Data
    ) {
        self.documentHTML = documentHTML
        self.segmentSidecar = segmentSidecar
        isAuthoritativelyProcessed = false
    }

    private init(
        validatedDocumentHTML documentHTML: Data,
        segmentSidecar: Data
    ) {
        self.documentHTML = documentHTML
        self.segmentSidecar = segmentSidecar
        isAuthoritativelyProcessed = true
    }

    public var combinedByteCount: Int {
        documentHTML.count + segmentSidecar.count
    }

    fileprivate static func revalidatedCachedReaderProcessing(
        documentHTML: Data,
        segmentSidecar: Data
    ) -> EbookProcessedSectionPayload? {
        let payload = EbookProcessedSectionPayload(
            validatedDocumentHTML: documentHTML,
            segmentSidecar: segmentSidecar
        )
        return ebookProcessedSectionPayloadHasDurableSegmentIdentities(payload)
            ? payload
            : nil
    }

    @_spi(TestSupport)
    public static func readerProcessingFixture(
        sourceDocumentHTML: Data,
        documentHTML: Data,
        segmentSidecar: Data
    ) -> EbookProcessedSectionPayload {
        EbookReaderProcessingCompletionProof.forTesting(
            sourceHTML: String(decoding: sourceDocumentHTML, as: UTF8.self)
        ).complete(
            documentHTML: documentHTML,
            segmentSidecar: segmentSidecar
        )
    }
}

@_spi(ReaderProcessing)
public func revalidatedReaderProcessingPayload(
    documentHTML: Data,
    segmentSidecar: Data
) -> EbookProcessedSectionPayload? {
    EbookProcessedSectionPayload.revalidatedCachedReaderProcessing(
        documentHTML: documentHTML,
        segmentSidecar: segmentSidecar
    )
}

/// A per-invocation capability created by LakeOfFire after source extraction.
/// Producers can complete only the invocation that handed them this value;
/// there is no public success factory or public initializer for the capability.
public final class EbookReaderProcessingCompletionProof: @unchecked Sendable {
    private let lock = NSLock()
    private let sourceVisibleTextDigest: String
    private var wasConsumed = false

    init?(sourceDocument: SwiftSoup.Document) {
        guard let digest = readerVisibleSourceTextDigest(sourceDocument) else { return nil }
        sourceVisibleTextDigest = digest
    }

    public func complete(
        documentHTML: Data,
        segmentSidecar: Data
    ) -> EbookProcessedSectionPayload {
        lock.lock()
        guard !wasConsumed else {
            lock.unlock()
            return EbookProcessedSectionPayload(
                documentHTML: documentHTML,
                segmentSidecar: segmentSidecar
            )
        }
        wasConsumed = true
        lock.unlock()
        guard let markedDocumentHTML = readerDocumentHTMLByInstallingOwnershipMarker(
            documentHTML,
            segmentSidecar: segmentSidecar,
            expectedSourceVisibleTextDigest: sourceVisibleTextDigest
        ) else {
            return EbookProcessedSectionPayload(
                documentHTML: documentHTML,
                segmentSidecar: segmentSidecar
            )
        }
        return EbookProcessedSectionPayload(
            validatedDocumentHTML: markedDocumentHTML,
            segmentSidecar: segmentSidecar
        )
    }

    static func forTesting(sourceHTML: String) -> EbookReaderProcessingCompletionProof {
        let document = try! SwiftSoup.parse(sourceHTML)
        return EbookReaderProcessingCompletionProof(sourceDocument: document)!
    }
}

extension EbookProcessedSectionPayload {
    /// Internal fixture/legacy-byte admission. Production cross-package callers
    /// receive a per-invocation proof from LakeOfFire instead.
    #if DEBUG
    static func successfulReaderProcessing(
        documentHTML: Data,
        segmentSidecar: Data
    ) -> EbookProcessedSectionPayload {
        EbookReaderProcessingCompletionProof.forTesting(
            sourceHTML: String(decoding: documentHTML, as: UTF8.self)
        ).complete(
            documentHTML: documentHTML,
            segmentSidecar: segmentSidecar
        )
    }
    #endif
}

private enum ReaderPretransformedEbookSidecarContract {
    static let transportMarkerName = "mnb-pretransformed-ebook-sidecar"
    static let contractVersion = 2
    static let coverageDigestAttribute = "data-mnb-reader-coverage-digest"
}

private struct ReaderSegmentSidecarIdentityProjection {
    let runtimeIdentifier: String
    let segmentHash: String
    let surfaceText: String
    let sentenceIdentifier: String
    let paragraphIdentifier: String
}

public func ebookProcessedSectionPayloadHasDurableSegmentIdentities(
    _ payload: EbookProcessedSectionPayload
) -> Bool {
    guard payload.isAuthoritativelyProcessed else { return false }
    guard let html = String(data: payload.documentHTML, encoding: .utf8),
          let document = try? SwiftSoup.parse(html),
          let documentSegmentIdentifiers = generatedReaderSegmentIdentifiers(in: document) else {
        return false
    }
    guard readerDocumentHasCompleteJapaneseCoverage(document) else { return false }
    let canonicalSidecars = (try? document.select("script#mnb-segment-metadata").array()) ?? []
    let transportMarkers = readerPretransformedEbookTransportMarkers(in: document)
    guard canonicalSidecars.isEmpty else { return false }
    guard !payload.segmentSidecar.isEmpty else {
        return documentSegmentIdentifiers.isEmpty
            && transportMarkers.count == 1
            && transportMarkers.first.map {
                readerSegmentFreeTransportMarkerIsValid(
                    $0,
                    document: document
                )
            } == true
    }
    guard !documentSegmentIdentifiers.isEmpty,
          transportMarkers.count == 1,
          let marker = transportMarkers.first,
          readerPretransformedEbookTransportMarkerIsValid(
              marker,
              segmentSidecar: payload.segmentSidecar,
              document: document,
              documentSegmentIdentifiers: documentSegmentIdentifiers
          ) else {
        return false
    }
    return true
}

private func readerDocumentHTMLByInstallingOwnershipMarker(
    _ documentHTML: Data,
    segmentSidecar: Data,
    expectedSourceVisibleTextDigest: String
) -> Data? {
    guard let html = String(data: documentHTML, encoding: .utf8),
          let document = try? SwiftSoup.parse(html),
          let documentSegmentIdentifiers = generatedReaderSegmentIdentifiers(in: document),
          readerDocumentHasCompleteJapaneseCoverage(document),
          readerVisibleSourceTextDigest(document) == expectedSourceVisibleTextDigest,
          let coverageDigest = readerVisibleContentCoverageDigest(document) else {
        return nil
    }
    let canonicalSidecars = (try? document.select("script#mnb-segment-metadata").array()) ?? []
    guard canonicalSidecars.isEmpty else { return nil }
    let existingMarkers = readerPretransformedEbookTransportMarkers(in: document)
    guard !segmentSidecar.isEmpty else {
        guard documentSegmentIdentifiers.isEmpty,
              let sentences = try? document.getElementsByTag("m-s").array(),
              readerSentenceOwnershipIsValid(sentences) else { return nil }
        if existingMarkers.count == 1,
           let marker = existingMarkers.first,
           readerSegmentFreeTransportMarkerIsValid(marker, document: document) {
            return documentHTML
        }
        guard existingMarkers.isEmpty else { return nil }
        return readerDocumentHTMLByInsertingOwnershipMarker(
            readerPretransformedEbookOwnershipMarker(
                segmentSidecar: segmentSidecar,
                segmentCount: 0,
                sentenceCount: sentences.count,
                coverageDigest: coverageDigest
            ),
            into: documentHTML,
            segmentSidecar: segmentSidecar,
            expectsSegments: false
        )
    }
    guard !documentSegmentIdentifiers.isEmpty,
          let projections = validatedReaderSegmentSidecarIdentityProjections(
              segmentSidecar,
              generatedSegmentIdentifiers: documentSegmentIdentifiers
          ),
          readerSegmentSidecarProjectionsMatchDocument(projections, document: document),
          let sentences = try? document.getElementsByTag("m-s").array(),
          !sentences.isEmpty else {
        return nil
    }
    guard readerSentenceOwnershipIsValid(sentences) else { return nil }
    if existingMarkers.count == 1,
       let existingMarker = existingMarkers.first,
       readerPretransformedEbookTransportMarkerIsValid(
           existingMarker,
           segmentSidecar: segmentSidecar,
           document: document,
           documentSegmentIdentifiers: documentSegmentIdentifiers
       ) {
        return documentHTML
    }
    guard existingMarkers.isEmpty else { return nil }

    let marker = readerPretransformedEbookOwnershipMarker(
        segmentSidecar: segmentSidecar,
        segmentCount: projections.count,
        sentenceCount: sentences.count,
        coverageDigest: coverageDigest
    )
    return readerDocumentHTMLByInsertingOwnershipMarker(
        marker,
        into: documentHTML,
        segmentSidecar: segmentSidecar,
        expectsSegments: true
    )
}

private func readerDocumentHTMLByInsertingOwnershipMarker(
    _ marker: Data,
    into documentHTML: Data,
    segmentSidecar: Data,
    expectsSegments: Bool
) -> Data? {
    guard let insertionIndex = readerOwnershipMarkerInsertionIndex(in: documentHTML) else {
        return nil
    }
    var markedDocumentHTML = Data()
    markedDocumentHTML.reserveCapacity(documentHTML.count + marker.count)
    markedDocumentHTML.append(documentHTML[..<insertionIndex])
    markedDocumentHTML.append(marker)
    markedDocumentHTML.append(documentHTML[insertionIndex...])

    guard let markedHTML = String(data: markedDocumentHTML, encoding: .utf8),
          let markedDocument = try? SwiftSoup.parse(markedHTML),
          let markedIdentifiers = generatedReaderSegmentIdentifiers(in: markedDocument),
          readerPretransformedEbookTransportMarkers(in: markedDocument).count == 1,
          let installedMarker = readerPretransformedEbookTransportMarkers(in: markedDocument).first else {
        return nil
    }
    let markerIsValid = expectsSegments
        ? readerPretransformedEbookTransportMarkerIsValid(
            installedMarker,
            segmentSidecar: segmentSidecar,
            document: markedDocument,
            documentSegmentIdentifiers: markedIdentifiers
        )
        : markedIdentifiers.isEmpty
            && readerSegmentFreeTransportMarkerIsValid(
                installedMarker,
                document: markedDocument
            )
    guard markerIsValid else { return nil }
    return markedDocumentHTML
}

private func readerSentenceOwnershipIsValid(_ sentences: [Element]) -> Bool {
    var identifiers = Set<String>()
    for sentence in sentences {
        guard let identifier = try? sentence.attr("sid"),
              !identifier.isEmpty,
              identifiers.insert(identifier).inserted,
              (try? sentence.attr("o")) == "true" else {
            return false
        }
    }
    return true
}

private let readerCoverageExcludedElementNames: Set<String> = [
    "script", "style", "rt", "rp", "template", "noscript",
]

private func readerDocumentHasCompleteJapaneseCoverage(
    _ document: SwiftSoup.Document
) -> Bool {
    guard let body = document.body() else { return false }
    return readerNodeHasCompleteJapaneseCoverage(body, ownedSentenceIdentifier: nil)
}

private func readerNodeHasCompleteJapaneseCoverage(
    _ node: Node,
    ownedSentenceIdentifier: String?
) -> Bool {
    var sentenceIdentifier = ownedSentenceIdentifier
    if let element = node as? Element {
        let tagName = element.tagName().lowercased()
        if readerCoverageExcludedElementNames.contains(tagName) { return true }
        if tagName == "m-s" {
            guard (try? element.attr("o")) == "true",
                  let identifier = try? element.attr("sid"),
                  !identifier.isEmpty else {
                return false
            }
            sentenceIdentifier = identifier
        }
    }
    if let text = node as? TextNode,
       readerTextContainsJapaneseLanguageScalar(text.getWholeText()),
       sentenceIdentifier == nil {
        return false
    }
    for index in 0..<node.childNodeSize() where !readerNodeHasCompleteJapaneseCoverage(
        node.childNode(index),
        ownedSentenceIdentifier: sentenceIdentifier
    ) {
        return false
    }
    return true
}

/// Hashes the visible text tree and its owned-sentence boundaries rather than
/// serialized markup. Provenance restamps and XHTML formatting stay byte-stable,
/// while appended or moved visible text invalidates the cached authority marker.
private func readerVisibleContentCoverageDigest(
    _ document: SwiftSoup.Document
) -> String? {
    guard let body = document.body() else { return nil }
    var bytes = Data()
    readerAppendVisibleCoverageBytes(
        body,
        ownedSentenceIdentifier: nil,
        to: &bytes
    )
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

func readerVisibleSourceTextDigest(_ document: SwiftSoup.Document) -> String? {
    guard let body = document.body() else { return nil }
    var bytes = Data()
    readerAppendVisibleSourceTextBytes(body, to: &bytes)
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func readerAppendVisibleSourceTextBytes(_ node: Node, to bytes: inout Data) {
    if let element = node as? Element,
       readerCoverageExcludedElementNames.contains(element.tagName().lowercased()) {
        return
    }
    if let ruby = node as? Element,
       ruby.tagName().lowercased() == "ruby",
       !readerRubyIsGenerated(ruby) {
        readerAppendCoverageField("#source-ruby", to: &bytes)
        readerAppendCoverageField(
            readerSourceTextExcludingRubyAnnotations(ruby),
            to: &bytes
        )
        readerAppendSourceRubyAnnotationBytes(ruby, to: &bytes)
    }
    if let text = node as? TextNode {
        bytes.append(contentsOf: text.getWholeText().utf8)
    }
    for index in 0..<node.childNodeSize() {
        readerAppendVisibleSourceTextBytes(node.childNode(index), to: &bytes)
    }
}

private func readerRubyIsGenerated(_ ruby: Element) -> Bool {
    (try? ruby.hasClass("mnb-gen")) == true
        || (try? ruby.attr("data-mnb-generated")) == "true"
}

private func readerAppendSourceRubyAnnotationBytes(
    _ node: Node,
    to bytes: inout Data
) {
    if let element = node as? Element {
        let tagName = element.tagName().lowercased()
        if tagName == "rt" || tagName == "rp" {
            readerAppendCoverageField(tagName, to: &bytes)
            readerAppendCoverageField(
                readerRubyAnnotationText(element),
                to: &bytes
            )
            return
        }
    }
    for index in 0..<node.childNodeSize() {
        readerAppendSourceRubyAnnotationBytes(node.childNode(index), to: &bytes)
    }
}

private func readerRubyAnnotationText(_ node: Node) -> String {
    if let text = node as? TextNode {
        return text.getWholeText()
    }
    var result = ""
    for index in 0..<node.childNodeSize() {
        result += readerRubyAnnotationText(node.childNode(index))
    }
    return result
}

private func readerAppendVisibleCoverageBytes(
    _ node: Node,
    ownedSentenceIdentifier: String?,
    to bytes: inout Data
) {
    var sentenceIdentifier = ownedSentenceIdentifier
    if let element = node as? Element {
        let tagName = element.tagName().lowercased()
        if readerElementIsFinalAuthorityMarker(element) {
            return
        }
        if tagName == "m-s" {
            sentenceIdentifier = (try? element.attr("sid")) ?? ""
        }
        readerAppendCoverageField("<\(tagName)>", to: &bytes)
    }
    if let text = node as? TextNode {
        readerAppendCoverageField(sentenceIdentifier ?? "-", to: &bytes)
        readerAppendCoverageField(text.getWholeText(), to: &bytes)
    } else if let data = node as? DataNode {
        readerAppendCoverageField("#data", to: &bytes)
        readerAppendCoverageField(data.getWholeData(), to: &bytes)
    } else if let comment = node as? Comment {
        readerAppendCoverageField("#comment", to: &bytes)
        readerAppendCoverageField(comment.getData(), to: &bytes)
    }
    for index in 0..<node.childNodeSize() {
        readerAppendVisibleCoverageBytes(
            node.childNode(index),
            ownedSentenceIdentifier: sentenceIdentifier,
            to: &bytes
        )
    }
    if let element = node as? Element,
       !readerElementIsFinalAuthorityMarker(element) {
        readerAppendCoverageField("</\(element.tagName().lowercased())>", to: &bytes)
    }
}

private func readerElementIsFinalAuthorityMarker(_ element: Element) -> Bool {
    element.tagName().lowercased() == "meta"
        && (try? element.attr("name"))
            == ReaderPretransformedEbookSidecarContract.transportMarkerName
}

private func readerAppendCoverageField(_ value: String, to bytes: inout Data) {
    let field = Data(value.utf8)
    var length = UInt64(field.count).littleEndian
    withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
    bytes.append(field)
}

private func readerTextContainsJapaneseLanguageScalar(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3005...0x3007, 0x3031...0x3035, 0x303B,
             0x3040...0x30FF, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF66...0xFF9F,
             0x1AFF0...0x1AFFF, 0x1B000...0x1B12F,
             0x20000...0x3134F:
            true
        default:
            false
        }
    }
}

private func readerSegmentFreeTransportMarkerIsValid(
    _ marker: Element,
    document: SwiftSoup.Document
) -> Bool {
    guard (try? marker.attr("data-mnb-pretransformed-ebook")) == "true",
          (try? marker.attr("data-mnb-sidecar-schema-version"))
            == String(ReaderCompactSegmentSidecarSchema.currentVersion),
          (try? marker.attr("data-mnb-sidecar-contract-version"))
            == String(ReaderPretransformedEbookSidecarContract.contractVersion),
          (try? marker.attr("data-mnb-sidecar-revision"))
            == String(stableHash(data: Data()), radix: 16, uppercase: true),
          (try? marker.attr("data-mnb-sidecar-segment-count")) == "0",
          let coverageDigest = readerVisibleContentCoverageDigest(document),
          (try? marker.attr(ReaderPretransformedEbookSidecarContract.coverageDigestAttribute))
            == coverageDigest,
          let sentenceCountValue = try? marker.attr("data-mnb-sidecar-sentence-count"),
          let sentenceCount = exactNonnegativeDecimalInteger(sentenceCountValue),
          let sentences = try? document.getElementsByTag("m-s").array(),
          sentences.count == sentenceCount,
          readerSentenceOwnershipIsValid(sentences) else {
        return false
    }
    return true
}

private func readerPretransformedEbookOwnershipMarker(
    segmentSidecar: Data,
    segmentCount: Int,
    sentenceCount: Int,
    coverageDigest: String
) -> Data {
    Data("""
    <meta name="\(ReaderPretransformedEbookSidecarContract.transportMarkerName)" data-mnb-pretransformed-ebook="true" data-mnb-sidecar-schema-version="\(ReaderCompactSegmentSidecarSchema.currentVersion)" data-mnb-sidecar-contract-version="\(ReaderPretransformedEbookSidecarContract.contractVersion)" data-mnb-sidecar-revision="\(String(stableHash(data: segmentSidecar), radix: 16, uppercase: true))" data-mnb-sidecar-segment-count="\(segmentCount)" data-mnb-sidecar-sentence-count="\(sentenceCount)" \(ReaderPretransformedEbookSidecarContract.coverageDigestAttribute)="\(coverageDigest)" />
    """.utf8)
}

private func readerOwnershipMarkerInsertionIndex(in html: Data) -> Data.Index? {
    for tagName in ["head", "body", "html"] {
        if let index = openingElementTagEnd(named: tagName, in: html) {
            return index
        }
    }
    return html.startIndex
}

private func openingElementTagEnd(named expectedName: String, in html: Data) -> Data.Index? {
    let bytes = [UInt8](html)
    let expected = Array(expectedName.utf8)
    var cursor = 0
    while cursor < bytes.count {
        guard bytes[cursor] == UInt8(ascii: "<") else {
            cursor += 1
            continue
        }
        let nameStart = cursor + 1
        let nameEnd = nameStart + expected.count
        guard nameEnd < bytes.count,
              asciiBytesEqualIgnoringCase(bytes[nameStart..<nameEnd], expected),
              isReaderTagBoundary(bytes[nameEnd]) else {
            cursor += 1
            continue
        }
        var quote: UInt8?
        var tagCursor = nameEnd
        while tagCursor < bytes.count {
            let byte = bytes[tagCursor]
            if let activeQuote = quote {
                if byte == activeQuote { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return html.index(html.startIndex, offsetBy: tagCursor + 1)
            }
            tagCursor += 1
        }
        return nil
    }
    return nil
}

private func asciiBytesEqualIgnoringCase(
    _ candidate: ArraySlice<UInt8>,
    _ expectedLowercase: [UInt8]
) -> Bool {
    guard candidate.count == expectedLowercase.count else { return false }
    return zip(candidate, expectedLowercase).allSatisfy { byte, expected in
        let lowered = (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            ? byte + 32 : byte
        return lowered == expected
    }
}

private func isReaderTagBoundary(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: ">")
        || byte == UInt8(ascii: "/")
        || byte == UInt8(ascii: " ")
        || byte == UInt8(ascii: "\t")
        || byte == UInt8(ascii: "\n")
        || byte == UInt8(ascii: "\r")
}

private func readerPretransformedEbookTransportMarkers(
    in document: SwiftSoup.Document
) -> [Element] {
    ((try? document.getElementsByTag("meta").array()) ?? []).filter {
        (try? $0.attr("name"))
            == ReaderPretransformedEbookSidecarContract.transportMarkerName
    }
}

private func readerPretransformedEbookTransportMarkerIsValid(
    _ marker: Element,
    segmentSidecar: Data,
    document: SwiftSoup.Document,
    documentSegmentIdentifiers: [String]
) -> Bool {
    guard (try? marker.attr("data-mnb-pretransformed-ebook")) == "true",
          (try? marker.attr("data-mnb-sidecar-schema-version"))
            == String(ReaderCompactSegmentSidecarSchema.currentVersion),
          (try? marker.attr("data-mnb-sidecar-contract-version"))
            == String(ReaderPretransformedEbookSidecarContract.contractVersion),
          let coverageDigest = readerVisibleContentCoverageDigest(document),
          (try? marker.attr(ReaderPretransformedEbookSidecarContract.coverageDigestAttribute))
            == coverageDigest,
          (try? marker.attr("data-mnb-sidecar-revision"))
            == String(stableHash(data: segmentSidecar), radix: 16, uppercase: true),
          let segmentCountValue = try? marker.attr("data-mnb-sidecar-segment-count"),
          let segmentCount = exactPositiveDecimalInteger(segmentCountValue),
          segmentCount == documentSegmentIdentifiers.count,
          let sentenceCountValue = try? marker.attr("data-mnb-sidecar-sentence-count"),
          let sentenceCount = exactPositiveDecimalInteger(sentenceCountValue),
          let projections = validatedReaderSegmentSidecarIdentityProjections(
              segmentSidecar,
              generatedSegmentIdentifiers: documentSegmentIdentifiers
          ),
          projections.count == segmentCount,
          let sentences = try? document.getElementsByTag("m-s").array(),
          sentences.count == sentenceCount else {
        return false
    }
    var sentenceIdentifiers = Set<String>()
    for sentence in sentences {
        guard let identifier = try? sentence.attr("sid"),
              !identifier.isEmpty,
              sentenceIdentifiers.insert(identifier).inserted,
              (try? sentence.attr("o")) == "true" else {
            return false
        }
    }
    return readerSegmentSidecarProjectionsMatchDocument(projections, document: document)
}

private func readerSegmentSidecarProjectionsMatchDocument(
    _ projections: [ReaderSegmentSidecarIdentityProjection],
    document: SwiftSoup.Document
) -> Bool {
    guard let segmentElements = try? document.getElementsByTag("m-m").array(),
          segmentElements.count == projections.count else { return false }
    for (segment, projection) in zip(segmentElements, projections) {
        guard (try? segment.attr("id")) == projection.runtimeIdentifier,
              let sentence = nearestReaderAncestor(named: "m-s", from: segment),
              let paragraph = nearestReaderAncestor(named: "m-c", from: segment),
              (try? sentence.attr("sid")) == projection.sentenceIdentifier,
              (try? sentence.attr("o")) == "true",
              (try? paragraph.attr("pid")) == projection.paragraphIdentifier,
              canonicalReaderSegmentSurface(segment) == projection.surfaceText else {
            return false
        }
    }
    return true
}

private func canonicalReaderSegmentSurface(_ segment: Element) -> String? {
    readerSourceTextExcludingRubyAnnotations(segment)
}

private func readerSourceTextExcludingRubyAnnotations(_ node: Node) -> String {
    if let element = node as? Element {
        let tagName = element.tagNameNormal()
        if tagName == "rt" || tagName == "rp" { return "" }
    }
    if let text = node as? TextNode { return text.getWholeText() }
    var result = ""
    for index in 0..<node.childNodeSize() {
        result += readerSourceTextExcludingRubyAnnotations(node.childNode(index))
    }
    return result
}

private func nearestReaderAncestor(named tagName: String, from element: Element) -> Element? {
    var candidate = element.parent() as? Element
    while let current = candidate {
        if current.tagNameNormal() == tagName { return current }
        candidate = current.parent() as? Element
    }
    return nil
}

private func exactPositiveDecimalInteger(_ value: String) -> Int? {
    guard let integer = exactNonnegativeDecimalInteger(value), integer > 0 else {
        return nil
    }
    return integer
}

private func exactNonnegativeDecimalInteger(_ value: String) -> Int? {
    guard !value.isEmpty,
          value.unicodeScalars.allSatisfy({
              $0.isASCII && CharacterSet.decimalDigits.contains($0)
          }),
          let integer = Int(value), integer >= 0, String(integer) == value else {
        return nil
    }
    return integer
}

private func validatedReaderSegmentSidecarIdentityProjections(
    _ sidecar: Data,
    generatedSegmentIdentifiers: [String]
) -> [ReaderSegmentSidecarIdentityProjection]? {
    guard let object = try? JSONSerialization.jsonObject(with: sidecar),
          let root = object as? [String: Any],
          exactNonnegativeJSONInteger(root["v"])
            == ReaderCompactSegmentSidecarSchema.currentVersion,
          let tables = root["t"] as? [String: Any],
          compactSidecarTablesAreValid(tables),
          let segments = root["s"] as? [[Any]],
          segments.count == generatedSegmentIdentifiers.count else {
        return nil
    }

    func tableValue(_ key: String, tuple: [Any], index: Int) -> Any? {
        guard tuple.indices.contains(index),
              let tableIndex = exactNonnegativeJSONInteger(tuple[index]),
              let table = tables[key] as? [Any],
              table.indices.contains(tableIndex) else {
            return nil
        }
        return table[tableIndex]
    }

    func optionalReferenceIsValid(_ key: String, tuple: [Any], index: Int) -> Bool {
        guard tuple.indices.contains(index) else { return false }
        return tuple[index] is NSNull || tableValue(key, tuple: tuple, index: index) != nil
    }

    var identifiers = Set<String>()
    var projections = [ReaderSegmentSidecarIdentityProjection]()
    projections.reserveCapacity(segments.count)
    for tuple in segments {
        guard (11...12).contains(tuple.count),
              let token = tuple.first as? String,
              let identifier = expandedReaderSegmentIdentifier(from: token),
              identifiers.insert(identifier).inserted,
              let segmentHash = tableValue("h", tuple: tuple, index: 1) as? String,
              !segmentHash.isEmpty,
              optionalReferenceIsValid("j", tuple: tuple, index: 2),
              optionalReferenceIsValid("n", tuple: tuple, index: 3),
              optionalReferenceIsValid("s", tuple: tuple, index: 4),
              optionalReferenceIsValid("ns", tuple: tuple, index: 5),
              optionalReferenceIsValid("p", tuple: tuple, index: 6),
              optionalJLPTLevelIsValid(tuple[7]),
              let surface = tableValue("x", tuple: tuple, index: 8) as? String,
              !surface.isEmpty,
              let sentence = tableValue("sid", tuple: tuple, index: 9) as? String,
              !sentence.isEmpty,
              let paragraph = tableValue("pid", tuple: tuple, index: 10) as? String,
              !paragraph.isEmpty,
              tuple.count == 11 || tableValue("res", tuple: tuple, index: 11) != nil else {
            return nil
        }
        projections.append(ReaderSegmentSidecarIdentityProjection(
            runtimeIdentifier: identifier,
            segmentHash: segmentHash,
            surfaceText: surface,
            sentenceIdentifier: sentence,
            paragraphIdentifier: paragraph
        ))
    }
    let documentIdentifierSet = Set(documentSegmentIdentifiers)
    guard documentIdentifierSet.count == documentSegmentIdentifiers.count,
          identifiers == documentIdentifierSet,
          projections.map(\.runtimeIdentifier) == generatedSegmentIdentifiers else {
        return nil
    }
    return projections
}

private let maximumExactJSONInteger = 9_007_199_254_740_991

private func exactNonnegativeJSONInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
    }
    let doubleValue = number.doubleValue
    guard doubleValue.isFinite,
          doubleValue >= 0,
          doubleValue.rounded(.towardZero) == doubleValue,
          doubleValue <= Double(maximumExactJSONInteger),
          doubleValue < Double(Int.max) else {
        return nil
    }
    return Int(doubleValue)
}

private func exactPositiveJSONInteger(_ value: Any?) -> Int? {
    guard let integer = exactNonnegativeJSONInteger(value), integer > 0 else { return nil }
    return integer
}

private func optionalJLPTLevelIsValid(_ value: Any) -> Bool {
    if value is NSNull { return true }
    guard let level = exactNonnegativeJSONInteger(value) else { return false }
    return (1...5).contains(level)
}

private func compactSidecarTablesAreValid(_ tables: [String: Any]) -> Bool {
    func entryIDTableIsValid(_ key: String) -> Bool {
        guard let rows = tables[key] as? [Any] else { return false }
        return rows.allSatisfy { row in
            guard let identifiers = row as? [Any] else { return false }
            return identifiers.allSatisfy { exactPositiveJSONInteger($0) != nil }
        }
    }
    func stringTableIsValid(_ key: String) -> Bool {
        guard let values = tables[key] as? [Any] else { return false }
        return values.allSatisfy { ($0 as? String)?.isEmpty == false }
    }
    guard entryIDTableIsValid("j"), entryIDTableIsValid("n"),
          stringTableIsValid("s"), stringTableIsValid("ns"),
          stringTableIsValid("p"), stringTableIsValid("h"),
          stringTableIsValid("x"), stringTableIsValid("sid"),
          stringTableIsValid("pid") else {
        return false
    }
    if let resolutions = tables["res"], !(resolutions is [Any]) { return false }
    if let fingerprints = tables["f"] {
        guard fingerprints is NSNull || stringTableIsValid("f") else { return false }
    }
    return true
}

private func expandedReaderSegmentIdentifier(from token: String) -> String? {
    guard let first = token.first else { return nil }
    if first == "!" {
        let identifier = String(token.dropFirst())
        return identifier.isEmpty ? nil : identifier
    }
    if first == "~" {
        let suffix = String(token.dropFirst())
        return suffix.isEmpty ? nil : "_m" + suffix
    }
    // The producer strips only the common `mnb-s` prefix. Its suffix may
    // contain separators such as the hyphens used by body/chunk identifiers.
    return "mnb-s" + token
}

private func generatedReaderSegmentIdentifiers(
    in document: SwiftSoup.Document
) -> [String]? {
    guard let elements = try? document.select("m-m").array() else {
        return nil
    }
    var identifiers = [String]()
    identifiers.reserveCapacity(elements.count)
    for element in elements {
        guard let identifier = try? element.attr("id"), !identifier.isEmpty else {
            return nil
        }
        identifiers.append(identifier)
    }
    return identifiers
}

struct ReaderExternalSegmentSidecarEntry: Sendable {
    let data: Data
    let signature: String
}

final class ReaderExternalSegmentSidecarStore: @unchecked Sendable {
    static let shared = ReaderExternalSegmentSidecarStore()

    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)
    private static let lowNibbleMask: UInt8 = 0x0F

    private let lock = NSLock()
    private let diskLock = NSLock()
    private let totalByteLimit: Int
    private let countLimit: Int
    private let diskByteLimit: Int
    private let diskCountLimit: Int
    private let maximumDiskAge: TimeInterval
    private let directoryURL: URL
    private var entries = [String: ReaderExternalSegmentSidecarEntry]()
    private var durableTokens = Set<String>()
    private var tokensInAccessOrder = [String]()
    private var totalBytes = 0

    init(
        directoryURL: URL = ReaderExternalSegmentSidecarStore.defaultDirectoryURL,
        totalByteLimit: Int = 24 * 1024 * 1024,
        countLimit: Int = 32,
        diskByteLimit: Int = 256 * 1024 * 1024,
        diskCountLimit: Int = 1_024,
        maximumDiskAge: TimeInterval = 90 * 24 * 60 * 60,
        now: Date = Date()
    ) {
        self.directoryURL = directoryURL
        self.totalByteLimit = max(totalByteLimit, 1)
        self.countLimit = max(countLimit, 1)
        self.diskByteLimit = max(diskByteLimit, 1)
        self.diskCountLimit = max(diskCountLimit, 1)
        self.maximumDiskAge = max(maximumDiskAge, 0)
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        var resourceURL = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(resourceValues)
        _ = pruneDiskCache(now: now)
    }

    func insert(_ data: Data) -> (token: String, signature: String)? {
        let token = Self.contentToken(for: data)
        let signature = "sha256:\(data.count):\(token)"
        let entry = ReaderExternalSegmentSidecarEntry(data: data, signature: signature)
        // An entry larger than both tiers could never be served while honoring
        // either configured byte budget. Do not publish a dangling URL for it.
        guard data.count <= totalByteLimit || data.count <= diskByteLimit else {
            return nil
        }
        let isDurable = data.count <= diskByteLimit
            && persistIfNeeded(data, token: token)

        lock.lock()
        insertIntoMemory(entry, token: token, isDurable: isDurable)
        let isMemoryResident = entries[token] != nil
        lock.unlock()
        guard isDurable || isMemoryResident else { return nil }
        return (token, signature)
    }

    func entry(for token: String) -> ReaderExternalSegmentSidecarEntry? {
        guard Self.isValidToken(token) else { return nil }
        lock.lock()
        if let entry = entries[token] {
            touch(token)
            lock.unlock()
            return entry
        }
        lock.unlock()

        let fileURL = directoryURL.appendingPathComponent(token, isDirectory: false)
        diskLock.lock()
        let diskData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let dataIsValid = diskData.map { Self.contentToken(for: $0) == token }
            ?? false
        if dataIsValid {
            touchDiskFile(fileURL)
        }
        diskLock.unlock()
        guard let data = diskData, dataIsValid else {
            return nil
        }
        let entry = ReaderExternalSegmentSidecarEntry(
            data: data,
            signature: "sha256:\(data.count):\(token)"
        )
        lock.lock()
        insertIntoMemory(entry, token: token, isDurable: true)
        lock.unlock()
        return entry
    }

    private func persistIfNeeded(_ data: Data, token: String) -> Bool {
        diskLock.lock()
        defer { diskLock.unlock() }
        let fileURL = directoryURL.appendingPathComponent(token, isDirectory: false)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let storedData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
               Self.contentToken(for: storedData) == token {
                touchDiskFile(fileURL)
                return true
            }
        }
        do {
            try data.write(to: fileURL, options: [.atomic])
            // Enforce the disk budget during long-lived reader sessions, not
            // only the next time this process constructs the store.
            guard pruneDiskCache(now: Date(), preserving: token) else {
                // If older files cannot be removed, keep the configured disk
                // bound authoritative and fall back to the bounded memory tier.
                try? FileManager.default.removeItem(at: fileURL)
                return false
            }
            return FileManager.default.fileExists(atPath: fileURL.path)
        } catch {
            return false
        }
    }

    private func insertIntoMemory(
        _ entry: ReaderExternalSegmentSidecarEntry,
        token: String,
        isDurable: Bool
    ) {
        if let previous = entries.updateValue(entry, forKey: token) {
            totalBytes -= previous.data.count
        }
        if isDurable {
            durableTokens.insert(token)
        } else {
            durableTokens.remove(token)
        }
        touch(token)
        totalBytes += entry.data.count
        evictEntriesIfNeeded()
    }

    private func touch(_ token: String) {
        tokensInAccessOrder.removeAll { $0 == token }
        tokensInAccessOrder.append(token)
    }

    private func evictEntriesIfNeeded() {
        while entries.count > countLimit || totalBytes > totalByteLimit {
            // Prefer evicting entries that can be reloaded from disk. If disk
            // persistence failed, still evict the oldest in-memory entry so a
            // disk-full or permission failure cannot disable the memory bound.
            guard let index = tokensInAccessOrder.firstIndex(
                where: durableTokens.contains
            ) ?? tokensInAccessOrder.indices.first else { break }
            let token = tokensInAccessOrder.remove(at: index)
            durableTokens.remove(token)
            if let removed = entries.removeValue(forKey: token) {
                totalBytes -= removed.data.count
            }
        }
    }

    @discardableResult
    private func pruneDiskCache(
        now: Date,
        preserving preservedToken: String? = nil
    ) -> Bool {
        struct DiskEntry {
            let url: URL
            let byteCount: Int
            let lastUsedAt: Date
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var entries = urls.compactMap { url -> DiskEntry? in
            guard Self.isValidToken(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                return nil
            }
            return DiskEntry(
                url: url,
                byteCount: max(values.fileSize ?? 0, 0),
                lastUsedAt: values.contentModificationDate ?? .distantPast
            )
        }
        entries.sort {
            if $0.lastUsedAt != $1.lastUsedAt {
                return $0.lastUsedAt < $1.lastUsedAt
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }

        var totalDiskBytes = entries.reduce(into: 0) { total, entry in
            let (sum, overflow) = total.addingReportingOverflow(entry.byteCount)
            total = overflow ? Int.max : sum
        }
        var remainingCount = entries.count
        let oldestAllowedDate = now.addingTimeInterval(-maximumDiskAge)
        for entry in entries {
            guard entry.url.lastPathComponent != preservedToken else { continue }
            let isExpired = entry.lastUsedAt < oldestAllowedDate
            let isOverBudget = remainingCount > diskCountLimit || totalDiskBytes > diskByteLimit
            guard isExpired || isOverBudget else { continue }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            remainingCount -= 1
            totalDiskBytes = max(totalDiskBytes - entry.byteCount, 0)
        }
        return remainingCount <= diskCountLimit && totalDiskBytes <= diskByteLimit
    }

    func memoryUsageForTesting() -> (byteCount: Int, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (totalBytes, entries.count)
    }

    func diskUsageForTesting() -> (byteCount: Int, count: Int) {
        diskLock.lock()
        defer { diskLock.unlock() }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.reduce(into: (byteCount: 0, count: 0)) { usage, url in
            guard Self.isValidToken(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return }
            usage.byteCount += max(values.fileSize ?? 0, 0)
            usage.count += 1
        }
    }

    private func touchDiskFile(_ fileURL: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
    }

    private static func contentToken(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var tokenBytes = [UInt8]()
        tokenBytes.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            tokenBytes.append(lowercaseHexDigits[Int(byte >> 4)])
            tokenBytes.append(lowercaseHexDigits[Int(byte & lowNibbleMask)])
        }
        return String(decoding: tokenBytes, as: UTF8.self)
    }

    private static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == SHA256.Digest.byteCount * 2
            && token.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }

    private static var defaultDirectoryURL: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("ManabiReaderSegmentSidecars-v1", isDirectory: true)
    }
}

enum ReaderExternalSegmentSidecarScheme: String, Sendable {
    case ebook
    case internalReader = "internal"

    fileprivate func endpointURL(token: String) -> String {
        switch self {
        case .ebook:
            return "ebook://ebook/processed-section-sidecar/\(token)"
        case .internalReader:
            return "internal://local/reader-sidecar/\(token)"
        }
    }

    var endpointPathPrefix: String {
        switch self {
        case .ebook: "/processed-section-sidecar/"
        case .internalReader: "/reader-sidecar/"
        }
    }
}

func readerExternalSegmentSidecarResponse(
    for url: URL,
    scheme: ReaderExternalSegmentSidecarScheme,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> (response: HTTPURLResponse, data: Data)? {
    let prefix = scheme.endpointPathPrefix
    guard url.path.hasPrefix(prefix),
          let entry = store.entry(for: String(url.path.dropFirst(prefix.count))) else {
        return nil
    }
    let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: [
            "Content-Type": "application/json; charset=utf-8",
            "Content-Length": "\(entry.data.count)",
            "Cache-Control": "no-store",
            "X-Manabi-Sidecar-Signature": entry.signature,
        ]
    )!
    return (response, entry.data)
}

struct ReaderExternalizedSegmentSidecarHTML: Sendable {
    let documentHTML: Data
    let canonicalSidecarByteCount: Int
    let signature: String?
    let endpointURL: String?
}

struct ReaderPublishedSegmentSidecar: Sendable {
    let documentHTML: Data
    let headDescriptor: Data?
    let canonicalSidecarByteCount: Int
    let signature: String?
    let endpointURL: String?
}

// Version 5 stores processing authority explicitly and rejects older envelopes
// whose authority was reconstructed through a permissive initializer default.
private let readerProcessedSegmentSidecarEnvelopePrefix = Array("MNBPSC5".utf8)
private let readerProcessedSegmentSidecarEnvelopeLengthByteCount = MemoryLayout<UInt64>.size
private let readerProcessedSegmentSidecarEnvelopeAuthorityByteCount = 1

func splitCanonicalReaderSegmentSidecar(
    from htmlBytes: [UInt8]
) -> EbookProcessedSectionPayload? {
    guard let ranges = canonicalReaderSegmentSidecarRanges(in: htmlBytes) else { return nil }
    let canonicalData = Data(htmlBytes[ranges.content])
    guard !canonicalData.isEmpty else { return nil }
    var documentHTML = Data()
    documentHTML.reserveCapacity(htmlBytes.count - ranges.element.count)
    documentHTML.append(contentsOf: htmlBytes[..<ranges.element.lowerBound])
    documentHTML.append(contentsOf: htmlBytes[ranges.element.upperBound...])
    return EbookProcessedSectionPayload(
        documentHTML: documentHTML,
        segmentSidecar: canonicalData
    )
}

func splitCanonicalReaderSegmentSidecar(
    from htmlBytes: [UInt8],
    completionProof: EbookReaderProcessingCompletionProof
) -> EbookProcessedSectionPayload? {
    guard let split = splitCanonicalReaderSegmentSidecar(from: htmlBytes) else {
        return nil
    }
    return completionProof.complete(
        documentHTML: split.documentHTML,
        segmentSidecar: split.segmentSidecar
    )
}

public func encodedEbookProcessedSectionCacheValue(
    _ payload: EbookProcessedSectionPayload
) -> [UInt8] {
    var bytes = readerProcessedSegmentSidecarEnvelopePrefix
    bytes.reserveCapacity(
        readerProcessedSegmentSidecarEnvelopePrefix.count
            + (readerProcessedSegmentSidecarEnvelopeLengthByteCount * 2)
            + readerProcessedSegmentSidecarEnvelopeAuthorityByteCount
            + payload.combinedByteCount
    )
    appendLittleEndianUInt64(UInt64(payload.documentHTML.count), to: &bytes)
    appendLittleEndianUInt64(UInt64(payload.segmentSidecar.count), to: &bytes)
    bytes.append(payload.isAuthoritativelyProcessed ? 1 : 0)
    bytes.append(contentsOf: payload.documentHTML)
    bytes.append(contentsOf: payload.segmentSidecar)
    return bytes
}

public func decodedEbookProcessedSectionCacheValue(
    _ bytes: [UInt8]
) -> EbookProcessedSectionPayload? {
    let headerByteCount = readerProcessedSegmentSidecarEnvelopePrefix.count
        + (readerProcessedSegmentSidecarEnvelopeLengthByteCount * 2)
        + readerProcessedSegmentSidecarEnvelopeAuthorityByteCount
    guard bytes.count >= headerByteCount,
          bytes.starts(with: readerProcessedSegmentSidecarEnvelopePrefix) else {
        return nil
    }
    var cursor = readerProcessedSegmentSidecarEnvelopePrefix.count
    guard let documentLength = readLittleEndianUInt64(from: bytes, cursor: &cursor),
          let sidecarLength = readLittleEndianUInt64(from: bytes, cursor: &cursor),
          documentLength <= UInt64(Int.max),
          sidecarLength <= UInt64(Int.max) else {
        return nil
    }
    guard cursor < bytes.count else { return nil }
    let authorityByte = bytes[cursor]
    guard authorityByte == 0 || authorityByte == 1 else { return nil }
    cursor += readerProcessedSegmentSidecarEnvelopeAuthorityByteCount
    let documentByteCount = Int(documentLength)
    let sidecarByteCount = Int(sidecarLength)
    guard documentByteCount <= bytes.count - cursor,
          sidecarByteCount == bytes.count - cursor - documentByteCount else {
        return nil
    }
    let documentEnd = cursor + documentByteCount
    let documentHTML = Data(bytes[cursor..<documentEnd])
    let segmentSidecar = Data(bytes[documentEnd...])
    if authorityByte == 1 {
        return EbookProcessedSectionPayload.revalidatedCachedReaderProcessing(
            documentHTML: documentHTML,
            segmentSidecar: segmentSidecar
        )
    }
    return EbookProcessedSectionPayload(
        documentHTML: documentHTML,
        segmentSidecar: segmentSidecar
    )
}

func externalizingCanonicalReaderSegmentSidecar(
    in htmlBytes: [UInt8],
    scheme: ReaderExternalSegmentSidecarScheme,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> ReaderExternalizedSegmentSidecarHTML {
    guard let payload = splitCanonicalReaderSegmentSidecar(from: htmlBytes) else {
        return ReaderExternalizedSegmentSidecarHTML(
            documentHTML: Data(htmlBytes),
            canonicalSidecarByteCount: 0,
            signature: nil,
            endpointURL: nil
        )
    }
    let published = publishingCanonicalReaderSegmentSidecar(
        payload,
        scheme: scheme,
        store: store
    )
    guard let descriptor = published.headDescriptor else {
        return ReaderExternalizedSegmentSidecarHTML(
            documentHTML: published.documentHTML,
            canonicalSidecarByteCount: published.canonicalSidecarByteCount,
            signature: published.signature,
            endpointURL: published.endpointURL
        )
    }
    let closingHead = Data("</head>".utf8)
    let openingBody = Data("<body".utf8)
    let insertionIndex = published.documentHTML.range(of: closingHead)?.lowerBound
        ?? published.documentHTML.range(of: openingBody)?.lowerBound
        ?? published.documentHTML.startIndex
    var output = Data()
    output.reserveCapacity(published.documentHTML.count + descriptor.count)
    output.append(published.documentHTML[..<insertionIndex])
    output.append(descriptor)
    output.append(published.documentHTML[insertionIndex...])
    return ReaderExternalizedSegmentSidecarHTML(
        documentHTML: output,
        canonicalSidecarByteCount: published.canonicalSidecarByteCount,
        signature: published.signature,
        endpointURL: published.endpointURL
    )
}

func publishingCanonicalReaderSegmentSidecar(
    _ payload: EbookProcessedSectionPayload,
    scheme: ReaderExternalSegmentSidecarScheme,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> ReaderPublishedSegmentSidecar {
    guard !payload.segmentSidecar.isEmpty,
          ebookProcessedSectionPayloadHasDurableSegmentIdentities(payload) else {
        return ReaderPublishedSegmentSidecar(
            documentHTML: payload.documentHTML,
            headDescriptor: nil,
            canonicalSidecarByteCount: 0,
            signature: nil,
            endpointURL: nil
        )
    }
    guard let stored = store.insert(payload.segmentSidecar) else {
        return ReaderPublishedSegmentSidecar(
            documentHTML: payload.documentHTML,
            headDescriptor: nil,
            canonicalSidecarByteCount: 0,
            signature: nil,
            endpointURL: nil
        )
    }
    let endpointURL = scheme.endpointURL(token: stored.token)
    let descriptor = Data(
        "<meta name=\"mnb-segment-sidecar\" content=\"\(endpointURL)\" data-mnb-segment-sidecar-signature=\"\(stored.signature)\">".utf8
    )
    return ReaderPublishedSegmentSidecar(
        documentHTML: payload.documentHTML,
        headDescriptor: descriptor,
        canonicalSidecarByteCount: payload.segmentSidecar.count,
        signature: stored.signature,
        endpointURL: endpointURL
    )
}

private func canonicalReaderSegmentSidecarRanges(
    in htmlBytes: [UInt8]
) -> (element: Range<Int>, content: Range<Int>)? {
    let ranges = canonicalReaderSegmentSidecarRangeList(in: Data(htmlBytes))
    return ranges.count == 1 ? ranges[0] : nil
}

private func canonicalReaderSegmentSidecarRangeList(
    in htmlData: Data
) -> [(element: Range<Int>, content: Range<Int>)] {
    var ranges = [(element: Range<Int>, content: Range<Int>)]()
    var searchStart = htmlData.startIndex

    while searchStart < htmlData.endIndex,
          let tagStart = htmlData[searchStart...].firstIndex(of: ReaderHTMLASCII.lessThan) {
        if htmlASCIIMatches(
            ReaderHTMLASCII.commentOpening,
            in: htmlData,
            at: tagStart,
            caseInsensitive: false
        ) {
            guard let commentEnd = htmlASCIIRange(
                of: ReaderHTMLASCII.commentClosing,
                in: htmlData,
                startingAt: tagStart + ReaderHTMLASCII.commentOpening.count,
                caseInsensitive: false
            ) else {
                return []
            }
            searchStart = commentEnd.upperBound
            continue
        }
        guard htmlIsScriptTag(in: htmlData, at: tagStart, isClosing: false) else {
            if htmlMayStartTag(in: htmlData, at: tagStart),
               let tagEnd = htmlTagEnd(in: htmlData, startingAt: tagStart) {
                searchStart = tagEnd
            } else {
                searchStart = tagStart + 1
            }
            continue
        }
        guard let openingTagEnd = htmlTagEnd(in: htmlData, startingAt: tagStart),
              let closingTagStart = htmlClosingScriptTagStart(
                in: htmlData,
                startingAt: openingTagEnd
              ),
              let closingTagEnd = htmlTagEnd(in: htmlData, startingAt: closingTagStart) else {
            return []
        }
        let openingTagHTML = String(
            decoding: htmlData[tagStart..<openingTagEnd],
            as: UTF8.self
        )
        if let fragment = try? SwiftSoup.parseBodyFragment(openingTagHTML + "</script>"),
           let script = try? fragment.getElementsByTag("script").first(),
           script.id() == "mnb-segment-metadata" {
            ranges.append((
                tagStart..<closingTagEnd,
                openingTagEnd..<closingTagStart
            ))
        }
        searchStart = closingTagEnd
    }
    return ranges
}

private enum ReaderHTMLASCII {
    static let lessThan = UInt8(ascii: "<")
    static let greaterThan = UInt8(ascii: ">")
    static let forwardSlash = UInt8(ascii: "/")
    static let singleQuote = UInt8(ascii: "'")
    static let doubleQuote = UInt8(ascii: "\"")
    static let space = UInt8(ascii: " ")
    static let horizontalTab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let formFeed = UInt8(ascii: "\u{000C}")
    static let uppercaseLetters = UInt8(ascii: "A")...UInt8(ascii: "Z")
    static let lowercaseLetters = UInt8(ascii: "a")...UInt8(ascii: "z")
    static let lowercaseOffset = UInt8(ascii: "a") - UInt8(ascii: "A")
    static let exclamationMark = UInt8(ascii: "!")
    static let questionMark = UInt8(ascii: "?")
    static let scriptTagName = Array("script".utf8)
    static let commentOpening = Array("<!--".utf8)
    static let commentClosing = Array("-->".utf8)
}

private func htmlASCIILowercased(_ byte: UInt8) -> UInt8 {
    ReaderHTMLASCII.uppercaseLetters.contains(byte)
        ? byte + ReaderHTMLASCII.lowercaseOffset
        : byte
}

private func htmlASCIIMatches(
    _ pattern: [UInt8],
    in data: Data,
    at start: Int,
    caseInsensitive: Bool = true
) -> Bool {
    guard start >= data.startIndex,
          pattern.count <= data.endIndex - start else {
        return false
    }
    for offset in pattern.indices {
        let sourceByte = data[start + offset]
        let patternByte = pattern[offset]
        if caseInsensitive {
            guard htmlASCIILowercased(sourceByte) == htmlASCIILowercased(patternByte) else {
                return false
            }
        } else if sourceByte != patternByte {
            return false
        }
    }
    return true
}

private func htmlASCIIRange(
    of pattern: [UInt8],
    in data: Data,
    startingAt start: Int,
    caseInsensitive: Bool = true
) -> Range<Int>? {
    guard !pattern.isEmpty,
          start >= data.startIndex,
          pattern.count <= data.endIndex - start else {
        return nil
    }
    let finalStart = data.endIndex - pattern.count
    for candidateStart in start...finalStart where htmlASCIIMatches(
        pattern,
        in: data,
        at: candidateStart,
        caseInsensitive: caseInsensitive
    ) {
        return candidateStart..<(candidateStart + pattern.count)
    }
    return nil
}

private func htmlIsWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case ReaderHTMLASCII.space,
         ReaderHTMLASCII.horizontalTab,
         ReaderHTMLASCII.lineFeed,
         ReaderHTMLASCII.carriageReturn,
         ReaderHTMLASCII.formFeed:
        true
    default:
        false
    }
}

private func htmlIsTagNameBoundary(_ byte: UInt8) -> Bool {
    htmlIsWhitespace(byte)
        || byte == ReaderHTMLASCII.greaterThan
        || byte == ReaderHTMLASCII.forwardSlash
}

private func htmlMayStartTag(in data: Data, at tagStart: Int) -> Bool {
    let markerIndex = tagStart + 1
    guard data.indices.contains(markerIndex) else { return false }
    let marker = data[markerIndex]
    return ReaderHTMLASCII.uppercaseLetters.contains(marker)
        || ReaderHTMLASCII.lowercaseLetters.contains(marker)
        || marker == ReaderHTMLASCII.forwardSlash
        || marker == ReaderHTMLASCII.exclamationMark
        || marker == ReaderHTMLASCII.questionMark
}

private func htmlIsScriptTag(
    in data: Data,
    at tagStart: Int,
    isClosing: Bool
) -> Bool {
    guard data.indices.contains(tagStart), data[tagStart] == ReaderHTMLASCII.lessThan else {
        return false
    }
    let slashByteCount = isClosing ? 1 : 0
    let nameStart = tagStart + 1 + slashByteCount
    if isClosing {
        guard data.indices.contains(tagStart + 1),
              data[tagStart + 1] == ReaderHTMLASCII.forwardSlash else {
            return false
        }
    }
    guard htmlASCIIMatches(ReaderHTMLASCII.scriptTagName, in: data, at: nameStart) else {
        return false
    }
    let boundaryIndex = nameStart + ReaderHTMLASCII.scriptTagName.count
    return data.indices.contains(boundaryIndex) && htmlIsTagNameBoundary(data[boundaryIndex])
}

private func htmlTagEnd(in data: Data, startingAt tagStart: Int) -> Int? {
    var quote: UInt8?
    var index = tagStart + 1
    while index < data.endIndex {
        let byte = data[index]
        if let activeQuote = quote {
            if byte == activeQuote { quote = nil }
        } else if byte == ReaderHTMLASCII.singleQuote || byte == ReaderHTMLASCII.doubleQuote {
            quote = byte
        } else if byte == ReaderHTMLASCII.greaterThan {
            return index + 1
        }
        index += 1
    }
    return nil
}

private func htmlClosingScriptTagStart(in data: Data, startingAt start: Int) -> Int? {
    var searchStart = start
    while searchStart < data.endIndex,
          let candidate = data[searchStart...].firstIndex(of: ReaderHTMLASCII.lessThan) {
        if htmlIsScriptTag(in: data, at: candidate, isClosing: true) {
            return candidate
        }
        searchStart = candidate + 1
    }
    return nil
}

@inline(__always)
private func appendLittleEndianUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
    for shift in stride(from: 0, to: UInt64.bitWidth, by: UInt8.bitWidth) {
        bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
}

@inline(__always)
private func readLittleEndianUInt64(from bytes: [UInt8], cursor: inout Int) -> UInt64? {
    guard cursor <= bytes.count - readerProcessedSegmentSidecarEnvelopeLengthByteCount else {
        return nil
    }
    var value: UInt64 = 0
    for offset in 0..<readerProcessedSegmentSidecarEnvelopeLengthByteCount {
        value |= UInt64(bytes[cursor + offset]) << UInt64(offset * UInt8.bitWidth)
    }
    cursor += readerProcessedSegmentSidecarEnvelopeLengthByteCount
    return value
}
