import Foundation
import CryptoKit
import UniformTypeIdentifiers
import ZIPFoundation
import LakeOfFireCore
import LakeOfFireAdblock

public extension Archive {
    func data(for subpath: String) -> Data? {
        guard let entry = self[subpath] else { return nil }
        
        var data = Data()
        do {
            _ = try self.extract(entry) { data.append($0) }
            return data
        } catch {
            return nil
        }
    }
}

public struct ReaderPackageEntryMetadata: Codable, Hashable, Sendable {
    public let path: String
    public let size: Int

    public init(path: String, size: Int) {
        self.path = path
        self.size = size
    }
}

public struct ReaderPackageEntryResponseMetadata: Sendable {
    public let mimeType: String
    public let textEncodingName: String?

    public init(mimeType: String, textEncodingName: String?) {
        self.mimeType = mimeType
        self.textEncodingName = textEncodingName
    }
}

public enum ReaderPackageEntrySourceError: Error, Equatable, Sendable {
    case invalidSubpath
    case entryNotFound
    case ambiguousEntry
    case cancelled
    case unsupportedSource
}

public struct ReaderPackageEntrySource: Sendable {
    public enum Kind: Sendable {
        case directory(rootURL: URL)
        case archive(fileURL: URL)
    }

    private struct ArchiveCatalog: Sendable {
        let entries: [ReaderPackageEntryMetadata]
        let paths: Set<String>
        let validationError: ReaderPackageEntrySourceError?
    }

    private let kind: Kind
    private let archiveCatalog: ArchiveCatalog?

