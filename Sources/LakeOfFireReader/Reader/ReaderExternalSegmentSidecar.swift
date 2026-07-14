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

func ebookProcessedSectionPayloadHasDurableSegmentIdentities(
    _ payload: EbookProcessedSectionPayload
) -> Bool {
    guard !payload.segmentSidecar.isEmpty else { return true }
    guard let object = try? JSONSerialization.jsonObject(with: payload.segmentSidecar),
          let root = object as? [String: Any],
          (root["v"] as? NSNumber)?.intValue == 9,
          let tables = root["t"] as? [String: Any],
          let hashes = tables["h"] as? [String],
          let sentenceIDs = tables["sid"] as? [String],
          let segments = root["s"] as? [[Any]] else {
        return false
    }
    guard !segments.isEmpty else { return true }

    func nonEmptyTableValue(_ table: [String], tuple: [Any], index: Int) -> Bool {
        guard tuple.indices.contains(index),
              let tableIndex = tuple[index] as? NSNumber,
              tableIndex.intValue >= 0,
              table.indices.contains(tableIndex.intValue) else {
            return false
        }
        return !table[tableIndex.intValue].isEmpty
    }

    return segments.allSatisfy { tuple in
        nonEmptyTableValue(hashes, tuple: tuple, index: 1)
            && nonEmptyTableValue(sentenceIDs, tuple: tuple, index: 9)
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
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
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
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let storedData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
               Self.contentToken(for: storedData) == token {
                return true
            }
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
            guard let index = tokensInAccessOrder.firstIndex(where: durableTokens.contains) else {
                break
            }
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

// Version 3 invalidates cached processed sections produced before durable `sid`
// was mandatory for every ebook segment.
private let readerProcessedSegmentSidecarEnvelopePrefix = Array("MNBPSC3".utf8)
private let readerProcessedSegmentSidecarEnvelopeLengthByteCount = MemoryLayout<UInt64>.size

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

public func encodedEbookProcessedSectionCacheValue(
    _ payload: EbookProcessedSectionPayload
) -> [UInt8] {
    var bytes = readerProcessedSegmentSidecarEnvelopePrefix
    bytes.reserveCapacity(
        readerProcessedSegmentSidecarEnvelopePrefix.count
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
