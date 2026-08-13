import CryptoKit
import CoreFoundation
import Foundation
import SwiftSoup
import SwiftUtilities

public enum ReaderCompactSegmentSidecarSchema {
    public static let currentVersion = 9
}

public struct EbookProcessedSectionPayload: Sendable {
    public let documentHTML: Data
    public let segmentSidecar: Data
    public let isAuthoritativelyProcessed: Bool

    public init(
        documentHTML: Data,
        segmentSidecar: Data,
        isAuthoritativelyProcessed: Bool = true
    ) {
        self.documentHTML = documentHTML
        self.segmentSidecar = segmentSidecar
        self.isAuthoritativelyProcessed = isAuthoritativelyProcessed
    }

    public var combinedByteCount: Int {
        documentHTML.count + segmentSidecar.count
    }
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

    let canonicalSidecars = (try? document.select("script#mnb-segment-metadata").array()) ?? []
    let transportMarkers = (try? document.getElementsByTag("meta").array().filter {
        try $0.attr("name") == ReaderPretransformedEbookSidecarContract.transportMarkerName
    }) ?? []
    guard canonicalSidecars.isEmpty else { return false }
    guard !payload.segmentSidecar.isEmpty else {
        return documentSegmentIdentifiers.isEmpty && transportMarkers.isEmpty
    }
    guard documentSegmentIdentifiers.count > 0,
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

private enum ReaderPretransformedEbookSidecarContract {
    static let transportMarkerName = "mnb-pretransformed-ebook-sidecar"
    static let contractVersion = 1
}

private struct ReaderSegmentSidecarIdentityProjection {
    let runtimeIdentifier: String
    let segmentHash: String
    let surfaceText: String?
    let sentenceIdentifier: String
    let paragraphIdentifier: String
}

private func readerPretransformedEbookTransportMarkerIsValid(
    _ marker: Element,
    segmentSidecar: Data,
    document: SwiftSoup.Document,
    documentSegmentIdentifiers: [String]
) -> Bool {
    guard let markerIsPretransformed = try? marker.attr("data-mnb-pretransformed-ebook"),
          markerIsPretransformed == "true",
          let schemaVersion = try? marker.attr("data-mnb-sidecar-schema-version"),
          schemaVersion == String(ReaderCompactSegmentSidecarSchema.currentVersion),
          let contractVersion = try? marker.attr("data-mnb-sidecar-contract-version"),
          contractVersion == String(ReaderPretransformedEbookSidecarContract.contractVersion),
          let revision = try? marker.attr("data-mnb-sidecar-revision"),
          revision == String(stableHash(data: segmentSidecar), radix: 16, uppercase: true),
          let segmentCountValue = try? marker.attr("data-mnb-sidecar-segment-count"),
          let segmentCount = exactPositiveDecimalInteger(segmentCountValue),
          segmentCount == documentSegmentIdentifiers.count,
          let sentenceCountValue = try? marker.attr("data-mnb-sidecar-sentence-count"),
          let sentenceCount = exactPositiveDecimalInteger(sentenceCountValue),
          let projections = validatedReaderSegmentSidecarIdentityProjections(
              segmentSidecar,
              generatedSegmentIdentifiers: documentSegmentIdentifiers
          ),
          projections.count == segmentCount else {
        return false
    }

    let sentenceElements = Array(document.getElementsByTag("m-s"))
    guard sentenceElements.count == sentenceCount else { return false }
    var sentenceIdentifiers = Set<String>()
    for sentence in sentenceElements {
        guard let sentenceIdentifier = try? sentence.attr("sid"),
              !sentenceIdentifier.isEmpty,
              sentenceIdentifiers.insert(sentenceIdentifier).inserted,
              (try? sentence.attr("o")) == "true" else {
            return false
        }
    }

    var segmentElementsByIdentifier = [String: Element]()
    for segment in document.getElementsByTag("m-m") {
        guard let identifier = try? segment.attr("id"),
              !identifier.isEmpty,
              segmentElementsByIdentifier.updateValue(segment, forKey: identifier) == nil else {
            return false
        }
    }
    for projection in projections {
        guard !projection.segmentHash.isEmpty,
              let surfaceText = projection.surfaceText,
              !surfaceText.isEmpty,
              let segment = segmentElementsByIdentifier[projection.runtimeIdentifier],
              let sentence = nearestReaderAncestor(named: "m-s", from: segment),
              let paragraph = nearestReaderAncestor(named: "m-c", from: segment),
              (try? sentence.attr("sid")) == projection.sentenceIdentifier,
              (try? sentence.attr("o")) == "true",
              (try? paragraph.attr("pid")) == projection.paragraphIdentifier else {
            return false
        }
    }
    return true
}

private func nearestReaderAncestor(named tagName: String, from element: Element) -> Element? {
    var candidate = element.parent() as? Element
    while let current = candidate {
        if current.tagName() == tagName { return current }
        candidate = current.parent() as? Element
    }
    return nil
}

private func exactPositiveDecimalInteger(_ value: String) -> Int? {
    guard !value.isEmpty,
          value.unicodeScalars.allSatisfy({
              $0.isASCII && CharacterSet.decimalDigits.contains($0)
          }),
          let integer = Int(value),
          integer > 0,
          String(integer) == value else {
        return nil
    }
    return integer
}

private func readerSegmentSidecarHasDurableSegmentIdentities(
    _ sidecar: Data,
    generatedSegmentIdentifiers: [String]
) -> Bool {
    validatedReaderSegmentSidecarIdentityProjections(
        sidecar,
        generatedSegmentIdentifiers: generatedSegmentIdentifiers
    ) != nil
}

private func validatedReaderSegmentSidecarIdentityProjections(
    _ sidecar: Data,
    generatedSegmentIdentifiers: [String]
) -> [ReaderSegmentSidecarIdentityProjection]? {
    guard let object = try? JSONSerialization.jsonObject(with: sidecar),
          let root = object as? [String: Any],
          exactNonnegativeInteger(root["v"]) == ReaderCompactSegmentSidecarSchema.currentVersion,
          let tables = root["t"] as? [String: Any],
          compactSidecarTablesAreValid(tables),
          let segments = root["s"] as? [[Any]],
          segments.count == generatedSegmentIdentifiers.count else {
        return nil
    }

    func tableValue(_ tableKey: String, tuple: [Any], index: Int) -> Any? {
        guard tuple.indices.contains(index),
              let tableIndex = exactNonnegativeInteger(tuple[index]),
              let table = tables[tableKey] as? [Any],
              table.indices.contains(tableIndex) else {
            return nil
        }
        return table[tableIndex]
    }

    func hasNonEmptyString(_ tableKey: String, tuple: [Any], index: Int) -> Bool {
        guard let value = tableValue(tableKey, tuple: tuple, index: index) as? String else {
            return false
        }
        return !value.isEmpty
    }

    func optionalStringReferenceIsValid(_ tableKey: String, tuple: [Any], index: Int) -> Bool {
        guard tuple.indices.contains(index) else { return false }
        if tuple[index] is NSNull { return true }
        return hasNonEmptyString(tableKey, tuple: tuple, index: index)
    }

    func optionalEntryIDReferenceIsValid(_ tableKey: String, tuple: [Any], index: Int) -> Bool {
        guard tuple.indices.contains(index) else { return false }
        if tuple[index] is NSNull { return true }
        guard let entryIDs = tableValue(tableKey, tuple: tuple, index: index) as? [Any] else {
            return false
        }
        return entryIDs.allSatisfy { exactPositiveInteger($0) != nil }
    }

    func optionalJLPTLevelIsValid(_ value: Any) -> Bool {
        guard !(value is NSNull) else { return true }
        guard let level = exactNonnegativeInteger(value) else { return false }
        return ReaderJLPTLevelRange.validLevels.contains(level)
    }

    func expandedRuntimeIdentifier(from token: String) -> String? {
        guard let first = token.first else { return nil }
        if first == "!" {
            let identifier = String(token.dropFirst())
            return identifier.isEmpty ? nil : identifier
        }
        if first == "~" {
            let suffix = String(token.dropFirst())
            return suffix.isEmpty ? nil : "_m" + suffix
        }
        let isCompactMnbSegmentToken = token.unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        }
        return isCompactMnbSegmentToken ? "mnb-s" + token : nil
    }