    public init(localURL: URL) throws {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            kind = .directory(
                rootURL: localURL.standardizedFileURL.resolvingSymlinksInPath()
            )
            archiveCatalog = nil
            return
        }

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }

        let fileURL = localURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let archive = try? Archive(url: fileURL, accessMode: .read) else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }
        kind = .archive(fileURL: fileURL)
        archiveCatalog = Self.makeArchiveCatalog(from: archive, fileURL: fileURL)
    }

    public func enumerateEntries() throws -> [ReaderPackageEntryMetadata] {
        switch kind {
        case .directory(let rootURL):
            return try enumerateDirectoryEntries(rootURL: rootURL)
        case .archive:
            return try enumerateArchiveEntries()
        }
    }

    public func readEntry(
        subpath rawSubpath: String,
        progress: Progress? = nil
    ) throws -> Data {
        let subpath = try Self.sanitizeSubpath(rawSubpath)
        switch kind {
        case .directory(let rootURL):
            let fileURL = try Self.resolveDirectoryURL(rootURL: rootURL, subpath: subpath)
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else {
                throw ReaderPackageEntrySourceError.entryNotFound
            }
            return try Self.readDirectoryEntry(
                at: fileURL,
                size: values?.fileSize,
                progress: progress
            )
        case .archive(let fileURL):
            guard let archiveCatalog else {
                throw ReaderPackageEntrySourceError.unsupportedSource
            }
            if let validationError = archiveCatalog.validationError {
                throw validationError
            }
            guard archiveCatalog.paths.contains(subpath) else {
                throw ReaderPackageEntrySourceError.entryNotFound
            }
            guard let archive = try? Archive(url: fileURL, accessMode: .read),
                  let entry = archive[subpath],
                  entry.type == .file else {
                throw ReaderPackageEntrySourceError.entryNotFound
            }
            var data = Data()
            do {
                try archive.extract(entry, progress: progress) { data.append($0) }
            } catch Archive.ArchiveError.cancelledOperation {
                throw ReaderPackageEntrySourceError.cancelled
            } catch Archive.ArchiveError.invalidCompressionMethod {
                throw ReaderPackageEntrySourceError.unsupportedSource
            }
            return data
        }
    }

    public func mimeType(subpath rawSubpath: String) throws -> ReaderPackageEntryResponseMetadata {
        let subpath = try Self.sanitizeSubpath(rawSubpath)
        let fileExtension = (subpath as NSString).pathExtension.lowercased()
        if let metadata = Self.knownResponseMetadata(forExtension: fileExtension) {
            return metadata
        }
        let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        let textEncodingName = Self.isUTF8TextType(utType: type, mimeType: mimeType) ? "utf-8" : nil
        return ReaderPackageEntryResponseMetadata(mimeType: mimeType, textEncodingName: textEncodingName)
    }

    public func mimeType(
        subpath rawSubpath: String,
        data: Data
    ) throws -> ReaderPackageEntryResponseMetadata {
        let metadata = try mimeType(subpath: rawSubpath)
        guard metadata.textEncodingName != nil else { return metadata }
        return ReaderPackageEntryResponseMetadata(
            mimeType: metadata.mimeType,
            textEncodingName: Self.detectedTextEncoding(in: data).ianaName
        )
    }

    public static func decodeText(_ data: Data) -> String {
        let encoding = detectedTextEncoding(in: data).foundationEncoding
        if let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func knownResponseMetadata(
        forExtension fileExtension: String
    ) -> ReaderPackageEntryResponseMetadata? {
        let metadata: (mimeType: String, textEncodingName: String?)
        switch fileExtension {
        case "xhtml":
            metadata = ("application/xhtml+xml", "utf-8")
        case "html", "htm":
            metadata = ("text/html", "utf-8")
        case "opf":
            metadata = ("application/oebps-package+xml", "utf-8")
        case "ncx":
            metadata = ("application/x-dtbncx+xml", "utf-8")
        case "xml":
            metadata = ("application/xml", "utf-8")
        case "svg":
            metadata = ("image/svg+xml", "utf-8")
        case "css":
            metadata = ("text/css", "utf-8")
        case "js", "mjs":
            metadata = ("text/javascript", "utf-8")
        case "json":
            metadata = ("application/json", "utf-8")
        case "txt":
            metadata = ("text/plain", "utf-8")
        case "ttf":
            metadata = ("font/ttf", nil)
        case "otf":
            metadata = ("font/otf", nil)
        case "woff":
            metadata = ("font/woff", nil)
        case "woff2":
            metadata = ("font/woff2", nil)
        case "wav":
            metadata = ("audio/wav", nil)
        case "mp3":
            metadata = ("audio/mpeg", nil)
        case "m4a":
            metadata = ("audio/mp4", nil)
        case "aac":
            metadata = ("audio/aac", nil)
        case "mp4":
            metadata = ("video/mp4", nil)
        case "webm":
            metadata = ("video/webm", nil)
        default:
            return nil
        }
        return ReaderPackageEntryResponseMetadata(
            mimeType: metadata.mimeType,
            textEncodingName: metadata.textEncodingName
        )
    }

    private struct DetectedTextEncoding {
        let ianaName: String
        let foundationEncoding: String.Encoding
    }

    private static func detectedTextEncoding(in data: Data) -> DetectedTextEncoding {
        let prefix = Array(data.prefix(4))
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) {
            return DetectedTextEncoding(ianaName: "utf-8", foundationEncoding: .utf8)
        }
        if prefix.starts(with: [0xFF, 0xFE]) {
            return DetectedTextEncoding(ianaName: "utf-16le", foundationEncoding: .utf16)
        }
        if prefix.starts(with: [0xFE, 0xFF]) {
            return DetectedTextEncoding(ianaName: "utf-16be", foundationEncoding: .utf16)
        }
        if prefix.count == 4 {
            if prefix[1] == 0x00,
               prefix[3] == 0x00,
               prefix[0] != 0x00 || prefix[2] != 0x00 {
                return DetectedTextEncoding(
                    ianaName: "utf-16le",
                    foundationEncoding: .utf16LittleEndian
                )
            }
            if prefix[0] == 0x00,
               prefix[2] == 0x00,
               prefix[1] != 0x00 || prefix[3] != 0x00 {
                return DetectedTextEncoding(
                    ianaName: "utf-16be",
                    foundationEncoding: .utf16BigEndian
                )
            }
        }
        return DetectedTextEncoding(ianaName: "utf-8", foundationEncoding: .utf8)
    }

    public static func sanitizeSubpath(_ rawSubpath: String) throws -> String {
        guard !rawSubpath.isEmpty,
              !rawSubpath.hasPrefix("/"),
              !rawSubpath.contains("\\"),
              !rawSubpath.contains("\0") else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        let components = rawSubpath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        let normalized = components.joined(separator: "/")
        guard !normalized.isEmpty else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }
        return normalized
    }

    public static func resolveDirectoryURL(rootURL: URL, subpath rawSubpath: String) throws -> URL {
        let subpath = try sanitizeSubpath(rawSubpath)
        let resolvedRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedURL = resolvedRootURL
            .appendingPathComponent(subpath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootComponents = resolvedRootURL.pathComponents
        let resolvedComponents = resolvedURL.pathComponents
        guard resolvedComponents.count > rootComponents.count,
              Array(resolvedComponents.prefix(rootComponents.count)) == rootComponents else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }
        return resolvedURL
    }

    private func enumerateDirectoryEntries(rootURL: URL) throws -> [ReaderPackageEntryMetadata] {
        let standardizedRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let enumerator = FileManager.default.enumerator(
            at: standardizedRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var entries = [ReaderPackageEntryMetadata]()
        while let fileURL = enumerator?.nextObject() as? URL {
            let relativePath = try Self.relativeSubpath(fileURL: fileURL, rootURL: standardizedRootURL)
            let subpath = try Self.sanitizeSubpath(relativePath)
            guard (try? Self.resolveDirectoryURL(
                rootURL: standardizedRootURL,
                subpath: subpath
            )) != nil else {
                continue
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            entries.append(ReaderPackageEntryMetadata(path: subpath, size: values.fileSize ?? 0))
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func relativeSubpath(fileURL: URL, rootURL: URL) throws -> String {
        let standardizedRootURL = rootURL.standardizedFileURL
        let standardizedFileURL = fileURL.standardizedFileURL
        let rootComponents = standardizedRootURL.pathComponents
        let fileComponents = standardizedFileURL.pathComponents

        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func enumerateArchiveEntries() throws -> [ReaderPackageEntryMetadata] {
        guard case .archive = kind,
              let archiveCatalog else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }
        if let validationError = archiveCatalog.validationError {
            throw validationError
        }
        return archiveCatalog.entries
    }

    private static func makeArchiveCatalog(
        from archive: Archive,
        fileURL: URL
    ) -> ArchiveCatalog {
        var metadataByPath = [String: ReaderPackageEntryMetadata]()
        var duplicatePaths = Set<String>()
        var hasInvalidEntry = false
        var parsedEntryCount: UInt64 = 0
        for entry in archive {
            parsedEntryCount += 1
            guard entry.type == .file else { continue }
            guard entry.uncompressedSize <= UInt64(Int.max),
                  let path = try? sanitizeSubpath(entry.path),
                  path == entry.path else {
                hasInvalidEntry = true
                continue
            }
            guard metadataByPath[path] == nil else {
                duplicatePaths.insert(path)
                continue
            }
            metadataByPath[path] = ReaderPackageEntryMetadata(
                path: path,
                size: Int(entry.uncompressedSize)
            )
        }
        let validationError: ReaderPackageEntrySourceError?
        if declaredArchiveEntryCount(at: fileURL) != parsedEntryCount {
            validationError = .unsupportedSource
        } else if hasInvalidEntry {
            validationError = .invalidSubpath
        } else if !duplicatePaths.isEmpty {
            validationError = .ambiguousEntry
        } else {
            validationError = nil
        }
        return ArchiveCatalog(
            entries: metadataByPath.values.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            },
            paths: Set(metadataByPath.keys),
            validationError: validationError
        )
    }

    private static func declaredArchiveEntryCount(at fileURL: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(),
              fileSize >= 22 else {
            return nil
        }
        let tailByteCount = Int(min(fileSize, UInt64(65_557)))
        guard (try? handle.seek(toOffset: fileSize - UInt64(tailByteCount))) != nil,
              let tail = try? handle.read(upToCount: tailByteCount),
              tail.count == tailByteCount,
              let endRecordOffset = zipEndOfCentralDirectoryOffset(in: tail) else {
            return nil
        }
        let diskNumber = littleEndianUInt16(in: tail, at: endRecordOffset + 4)
        let centralDirectoryDisk = littleEndianUInt16(in: tail, at: endRecordOffset + 6)
        let entriesOnDisk = littleEndianUInt16(in: tail, at: endRecordOffset + 8)
        let totalEntries = littleEndianUInt16(in: tail, at: endRecordOffset + 10)
        guard diskNumber == 0,
              centralDirectoryDisk == 0,
              entriesOnDisk == totalEntries else {
            return nil
        }
        if totalEntries != UInt16.max {
            return UInt64(totalEntries)
        }

        let absoluteEndRecordOffset = fileSize - UInt64(tailByteCount) + UInt64(endRecordOffset)
        guard absoluteEndRecordOffset >= 20,
              (try? handle.seek(toOffset: absoluteEndRecordOffset - 20)) != nil,
              let locator = try? handle.read(upToCount: 20),
              locator.count == 20,
              littleEndianUInt32(in: locator, at: 0) == 0x07064B50,
              littleEndianUInt32(in: locator, at: 4) == 0,
              littleEndianUInt32(in: locator, at: 16) == 1 else {
            return nil
        }
        let zip64EndRecordOffset = littleEndianUInt64(in: locator, at: 8)
        guard (try? handle.seek(toOffset: zip64EndRecordOffset)) != nil,
              let zip64EndRecord = try? handle.read(upToCount: 56),
              zip64EndRecord.count == 56,
              littleEndianUInt32(in: zip64EndRecord, at: 0) == 0x06064B50,
              littleEndianUInt32(in: zip64EndRecord, at: 16) == 0,
              littleEndianUInt32(in: zip64EndRecord, at: 20) == 0 else {
            return nil
        }
        let entriesOnDisk64 = littleEndianUInt64(in: zip64EndRecord, at: 24)
        let totalEntries64 = littleEndianUInt64(in: zip64EndRecord, at: 32)
        guard entriesOnDisk64 == totalEntries64 else { return nil }
        return totalEntries64
    }

    private static func zipEndOfCentralDirectoryOffset(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var offset = data.count - 22
        while offset >= 0 {
            if littleEndianUInt32(in: data, at: offset) == 0x06054B50 {
                let commentLength = Int(littleEndianUInt16(in: data, at: offset + 20))
                if offset + 22 + commentLength == data.count {
                    return offset
                }
            }
            offset -= 1
        }
        return nil
    }

    private static func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for byteOffset in 0..<4 {
            value |= UInt32(data[offset + byteOffset]) << UInt32(byteOffset * 8)
        }
        return value
    }

    private static func littleEndianUInt64(in data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byteOffset in 0..<8 {
            value |= UInt64(data[offset + byteOffset]) << UInt64(byteOffset * 8)
        }
        return value
    }

    private static func readDirectoryEntry(
        at fileURL: URL,
        size: Int?,
        progress: Progress?
    ) throws -> Data {
        if progress?.isCancelled == true {
            throw ReaderPackageEntrySourceError.cancelled
        }
        progress?.totalUnitCount = Int64(size ?? 0)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var data = Data()
        if let size {
            data.reserveCapacity(size)
        }
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if progress?.isCancelled == true {
                throw ReaderPackageEntrySourceError.cancelled
            }
            data.append(chunk)
            progress?.completedUnitCount += Int64(chunk.count)
        }
        if progress?.isCancelled == true {
            throw ReaderPackageEntrySourceError.cancelled
        }
        return data
    }

    private static func isUTF8TextType(utType: UTType?, mimeType: String) -> Bool {
        if let utType, utType.conforms(to: .text) {
            return true
        }

        switch mimeType.lowercased() {
        case "application/xhtml+xml",
             "application/xml",
             "text/xml",
             "application/oebps-package+xml",
             "application/x-dtbncx+xml",
             "image/svg+xml",
             "text/css",
             "text/javascript",
             "application/javascript",
             "application/json",
             "text/html",
             "text/plain":
            return true
        default:
            return mimeType.hasSuffix("+xml")
        }
    }
}

