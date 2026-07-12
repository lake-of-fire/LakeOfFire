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

struct ReaderExternalSegmentSidecarEntry: Sendable {
    let data: Data
    let signature: String
}

final class ReaderExternalSegmentSidecarStore: @unchecked Sendable {
    static let shared = ReaderExternalSegmentSidecarStore()

    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)
    private static let lowNibbleMask: UInt8 = 0x0F

    private let lock = NSLock()
    private let totalByteLimit = 24 * 1024 * 1024
    private let countLimit = 32
    private var entries = [String: ReaderExternalSegmentSidecarEntry]()
    private var tokensInAccessOrder = [String]()
    private var totalBytes = 0

    private init() {}

    func insert(_ data: Data) -> (token: String, signature: String) {
        let token = Self.contentToken(for: data)
        let signature = "sha256:\(data.count):\(token)"
        let entry = ReaderExternalSegmentSidecarEntry(data: data, signature: signature)

        lock.lock()
        if let previous = entries.updateValue(entry, forKey: token) {
            totalBytes -= previous.data.count
        }
        if let index = tokensInAccessOrder.firstIndex(of: token) {
            tokensInAccessOrder.remove(at: index)
        }
        tokensInAccessOrder.append(token)
        totalBytes += data.count
        evictIfNeeded()
        lock.unlock()
        return (token, signature)
    }

    func entry(for token: String) -> ReaderExternalSegmentSidecarEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token] else { return nil }
        if let index = tokensInAccessOrder.firstIndex(of: token) {
            tokensInAccessOrder.remove(at: index)
            tokensInAccessOrder.append(token)
        }
        return entry
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

    private func evictIfNeeded() {
        while entries.count > countLimit || (totalBytes > totalByteLimit && entries.count > 1) {
            guard let token = tokensInAccessOrder.first else { break }
            tokensInAccessOrder.removeFirst()
            if let removed = entries.removeValue(forKey: token) {
                totalBytes -= removed.data.count
            }
        }
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
            "Cache-Control": "public, max-age=31536000, immutable",
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

private let readerProcessedSegmentSidecarEnvelopePrefix = Array("MNBPSC2".utf8)
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