    var runtimeIdentifiers = Set<String>()
    var projections = [ReaderSegmentSidecarIdentityProjection]()
    projections.reserveCapacity(segments.count)
    for tuple in segments {
        guard tuple.count == CompactSegmentTupleField.count,
              let runtimeIdentifierToken = tuple[CompactSegmentTupleField.runtimeIdentifier] as? String,
              let runtimeIdentifier = expandedRuntimeIdentifier(from: runtimeIdentifierToken),
              runtimeIdentifiers.insert(runtimeIdentifier).inserted,
              let segmentHash = tableValue(
                  "h",
                  tuple: tuple,
                  index: CompactSegmentTupleField.segmentHash
              ) as? String,
              !segmentHash.isEmpty,
              optionalEntryIDReferenceIsValid(
                  "j",
                  tuple: tuple,
                  index: CompactSegmentTupleField.jmdictEntryIDs
              ),
              optionalEntryIDReferenceIsValid(
                  "n",
                  tuple: tuple,
                  index: CompactSegmentTupleField.jmnedictEntryIDs
              ),
              optionalStringReferenceIsValid(
                  "s",
                  tuple: tuple,
                  index: CompactSegmentTupleField.jmdictSearchString
              ),
              optionalStringReferenceIsValid(
                  "ns",
                  tuple: tuple,
                  index: CompactSegmentTupleField.jmnedictSearchString
              ),
              optionalStringReferenceIsValid(
                  "p",
                  tuple: tuple,
                  index: CompactSegmentTupleField.partOfSpeech
              ),
              optionalJLPTLevelIsValid(tuple[CompactSegmentTupleField.jlptLevel]),
              optionalStringReferenceIsValid(
                  "x",
                  tuple: tuple,
                  index: CompactSegmentTupleField.surfaceText
              ),
              let sentenceIdentifier = tableValue(
                  "sid",
                  tuple: tuple,
                  index: CompactSegmentTupleField.sentenceIdentifier
              ) as? String,
              !sentenceIdentifier.isEmpty,
              let paragraphIdentifier = tableValue(
                  "pid",
                  tuple: tuple,
                  index: CompactSegmentTupleField.paragraphIdentifier
              ) as? String,
              !paragraphIdentifier.isEmpty else {
            return nil
        }
        projections.append(
            ReaderSegmentSidecarIdentityProjection(
                runtimeIdentifier: runtimeIdentifier,
                segmentHash: segmentHash,
                surfaceText: tableValue(
                    "x",
                    tuple: tuple,
                    index: CompactSegmentTupleField.surfaceText
                ) as? String,
                sentenceIdentifier: sentenceIdentifier,
                paragraphIdentifier: paragraphIdentifier
            )
        )
    }