public actor ReaderPackageEntrySourceCache {
    public static let shared = ReaderPackageEntrySourceCache()

    public struct CachedSource: Sendable {
        public let source: ReaderPackageEntrySource
        public let entries: [ReaderPackageEntryMetadata]
        public let generationID: String

        public init(
            source: ReaderPackageEntrySource,
            entries: [ReaderPackageEntryMetadata],
            generationID: String
        ) {
            self.source = source
            self.entries = entries
            self.generationID = generationID
        }
    }

    private struct CacheRecord: Sendable {
        let source: ReaderPackageEntrySource
        let entries: [ReaderPackageEntryMetadata]
        let localURL: URL
        let freshnessToken: String
        let generationID: String
    }

    private let countLimit: Int
    private var cachedSources: [String: CacheRecord] = [:]
    private var accessOrder: [String] = []

    public init(countLimit: Int = 8) {
        self.countLimit = max(1, countLimit)
    }

    public func cachedSource(
        forPackageURL readerFileURL: URL,
        readerFileManager: ReaderFileManager
    ) async throws -> CachedSource {
        try Task.checkCancellation()
        let diagnosticLocalURL = Self.diagnosticLocalFileURL(forPackageURL: readerFileURL)
        let canonicalReaderBackingURL = readerFileManager.canonicalReaderBackingURL(for: readerFileURL) ?? readerFileURL
        let cacheKey = diagnosticLocalURL.map { "diagnosticLocalFilePath:\($0.standardizedFileURL.path)" }
            ?? canonicalReaderBackingURL.absoluteString
        if let cached = try freshCachedSource(forKey: cacheKey) {
            return cached
        }
        let localURL: URL
        if let diagnosticLocalURL {
            localURL = diagnosticLocalURL
        } else {
            localURL = try await Self.resolvedLocalURL(
                forPackageURL: canonicalReaderBackingURL,
                readerFileManager: readerFileManager
            )
        }
        try Task.checkCancellation()
        let freshnessToken = try Self.freshnessToken(for: localURL)
        try Task.checkCancellation()

        if let cached = cachedSources[cacheKey],
           cached.localURL == localURL,
           cached.freshnessToken == freshnessToken {
            recordAccess(forKey: cacheKey)
            return CachedSource(
                source: cached.source,
                entries: cached.entries,
                generationID: cached.generationID
            )
        }

        let source = try ReaderPackageEntrySource(localURL: localURL)
        let entries = try source.enumerateEntries()
        try Task.checkCancellation()
        let generationID = Self.generationID(for: freshnessToken)
        store(
            CacheRecord(
                source: source,
                entries: entries,
                localURL: localURL,
                freshnessToken: freshnessToken,
                generationID: generationID
            ),
            forKey: cacheKey
        )
        return CachedSource(
            source: source,
            entries: entries,
            generationID: generationID
        )
    }

    private func freshCachedSource(forKey cacheKey: String) throws -> CachedSource? {
        guard let cached = cachedSources[cacheKey] else {
            return nil
        }
        guard let freshnessToken = try? Self.freshnessToken(for: cached.localURL),
              cached.freshnessToken == freshnessToken else {
            removeCachedSource(forKey: cacheKey)
            return nil
        }
        try Task.checkCancellation()
        recordAccess(forKey: cacheKey)
        return CachedSource(
            source: cached.source,
            entries: cached.entries,
            generationID: cached.generationID
        )
    }

    private func store(_ record: CacheRecord, forKey cacheKey: String) {
        cachedSources[cacheKey] = record
        recordAccess(forKey: cacheKey)
        while cachedSources.count > countLimit, let oldestKey = accessOrder.first {
            removeCachedSource(forKey: oldestKey)
        }
    }

    private func recordAccess(forKey cacheKey: String) {
        accessOrder.removeAll { $0 == cacheKey }
        accessOrder.append(cacheKey)
    }

    private func removeCachedSource(forKey cacheKey: String) {
        cachedSources.removeValue(forKey: cacheKey)
        accessOrder.removeAll { $0 == cacheKey }
    }

#if DEBUG
    func cachedSourceCountForTesting() -> Int {
        cachedSources.count
    }

    func cachedSourcePathsInLRUOrderForTesting() -> [String] {
        accessOrder.compactMap { cachedSources[$0]?.localURL.standardizedFileURL.path }
    }
#endif

    private static func generationID(for freshnessToken: String) -> String {
        let digest = SHA256.hash(data: Data(freshnessToken.utf8))
        return "g1-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func resolvedLocalURL(
        forPackageURL readerFileURL: URL,
        readerFileManager: ReaderFileManager
    ) async throws -> URL {
        let readerBackingURL = readerFileManager.canonicalReaderBackingURL(for: readerFileURL) ?? readerFileURL
        let localURL = try await readerFileManager.resolveReadableLocalURL(forReaderBackingURL: readerBackingURL)
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return localURL
        }
        return localURL
    }

    private static func diagnosticLocalFileURL(forPackageURL readerFileURL: URL) -> URL? {
#if DEBUG
        guard let components = URLComponents(url: readerFileURL, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "diagnosticLocalFilePath" })?.value,
              !path.isEmpty else {
            return nil
        }

        let localURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            return nil
        }
        return localURL
