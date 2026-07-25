import CryptoKit
import Foundation

public struct EbookProcessedSectionPayload: Sendable {
    public let documentHTML: Data
    public let segmentSidecar: Data

    public init(documentHTML: Data, segmentSidecar: Data) {
        self.documentHTML = documentHTML
        self.segmentSidecar = segmentSidecar
    }

    public var combinedByteCount: Int {
        documentHTML.count + segmentSidecar.count
    }
}

public func ebookProcessedSectionPayloadHasDurableSegmentIdentities(
    _ payload: EbookProcessedSectionPayload
) -> Bool {
    let documentSegmentCount = generatedReaderSegmentCount(in: payload.documentHTML)
    guard !payload.segmentSidecar.isEmpty else { return documentSegmentCount == 0 }
    return readerSegmentSidecarHasDurableSegmentIdentities(
        payload.segmentSidecar,
        generatedSegmentCount: documentSegmentCount
    )
}

private func readerSegmentSidecarHasDurableSegmentIdentities(
    _ sidecar: Data,
    generatedSegmentCount: Int
) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: sidecar),
          let root = object as? [String: Any],
          (root["v"] as? NSNumber)?.intValue == 9,
          let tables = root["t"] as? [String: Any],
          let hashes = tables["h"] as? [String],
          let sentenceIdentifiers = tables["sid"] as? [String],
          let paragraphIdentifiers = tables["pid"] as? [String],
          let segments = root["s"] as? [[Any]],
          segments.count == generatedSegmentCount else {
        return false
    }

    func hasNonEmptyValue(_ table: [String], tuple: [Any], index: Int) -> Bool {
        guard tuple.indices.contains(index),
              let tableIndex = tuple[index] as? NSNumber,
              table.indices.contains(tableIndex.intValue) else {
            return false
        }
        return !table[tableIndex.intValue].isEmpty
    }

    var runtimeIdentifierTokens = Set<String>()
    return segments.allSatisfy { tuple in
        guard tuple.count == 11,
              let runtimeIdentifierToken = tuple.first as? String,
              runtimeIdentifierToken.count > 1,
              (runtimeIdentifierToken.first == "!" || runtimeIdentifierToken.first == "~"),
              runtimeIdentifierTokens.insert(runtimeIdentifierToken).inserted else {
            return false
        }
        return hasNonEmptyValue(hashes, tuple: tuple, index: 1)
            && hasNonEmptyValue(sentenceIdentifiers, tuple: tuple, index: 9)
            && hasNonEmptyValue(paragraphIdentifiers, tuple: tuple, index: 10)
    }
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
    private let totalByteLimit: Int
    private let countLimit: Int
    private let directoryURL: URL
    private var entries = [String: ReaderExternalSegmentSidecarEntry]()
    private var durableTokens = Set<String>()
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

    func insert(_ data: Data) -> (token: String, signature: String) {
        let token = Self.contentToken(for: data)
        let signature = "sha256:\(data.count):\(token)"
        let entry = ReaderExternalSegmentSidecarEntry(data: data, signature: signature)
        let isDurable = persistIfNeeded(data, token: token)

        lock.lock()
        insertIntoMemory(entry, token: token, isDurable: isDurable)
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
        insertIntoMemory(entry, token: token, isDurable: true)
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
        evictDurableEntriesIfNeeded()
    }

    private func touch(_ token: String) {
        tokensInAccessOrder.removeAll { $0 == token }
        tokensInAccessOrder.append(token)
    }

    private func evictDurableEntriesIfNeeded() {
        while entries.count > countLimit || (totalBytes > totalByteLimit && entries.count > 1) {
            guard let index = tokensInAccessOrder.firstIndex(where: durableTokens.contains) else { break }
            let token = tokensInAccessOrder.remove(at: index)
            durableTokens.remove(token)
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

private let readerProcessedSegmentSidecarEnvelopePrefix = Array("MNBPSC3".utf8)
private let readerProcessedSegmentSidecarEnvelopeLengthByteCount = MemoryLayout<UInt64>.size

func splitCanonicalReaderSegmentSidecar(
    from htmlBytes: [UInt8]
) -> EbookProcessedSectionPayload? {
    guard let ranges = canonicalReaderSegmentSidecarRanges(in: htmlBytes) else { return nil }
    let sidecar = Data(htmlBytes[ranges.content])
    guard !sidecar.isEmpty else { return nil }

    var documentHTML = Data()
    documentHTML.reserveCapacity(htmlBytes.count - ranges.element.count)
    documentHTML.append(contentsOf: htmlBytes[..<ranges.element.lowerBound])
    documentHTML.append(contentsOf: htmlBytes[ranges.element.upperBound...])
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
    let stored = store.insert(payload.segmentSidecar)
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
    let htmlBytes = Array(processedHTML.utf8)
    let generatedSegmentCount = generatedReaderSegmentCount(in: htmlBytes)
    let sidecarData: Data?
    if let ranges = canonicalReaderSegmentSidecarRanges(in: htmlBytes) {
        sidecarData = Data(htmlBytes[ranges.content])
    } else if let token = externalReaderSegmentSidecarToken(in: htmlBytes) {
        sidecarData = store.entry(for: token)?.data
    } else {
        sidecarData = nil
    }
    guard let sidecarData else {
        return generatedSegmentCount == 0
    }
    return readerSegmentSidecarHasDurableSegmentIdentities(
        sidecarData,
        generatedSegmentCount: generatedSegmentCount
    )
}

private func generatedReaderSegmentCount(in htmlBytes: [UInt8]) -> Int {
    let openingTag = Array("<m-m".utf8)
    let tagDelimiters: Set<UInt8> = [9, 10, 13, 32, 47, 62]
    var count = 0
    var index = htmlBytes.startIndex
    while index + openingTag.count <= htmlBytes.endIndex {
        guard htmlBytes[index..<(index + openingTag.count)].elementsEqual(openingTag) else {
            index += 1
            continue
        }
        let delimiterIndex = index + openingTag.count
        if delimiterIndex == htmlBytes.endIndex || tagDelimiters.contains(htmlBytes[delimiterIndex]) {
            count += 1
        }
        index = delimiterIndex
    }
    return count
}

private func generatedReaderSegmentCount(in documentHTML: Data) -> Int {
    let openingTag = Data("<m-m".utf8)
    let tagDelimiters: Set<UInt8> = [9, 10, 13, 32, 47, 62]
    var count = 0
    var searchRange = documentHTML.startIndex..<documentHTML.endIndex
    while let match = documentHTML.range(of: openingTag, options: [], in: searchRange) {
        if match.upperBound == documentHTML.endIndex
            || tagDelimiters.contains(documentHTML[match.upperBound]) {
            count += 1
        }
        searchRange = match.upperBound..<documentHTML.endIndex
    }
    return count
}

func externalizingCanonicalReaderSegmentSidecar(
    in htmlBytes: [UInt8],
    scheme: ReaderExternalSegmentSidecarScheme,
    store: ReaderExternalSegmentSidecarStore = .shared
) -> ReaderExternalizedSegmentSidecarHTML {
    guard let ranges = canonicalReaderSegmentSidecarRanges(in: htmlBytes) else {
        return ReaderExternalizedSegmentSidecarHTML(
            documentHTML: Data(htmlBytes),
            canonicalSidecarByteCount: 0,
            signature: nil,
            endpointURL: nil
        )
    }
    let sidecar = Data(htmlBytes[ranges.content])
    guard !sidecar.isEmpty else {
        return ReaderExternalizedSegmentSidecarHTML(
            documentHTML: Data(htmlBytes),
            canonicalSidecarByteCount: 0,
            signature: nil,
            endpointURL: nil
        )
    }
    let htmlData = Data(htmlBytes)
    var documentWithoutSidecar = Data()
    documentWithoutSidecar.reserveCapacity(htmlBytes.count - ranges.element.count)
    documentWithoutSidecar.append(htmlData[..<ranges.element.lowerBound])
    documentWithoutSidecar.append(htmlData[ranges.element.upperBound...])
    return externalizingReaderSegmentSidecar(
        documentHTML: documentWithoutSidecar.map { $0 },
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
    guard !canonicalSidecar.isEmpty else {
        return ReaderExternalizedSegmentSidecarHTML(
            documentHTML: Data(documentHTML),
            canonicalSidecarByteCount: 0,
            signature: nil,
            endpointURL: nil
        )
    }
    let stored = store.insert(canonicalSidecar)
    let endpointURL = scheme.endpointURL(token: stored.token)
    let descriptorHTML = "<meta name=\"mnb-segment-sidecar\" content=\"\(endpointURL)\" "
        + "data-mnb-segment-sidecar-signature=\"\(stored.signature)\">"
    let descriptor = Data(descriptorHTML.utf8)
    let documentWithoutSidecar = Data(documentHTML)
    let closingHead = Data("</head>".utf8)
    let openingBody = Data("<body".utf8)
    let insertionIndex = documentWithoutSidecar.range(of: closingHead)?.lowerBound
        ?? documentWithoutSidecar.range(of: openingBody)?.lowerBound
        ?? documentWithoutSidecar.startIndex
    var output = Data()
    output.reserveCapacity(documentWithoutSidecar.count + descriptor.count)
    output.append(documentWithoutSidecar[..<insertionIndex])
    output.append(descriptor)
    output.append(documentWithoutSidecar[insertionIndex...])
    return ReaderExternalizedSegmentSidecarHTML(
        documentHTML: output,
        canonicalSidecarByteCount: canonicalSidecar.count,
        signature: stored.signature,
        endpointURL: endpointURL
    )
}

private func externalReaderSegmentSidecarToken(in htmlBytes: [UInt8]) -> String? {
    let endpointPrefix = Array("content=\"ebook://ebook/processed-section-sidecar/".utf8)
    guard let prefixRange = Data(htmlBytes).range(of: Data(endpointPrefix)) else { return nil }
    let tokenStart = prefixRange.upperBound
    guard tokenStart < htmlBytes.count,
          let tokenEnd = htmlBytes[tokenStart...].firstIndex(of: UInt8(ascii: "\"")) else {
        return nil
    }
    let token = String(decoding: htmlBytes[tokenStart..<tokenEnd], as: UTF8.self)
    return token.isEmpty ? nil : token
}

private func canonicalReaderSegmentSidecarRanges(
    in htmlBytes: [UInt8]
) -> (element: Range<Int>, content: Range<Int>)? {
    let htmlData = Data(htmlBytes)
    let identifierIndex = [
        Data("id=\"mnb-segment-metadata\"".utf8),
        Data("id='mnb-segment-metadata'".utf8),
    ]
        .compactMap { htmlData.range(of: $0)?.lowerBound }
        .min()
    guard let identifierIndex,
          let openingTag = htmlData.range(
            of: Data("<script".utf8),
            options: .backwards,
            in: htmlData.startIndex..<identifierIndex
          ),
          let openingTagEnd = htmlData.range(
            of: Data(">".utf8),
            in: identifierIndex..<htmlData.endIndex
          )?.lowerBound,
          let closingTag = htmlData.range(
            of: Data("</script>".utf8),
            in: (openingTagEnd + 1)..<htmlData.endIndex
          ) else {
        return nil
    }
    return (
        openingTag.lowerBound..<closingTag.upperBound,
        (openingTagEnd + 1)..<closingTag.lowerBound
    )
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