    let documentIdentifierSet = Set(generatedSegmentIdentifiers)
    guard documentIdentifierSet.count == generatedSegmentIdentifiers.count,
          runtimeIdentifiers == documentIdentifierSet else {
        return nil
    }
    return projections
}

private enum CompactSegmentTupleField {
    static let runtimeIdentifier = 0
    static let segmentHash = 1
    static let jmdictEntryIDs = 2
    static let jmnedictEntryIDs = 3
    static let jmdictSearchString = 4
    static let jmnedictSearchString = 5
    static let partOfSpeech = 6
    static let jlptLevel = 7
    static let surfaceText = 8
    static let sentenceIdentifier = 9
    static let paragraphIdentifier = 10
    static let count = 11
}

private let maximumExactJSONInteger = 9_007_199_254_740_991

private enum ReaderJLPTLevelRange {
    static let validLevels = 1...5
}

private func exactNonnegativeInteger(_ value: Any?) -> Int? {
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

private func exactPositiveInteger(_ value: Any?) -> Int? {
    guard let integer = exactNonnegativeInteger(value), integer > 0 else { return nil }
    return integer
}

private func compactSidecarTablesAreValid(_ tables: [String: Any]) -> Bool {
    func entryIDTableIsValid(_ key: String) -> Bool {
        guard let rows = tables[key] as? [Any] else { return false }
        return rows.allSatisfy { row in
            guard let entryIDs = row as? [Any] else { return false }
            return entryIDs.allSatisfy { exactPositiveInteger($0) != nil }
        }
    }

    func stringTableIsValid(_ key: String) -> Bool {
        guard let values = tables[key] as? [Any] else { return false }
        return values.allSatisfy { value in
            guard let string = value as? String else { return false }
            return !string.isEmpty
        }
    }

    guard entryIDTableIsValid("j"),
          entryIDTableIsValid("n"),
          stringTableIsValid("s"),
          stringTableIsValid("ns"),
          stringTableIsValid("p"),
          stringTableIsValid("h"),
          stringTableIsValid("sid"),
          stringTableIsValid("pid") else {
        return false
    }
    guard let surfaceTexts = tables["x"] else { return true }
    if surfaceTexts is NSNull { return true }
    return stringTableIsValid("x")
}

private func generatedReaderSegmentIdentifiers(in documentHTML: Data) -> [String]? {
    guard let html = String(data: documentHTML, encoding: .utf8) else { return nil }
    do {
        let document = try SwiftSoup.parse(html)
        return generatedReaderSegmentIdentifiers(in: document)
    } catch {
        return nil
    }
}

private func generatedReaderSegmentIdentifiers(in document: SwiftSoup.Document) -> [String]? {
    let segmentElements = document.getElementsByTag("m-m")
    var identifiers = [String]()
    identifiers.reserveCapacity(segmentElements.size())
    for segmentElement in segmentElements {
        let identifier = segmentElement.id()
        guard !identifier.isEmpty else { return nil }
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
    private static let decimalDigitBytes = UInt8(ascii: "0")...UInt8(ascii: "9")
    private static let lowercaseHexLetterBytes = UInt8(ascii: "a")...UInt8(ascii: "f")

    private let lock = NSLock()
    private let totalByteLimit: Int
    private let countLimit: Int
    private let directoryURL: URL
    private var entries = [String: ReaderExternalSegmentSidecarEntry]()
    private var tokensInAccessOrder = [String]()
    private var totalBytes = 0

    init(
        directoryURL: URL = ReaderExternalSegmentSidecarStore.defaultDirectoryURL,
        totalByteLimit: Int = 24 * 1024 * 1024,
        countLimit: Int = 32
    ) {
        self.directoryURL = directoryURL
        self.totalByteLimit = max(totalByteLimit, 1)
        self.countLimit = max(countLimit, 1)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var resourceURL = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(resourceValues)
    }

    func insert(_ data: Data) -> (token: String, signature: String)? {
        let token = Self.contentToken(for: data)
        let signature = "sha256:\(data.count):\(token)"
        let entry = ReaderExternalSegmentSidecarEntry(data: data, signature: signature)
        guard persistIfNeeded(data, token: token) else { return nil }

        lock.lock()
        insertIntoMemory(entry, token: token)
        lock.unlock()
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
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              Self.contentToken(for: data) == token else {
            return nil
        }
        let entry = ReaderExternalSegmentSidecarEntry(
            data: data,
            signature: "sha256:\(data.count):\(token)"
        )
        lock.lock()
        insertIntoMemory(entry, token: token)
        lock.unlock()
        return entry
    }

    private func persistIfNeeded(_ data: Data, token: String) -> Bool {
        let fileURL = directoryURL.appendingPathComponent(token, isDirectory: false)
        if let storedData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
           Self.contentToken(for: storedData) == token {
            return true
        }
        do {
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private func insertIntoMemory(
        _ entry: ReaderExternalSegmentSidecarEntry,
        token: String
    ) {
        guard entry.data.count <= totalByteLimit else {
            if let previous = entries.removeValue(forKey: token) {
                totalBytes -= previous.data.count
            }
            tokensInAccessOrder.removeAll { $0 == token }
            return
        }
        if let previous = entries.updateValue(entry, forKey: token) {
            totalBytes -= previous.data.count
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
            guard !tokensInAccessOrder.isEmpty else { break }
            let token = tokensInAccessOrder.removeFirst()
            if let removed = entries.removeValue(forKey: token) {
                totalBytes -= removed.data.count
            }
        }
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

    fileprivate static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == SHA256.Digest.byteCount * 2
            && token.utf8.allSatisfy {
                decimalDigitBytes.contains($0) || lowercaseHexLetterBytes.contains($0)
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

    func endpointURL(token: String) -> String {
        switch self {
        case .ebook:
            "ebook://ebook/processed-section-sidecar/\(token)"
        case .internalReader:
            "internal://local/reader-sidecar/\(token)"
        }
    }

    var endpointPathPrefix: String {
        switch self {
        case .ebook: "/processed-section-sidecar/"
        case .internalReader: "/reader-sidecar/"
        }
    }

    private var endpointHost: String {
        switch self {
        case .ebook: "ebook"
        case .internalReader: "local"
        }
    }

    func token(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == rawValue,
              components.host == endpointHost,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil,
              components.percentEncodedPath.hasPrefix(endpointPathPrefix) else {
            return nil
        }
        let token = String(components.percentEncodedPath.dropFirst(endpointPathPrefix.count))
        return ReaderExternalSegmentSidecarStore.isValidToken(token) ? token : nil
    }
}

func readerExternalSegmentSidecarResponse(
    for url: URL,
    scheme: ReaderExternalSegmentSidecarScheme,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> (response: HTTPURLResponse, data: Data)? {
    guard let token = scheme.token(from: url),
          let entry = store.entry(for: token) else {
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

// Version 5 invalidates detached payloads that predate exact producer-contract
// validation across the sidecar, transport marker, and generated DOM hierarchy.
private let readerProcessedSegmentSidecarEnvelopePrefix = Array("MNBPSC5".utf8)
private let readerProcessedSegmentSidecarEnvelopeLengthByteCount = MemoryLayout<UInt64>.size

func splitCanonicalReaderSegmentSidecar(
    from htmlBytes: [UInt8]
) -> EbookProcessedSectionPayload? {
    splitCanonicalReaderSegmentSidecar(from: Data(htmlBytes))
}

func splitCanonicalReaderSegmentSidecar(
    from htmlData: Data
) -> EbookProcessedSectionPayload? {
    guard let ranges = canonicalReaderSegmentSidecarRanges(in: htmlData) else { return nil }
    let sidecar = Data(htmlData[ranges.content])
    guard !sidecar.isEmpty else { return nil }

    var documentHTML = Data()
    documentHTML.reserveCapacity(htmlData.count - ranges.element.count)
    documentHTML.append(htmlData[..<ranges.element.lowerBound])
    documentHTML.append(htmlData[ranges.element.upperBound...])
    return EbookProcessedSectionPayload(documentHTML: documentHTML, segmentSidecar: sidecar)
}

public func encodedEbookProcessedSectionCacheValue(
    _ payload: EbookProcessedSectionPayload
) -> [UInt8] {
    var bytes = readerProcessedSegmentSidecarEnvelopePrefix
    bytes.reserveCapacity(
        bytes.count
            + (readerProcessedSegmentSidecarEnvelopeLengthByteCount * 2)
            + payload.combinedByteCount
    )
    appendLittleEndianUInt64(UInt64(payload.documentHTML.count), to: &bytes)
    appendLittleEndianUInt64(UInt64(payload.segmentSidecar.count), to: &bytes)
    bytes.append(contentsOf: payload.documentHTML)
    bytes.append(contentsOf: payload.segmentSidecar)
    return bytes
}

public func decodedEbookProcessedSectionCacheValue(
    _ bytes: [UInt8]
) -> EbookProcessedSectionPayload? {
    let headerByteCount = readerProcessedSegmentSidecarEnvelopePrefix.count
        + (readerProcessedSegmentSidecarEnvelopeLengthByteCount * 2)
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
    let documentByteCount = Int(documentLength)
    let sidecarByteCount = Int(sidecarLength)
    guard documentByteCount <= bytes.count - cursor,
          sidecarByteCount == bytes.count - cursor - documentByteCount else {
        return nil
    }
    let documentEnd = cursor + documentByteCount
    return EbookProcessedSectionPayload(
        documentHTML: Data(bytes[cursor..<documentEnd]),
        segmentSidecar: Data(bytes[documentEnd...])
    )
}

func publishingCanonicalReaderSegmentSidecar(
    _ payload: EbookProcessedSectionPayload,
    scheme: ReaderExternalSegmentSidecarScheme,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> ReaderPublishedSegmentSidecar {
    guard !payload.segmentSidecar.isEmpty else {
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
            headDescriptor: inlineCanonicalReaderSegmentSidecar(payload.segmentSidecar),
            canonicalSidecarByteCount: payload.segmentSidecar.count,
            signature: nil,
            endpointURL: nil
        )
    }
    let endpointURL = scheme.endpointURL(token: stored.token)
    let descriptor = Data(
        "<meta name=\"mnb-segment-sidecar\" content=\"\(endpointURL)\" "
            .appending("data-mnb-segment-sidecar-signature=\"\(stored.signature)\">")
            .utf8
    )
    return ReaderPublishedSegmentSidecar(
        documentHTML: payload.documentHTML,
        headDescriptor: descriptor,
        canonicalSidecarByteCount: payload.segmentSidecar.count,
        signature: stored.signature,
        endpointURL: endpointURL
    )
}

func ebookProcessedHTMLHasDurableSegmentIdentities(
    _ processedHTML: String,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> Bool {
    let htmlData = Data(processedHTML.utf8)
    guard let generatedSegmentIdentifiers = generatedReaderSegmentIdentifiers(
        in: htmlData
    ) else {
        return false
    }
    let sidecarData: Data?
    let canonicalRanges = canonicalReaderSegmentSidecarRangeList(in: htmlData)
    if canonicalRanges.count == 1, let ranges = canonicalRanges.first {
        sidecarData = Data(htmlData[ranges.content])
    } else if !canonicalRanges.isEmpty {
        return false
    } else {
        guard let descriptor = externalReaderSegmentSidecarDescriptor(in: htmlData),
              let endpointURL = URL(string: descriptor.endpointURL),
              let token = ReaderExternalSegmentSidecarScheme.ebook.token(from: endpointURL),
              let entry = store.entry(for: token),
              entry.signature == descriptor.signature else {
            return generatedSegmentIdentifiers.isEmpty
                && !htmlDataContainsExternalReaderSegmentSidecarDescriptor(htmlData)
        }
        sidecarData = entry.data
    }
    guard let sidecarData else {
        return generatedSegmentIdentifiers.isEmpty
    }
    return readerSegmentSidecarHasDurableSegmentIdentities(
        sidecarData,
        generatedSegmentIdentifiers: generatedSegmentIdentifiers
    )
}

func externalizingCanonicalReaderSegmentSidecar(
    in htmlBytes: [UInt8],
    scheme: ReaderExternalSegmentSidecarScheme,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> ReaderExternalizedSegmentSidecarHTML {
    externalizingCanonicalReaderSegmentSidecar(
        in: Data(htmlBytes),
        scheme: scheme,
        store: store
    )
}

func externalizingCanonicalReaderSegmentSidecar(
    in htmlData: Data,
    scheme: ReaderExternalSegmentSidecarScheme,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> ReaderExternalizedSegmentSidecarHTML {
    guard let ranges = canonicalReaderSegmentSidecarRanges(in: htmlData) else {
        return ReaderExternalizedSegmentSidecarHTML(
            documentHTML: htmlData,
            canonicalSidecarByteCount: 0,
            signature: nil,
            endpointURL: nil
        )
    }
    let sidecar = Data(htmlData[ranges.content])
    guard !sidecar.isEmpty else {
        return ReaderExternalizedSegmentSidecarHTML(
            documentHTML: htmlData,
            canonicalSidecarByteCount: 0,
            signature: nil,
            endpointURL: nil
        )
    }
    var documentWithoutSidecar = Data()
    documentWithoutSidecar.reserveCapacity(htmlData.count - ranges.element.count)
    documentWithoutSidecar.append(htmlData[..<ranges.element.lowerBound])
    documentWithoutSidecar.append(htmlData[ranges.element.upperBound...])
    return externalizingReaderSegmentSidecar(
        documentHTML: documentWithoutSidecar,
        canonicalSidecar: sidecar,
        scheme: scheme,
        store: store
    )
}

func externalizingReaderSegmentSidecar(
    documentHTML: [UInt8],
    canonicalSidecar: Data,
    scheme: ReaderExternalSegmentSidecarScheme,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> ReaderExternalizedSegmentSidecarHTML {
    externalizingReaderSegmentSidecar(
        documentHTML: Data(documentHTML),
        canonicalSidecar: canonicalSidecar,
        scheme: scheme,
        store: store
    )
}

func externalizingReaderSegmentSidecar(
    documentHTML: Data,
    canonicalSidecar: Data,
    scheme: ReaderExternalSegmentSidecarScheme,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> ReaderExternalizedSegmentSidecarHTML {
    let cleanDocumentHTML = removingCanonicalReaderSegmentSidecars(from: documentHTML)
    guard !canonicalSidecar.isEmpty else {
        return ReaderExternalizedSegmentSidecarHTML(
            documentHTML: ebookHTMLDataReplacingHeadMetaElement(
                named: "mnb-segment-sidecar",
                with: Data(),
                in: cleanDocumentHTML
            ),
            canonicalSidecarByteCount: 0,
            signature: nil,
            endpointURL: nil
        )
    }
    guard let stored = store.insert(canonicalSidecar) else {
        return ReaderExternalizedSegmentSidecarHTML(
            documentHTML: ebookHTMLDataReplacingHeadMetaElement(
                named: "mnb-segment-sidecar",
                with: inlineCanonicalReaderSegmentSidecar(canonicalSidecar),
                in: cleanDocumentHTML
            ),
            canonicalSidecarByteCount: canonicalSidecar.count,
            signature: nil,
            endpointURL: nil
        )
    }
    let endpointURL = scheme.endpointURL(token: stored.token)
    let descriptorHTML = "<meta name=\"mnb-segment-sidecar\" content=\"\(endpointURL)\" "
        + "data-mnb-segment-sidecar-signature=\"\(stored.signature)\">"
    let descriptor = Data(descriptorHTML.utf8)
    return ReaderExternalizedSegmentSidecarHTML(
        documentHTML: ebookHTMLDataReplacingHeadMetaElement(
            named: "mnb-segment-sidecar",
            with: descriptor,
            in: cleanDocumentHTML
        ),
        canonicalSidecarByteCount: canonicalSidecar.count,
        signature: stored.signature,
        endpointURL: endpointURL
    )
}

func inliningReaderSegmentSidecar(
    documentHTML: Data,
    canonicalSidecar: Data
) -> Data {
    let documentWithoutCanonicalSidecars = removingCanonicalReaderSegmentSidecars(
        from: documentHTML
    )
    return ebookHTMLDataReplacingHeadMetaElement(
        named: "mnb-segment-sidecar",
        with: canonicalSidecar.isEmpty
            ? Data()
            : inlineCanonicalReaderSegmentSidecar(canonicalSidecar),
        in: documentWithoutCanonicalSidecars
    )
}

private func inlineCanonicalReaderSegmentSidecar(_ sidecar: Data) -> Data {
    let escapedSidecar = scriptSafeJSON(sidecar)
    var element = Data(
        "<script id=\"mnb-segment-metadata\" type=\"application/json\" data-mnb-seg-meta=\"true\">".utf8
    )
    element.reserveCapacity(element.count + escapedSidecar.count + "</script>".utf8.count)
    element.append(escapedSidecar)
    element.append(contentsOf: "</script>".utf8)
    return element
}

private func scriptSafeJSON(_ data: Data) -> Data {
    var escaped = Data()
    escaped.reserveCapacity(data.count)
    for byte in data {
        switch byte {
        case UInt8(ascii: "<"):
            escaped.append(contentsOf: "\\u003C".utf8)
        case UInt8(ascii: "&"):
            escaped.append(contentsOf: "\\u0026".utf8)
        default:
            escaped.append(byte)
        }
    }
    return escaped
}

private struct ReaderExternalSegmentSidecarDescriptor {
    let endpointURL: String
    let signature: String
}

private func externalReaderSegmentSidecarDescriptor(
    in htmlData: Data
) -> ReaderExternalSegmentSidecarDescriptor? {
    guard let html = String(data: htmlData, encoding: .utf8),
          let document = try? SwiftSoup.parse(html) else {
        return nil
    }
    let descriptors = document.getElementsByTag("meta").array().filter { element in
        (try? element.attr("name").lowercased()) == "mnb-segment-sidecar"
    }
    guard descriptors.count == 1,
          let descriptor = descriptors.first,
          let endpointURL = try? descriptor.attr("content"),
          !endpointURL.isEmpty,
          let signature = try? descriptor.attr("data-mnb-segment-sidecar-signature"),
          !signature.isEmpty else {
        return nil
    }
    return ReaderExternalSegmentSidecarDescriptor(
        endpointURL: endpointURL,
        signature: signature
    )
}

private func htmlDataContainsExternalReaderSegmentSidecarDescriptor(_ htmlData: Data) -> Bool {
    guard let html = String(data: htmlData, encoding: .utf8),
          let document = try? SwiftSoup.parse(html) else {
        return false
    }
    return document.getElementsByTag("meta").array().contains { element in
        (try? element.attr("name").lowercased()) == "mnb-segment-sidecar"
    }
}

private func canonicalReaderSegmentSidecarRanges(
    in htmlData: Data
) -> (element: Range<Int>, content: Range<Int>)? {
    let ranges = canonicalReaderSegmentSidecarRangeList(in: htmlData)
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
           script?.id() == "mnb-segment-metadata" {
            ranges.append((
                tagStart..<closingTagEnd,
                openingTagEnd..<closingTagStart
            ))
        }
        searchStart = closingTagEnd
    }
    return ranges
}

private func removingCanonicalReaderSegmentSidecars(from htmlData: Data) -> Data {
    let ranges = canonicalReaderSegmentSidecarRangeList(in: htmlData).map(\.element)
    guard !ranges.isEmpty else { return htmlData }
    var result = Data()
    result.reserveCapacity(htmlData.count - ranges.reduce(0) { $0 + $1.count })
    var sourceIndex = htmlData.startIndex
    for range in ranges {
        result.append(htmlData[sourceIndex..<range.lowerBound])
        sourceIndex = range.upperBound
    }
    result.append(htmlData[sourceIndex...])
    return result
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
            if byte == activeQuote {
                quote = nil
            }
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