#else
        return nil
#endif
    }

    private static func freshnessToken(for localURL: URL) throws -> String {
        let standardizedURL = localURL.standardizedFileURL
        let values = try standardizedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey
        ])
        let modificationDate = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = values.fileSize ?? 0
        let isDirectory = values.isDirectory ?? false
        guard isDirectory else {
            return [
                standardizedURL.path,
                String(modificationDate.bitPattern),
                String(fileSize),
                "false",
            ].joined(separator: "|")
        }

        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey
        ]
        let enumerator = FileManager.default.enumerator(
            at: standardizedURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        var descendantMetadata = [String]()

        while let childURL = enumerator?.nextObject() as? URL {
            let childValues = try childURL.resourceValues(forKeys: resourceKeys)
            let childModificationDate = childValues.contentModificationDate?.timeIntervalSince1970 ?? 0
            descendantMetadata.append([
                childURL.standardizedFileURL.path,
                String(childModificationDate.bitPattern),
                String(childValues.fileSize ?? 0),
                childValues.isDirectory == true ? "directory" : "file",
            ].joined(separator: "\u{0}"))
        }

        var metadataHasher = SHA256()
        for metadata in descendantMetadata.sorted() {
            metadataHasher.update(data: Data(metadata.utf8))
            metadataHasher.update(data: Data([0]))
        }
        let metadataDigest = metadataHasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return [
            standardizedURL.path,
            String(modificationDate.bitPattern),
            String(fileSize),
            "true",
            metadataDigest,
        ].joined(separator: "|")
    }
}
