import Foundation
import LakeOfFireCore
import SwiftUIWebView
import UniformTypeIdentifiers
import ZIPFoundation

public extension Archive {
    func data(for subpath: String) -> Data? {
        guard let subpath = try? ReaderPackageEntrySource.sanitizeSubpath(subpath),
              let entry = self[subpath] else { return nil }

        // This convenience API predates ReaderPackageEntrySource. Keep it
        // bounded as it is also used by callers handling untrusted archives.
        guard entry.uncompressedSize <= UInt64(ReaderPackageResourceLimits.default.maxEntryBytes) else {
            return nil
        }
        
        var data = Data()
        var actualSize: Int64 = 0
        do {
            _ = try self.extract(entry) { chunk in
                try Task.checkCancellation()
                let chunkSize = Int64(chunk.count)
                let (newSize, overflow) = actualSize.addingReportingOverflow(chunkSize)
                guard !overflow, newSize <= ReaderPackageResourceLimits.default.maxEntryBytes else {
                    throw ReaderPackageEntrySourceError.actualEntrySizeExceeded(
                        path: entry.path,
                        size: overflow ? Int64.max : newSize,
                        limit: ReaderPackageResourceLimits.default.maxEntryBytes
                    )
                }
                actualSize = newSize
                data.append(chunk)
            }
            return data
        } catch {
            return nil
        }
    }
}

/// Limits applied while inspecting or extracting a package. ZIP headers are
/// untrusted input: advertised sizes are checked before allocation, and the
/// consumer is checked again while decompression produces bytes.
public struct ReaderPackageResourceLimits: Sendable, Equatable {
    public let maxEntryCount: Int
    public let maxEntryBytes: Int64
    public let maxAggregateUncompressedBytes: Int64

    public init(
        maxEntryCount: Int = 100_000,
        maxEntryBytes: Int64 = 64 * 1024 * 1024,
        maxAggregateUncompressedBytes: Int64 = 8 * 1024 * 1024 * 1024
    ) {
        self.maxEntryCount = max(0, maxEntryCount)
        self.maxEntryBytes = max(0, maxEntryBytes)
        self.maxAggregateUncompressedBytes = max(0, maxAggregateUncompressedBytes)
    }

    public static let `default` = Self()

    /// Container metadata should be small. This also bounds a malformed EPUB
    /// before XMLParser is given any input.
    public static let metadata = Self(
        maxEntryCount: 25_000,
        maxEntryBytes: 8 * 1024 * 1024,
        maxAggregateUncompressedBytes: 8 * 1024 * 1024 * 1024
    )

    /// Images need more room than package metadata, but still must not be
    /// allowed to expand without bound in a WebKit scheme request.
    public static let image = Self(
        maxEntryCount: 100_000,
        maxEntryBytes: 128 * 1024 * 1024,
        maxAggregateUncompressedBytes: 8 * 1024 * 1024 * 1024
    )
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

public enum ReaderPackageEntrySourceError: Swift.Error, Sendable {
    case invalidSubpath
    case entryNotFound
    case unsupportedSource
    case packageCorrupt
    case entryCountExceeded(limit: Int)
    case entrySizeExceeded(path: String, size: Int64, limit: Int64)
    case aggregateSizeExceeded(size: Int64, limit: Int64)
    case actualEntrySizeExceeded(path: String, size: Int64, limit: Int64)
}

public struct ReaderPackageEntrySource: Sendable {
    public enum Kind: Sendable {
        case directory(rootURL: URL)
        case archive(fileURL: URL)
    }

    private let kind: Kind
    private let limits: ReaderPackageResourceLimits

    public init(
        localURL: URL,
        limits: ReaderPackageResourceLimits = .default
    ) throws {
        self.limits = limits
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            kind = .directory(rootURL: localURL.standardizedFileURL)
            return
        }

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }

        // Open once during construction so malformed ZIP structures are
        // reported as a typed package error instead of leaking a
        // ZIPFoundation implementation error from a later request.
        do {
            _ = try Archive(url: localURL, accessMode: .read)
        } catch {
            throw ReaderPackageEntrySourceError.packageCorrupt
        }

        kind = .archive(fileURL: localURL.standardizedFileURL)
    }

    public func enumerateEntries() throws -> [ReaderPackageEntryMetadata] {
        switch kind {
        case .directory(let rootURL):
            return try enumerateDirectoryEntries(rootURL: rootURL)
        case .archive(let fileURL):
            return try enumerateArchiveEntries(fileURL: fileURL)
        }
    }

    public func readEntry(subpath rawSubpath: String) throws -> Data {
        let subpath = try Self.sanitizeSubpath(rawSubpath)
        switch kind {
        case .directory(let rootURL):
            let fileURL = try Self.resolveDirectoryURL(rootURL: rootURL, subpath: subpath)
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw ReaderPackageEntrySourceError.entryNotFound
            }
            let advertisedSize = Int64(values.fileSize ?? 0)
            guard advertisedSize <= limits.maxEntryBytes else {
                throw ReaderPackageEntrySourceError.entrySizeExceeded(
                    path: subpath,
                    size: advertisedSize,
                    limit: limits.maxEntryBytes
                )
            }
            return try Self.readFile(
                at: fileURL,
                subpath: subpath,
                limit: limits.maxEntryBytes
            )
        case .archive(let fileURL):
            let archive: Archive
            do {
                archive = try Archive(url: fileURL, accessMode: .read)
            } catch {
                throw ReaderPackageEntrySourceError.packageCorrupt
            }
            guard let entry = archive[subpath],
                  entry.type == .file else {
                throw ReaderPackageEntrySourceError.entryNotFound
            }
            let advertisedSize = try Self.checkedSize(of: entry)
            guard advertisedSize <= limits.maxEntryBytes else {
                throw ReaderPackageEntrySourceError.entrySizeExceeded(
                    path: subpath,
                    size: advertisedSize,
                    limit: limits.maxEntryBytes
                )
            }
            var data = Data()
            var actualSize: Int64 = 0
            do {
                try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    let chunkSize = Int64(chunk.count)
                    let (newSize, overflow) = actualSize.addingReportingOverflow(chunkSize)
                    guard !overflow, newSize <= limits.maxEntryBytes else {
                        throw ReaderPackageEntrySourceError.actualEntrySizeExceeded(
                            path: subpath,
                            size: overflow ? Int64.max : newSize,
                            limit: limits.maxEntryBytes
                        )
                    }
                    actualSize = newSize
                    data.append(chunk)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ReaderPackageEntrySourceError {
                throw error
            } catch {
                throw ReaderPackageEntrySourceError.packageCorrupt
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

    private static func knownResponseMetadata(forExtension fileExtension: String) -> ReaderPackageEntryResponseMetadata? {
        let mimeType: String
        switch fileExtension {
        case "xhtml":
            mimeType = "application/xhtml+xml"
        case "html", "htm":
            mimeType = "text/html"
        case "opf":
            mimeType = "application/oebps-package+xml"
        case "ncx":
            mimeType = "application/x-dtbncx+xml"
        case "xml":
            mimeType = "application/xml"
        case "svg":
            mimeType = "image/svg+xml"
        case "css":
            mimeType = "text/css"
        case "js", "mjs":
            mimeType = "text/javascript"
        case "json":
            mimeType = "application/json"
        case "txt":
            mimeType = "text/plain"
        default:
            return nil
        }
        return ReaderPackageEntryResponseMetadata(
            mimeType: mimeType,
            textEncodingName: "utf-8"
        )
    }

    public static func sanitizeSubpath(_ rawSubpath: String) throws -> String {
        let trimmed = rawSubpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\") else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
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
            // Hidden files are still package entries. Omitting them here
            // would let an oversized hidden file bypass the aggregate budget
            // while remaining directly readable by subpath.
            options: []
        )

        var entries = [ReaderPackageEntryMetadata]()
        var entryCount = 0
        var aggregateSize: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            try Task.checkCancellation()
            entryCount += 1
            guard entryCount <= limits.maxEntryCount else {
                throw ReaderPackageEntrySourceError.entryCountExceeded(limit: limits.maxEntryCount)
            }
            let relativePath = try Self.relativeSubpath(fileURL: fileURL, rootURL: standardizedRootURL)
            let subpath = try Self.sanitizeSubpath(relativePath)
            guard let resolvedURL = try? Self.resolveDirectoryURL(
                rootURL: standardizedRootURL,
                subpath: subpath
            ) else {
                // Do not descend through a symlink that escapes the package.
                enumerator?.skipDescendants()
                continue
            }
            let values = try fileURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if values.isSymbolicLink == true {
                // A symlink is a valid package entry only when its resolved
                // target remains inside this package.  Keep safe internal
                // aliases addressable, while the same containment check
                // excludes links that escape the package root.
                enumerator?.skipDescendants()
                guard let resolvedValues = try? resolvedURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                ),
                resolvedValues.isRegularFile == true else {
                    continue
                }
                let size = Int64(resolvedValues.fileSize ?? 0)
                try Self.validateEntry(
                    path: subpath,
                    size: size,
                    aggregateSize: &aggregateSize,
                    limits: limits
                )
                entries.append(
                    ReaderPackageEntryMetadata(
                        path: subpath,
                        size: Int(min(size, Int64(Int.max)))
                    )
                )
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            try Self.validateEntry(
                path: subpath,
                size: size,
                aggregateSize: &aggregateSize,
                limits: limits
            )
            entries.append(ReaderPackageEntryMetadata(path: subpath, size: Int(min(size, Int64(Int.max)))))
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

    private func enumerateArchiveEntries(fileURL: URL) throws -> [ReaderPackageEntryMetadata] {
        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            throw ReaderPackageEntrySourceError.packageCorrupt
        }

        var seenSubpaths = Set<String>()
        var entries = [ReaderPackageEntryMetadata]()
        var entryCount = 0
        var aggregateSize: Int64 = 0
        for entry in archive {
            try Task.checkCancellation()
            entryCount += 1
            guard entryCount <= limits.maxEntryCount else {
                throw ReaderPackageEntrySourceError.entryCountExceeded(limit: limits.maxEntryCount)
            }
            guard entry.type == .file else { continue }
            let size = try Self.checkedSize(of: entry)
            try Self.validateAdvertisedSize(
                path: entry.path,
                size: size,
                aggregateSize: &aggregateSize,
                limits: limits
            )
            guard let subpath = try? Self.sanitizeSubpath(entry.path),
                  subpath == entry.path,
                  seenSubpaths.insert(subpath).inserted else {
                continue
            }
            entries.append(ReaderPackageEntryMetadata(path: subpath, size: Int(size)))
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func checkedSize(of entry: Entry) throws -> Int64 {
        guard entry.uncompressedSize <= UInt64(Int64.max) else {
            throw ReaderPackageEntrySourceError.entrySizeExceeded(
                path: entry.path,
                size: Int64.max,
                limit: Int64.max
            )
        }
        return Int64(entry.uncompressedSize)
    }

    private static func validateAdvertisedSize(
        path: String,
        size: Int64,
        aggregateSize: inout Int64,
        limits: ReaderPackageResourceLimits
    ) throws {
        guard size <= limits.maxEntryBytes else {
            throw ReaderPackageEntrySourceError.entrySizeExceeded(
                path: path,
                size: size,
                limit: limits.maxEntryBytes
            )
        }
        let (newAggregate, overflow) = aggregateSize.addingReportingOverflow(size)
        guard !overflow, newAggregate <= limits.maxAggregateUncompressedBytes else {
            throw ReaderPackageEntrySourceError.aggregateSizeExceeded(
                size: overflow ? Int64.max : newAggregate,
                limit: limits.maxAggregateUncompressedBytes
            )
        }
        aggregateSize = newAggregate
    }

    private static func validateEntry(
        path: String,
        size: Int64,
        aggregateSize: inout Int64,
        limits: ReaderPackageResourceLimits
    ) throws {
        try validateAdvertisedSize(path: path, size: size, aggregateSize: &aggregateSize, limits: limits)
    }

    private static func readFile(at url: URL, subpath: String, limit: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        var actualSize: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            let (newSize, overflow) = actualSize.addingReportingOverflow(Int64(chunk.count))
            guard !overflow, newSize <= limit else {
                throw ReaderPackageEntrySourceError.actualEntrySizeExceeded(
                    path: subpath,
                    size: overflow ? Int64.max : newSize,
                    limit: limit
                )
            }
            actualSize = newSize
            data.append(chunk)
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

        public init(source: ReaderPackageEntrySource, entries: [ReaderPackageEntryMetadata]) {
            self.source = source
            self.entries = entries
        }
    }

    private struct CacheRecord: Sendable {
        let source: ReaderPackageEntrySource
        let entries: [ReaderPackageEntryMetadata]
        let localURL: URL
        let freshnessToken: String
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
            try Task.checkCancellation()
            recordAccess(forKey: cacheKey)
            return CachedSource(source: cached.source, entries: cached.entries)
        }

        let source = try Self.preparedSource(for: localURL)
        let entries = try source.enumerateEntries()
        try Task.checkCancellation()
        store(
            CacheRecord(
                source: source,
                entries: entries,
                localURL: localURL,
                freshnessToken: freshnessToken
            ),
            forKey: cacheKey
        )
        return CachedSource(source: source, entries: entries)
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
        return CachedSource(source: cached.source, entries: cached.entries)
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

    private static func resolvedLocalURL(
        forPackageURL readerFileURL: URL,
        readerFileManager: ReaderFileManager
    ) async throws -> URL {
        let readerBackingURL = readerFileManager.canonicalReaderBackingURL(for: readerFileURL) ?? readerFileURL
        return try await readerFileManager.resolveReadableLocalURL(forReaderBackingURL: readerBackingURL)
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

    private static func preparedSource(for localURL: URL) throws -> ReaderPackageEntrySource {
        try ReaderPackageEntrySource(localURL: localURL)
    }

    private static func freshnessToken(for localURL: URL) throws -> String {
        let standardizedURL = localURL.standardizedFileURL
        let values = try standardizedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
        ])
        let modificationDate = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = values.fileSize ?? 0
        let isDirectory = values.isDirectory ?? false
        // Reader packages are immutable while loaded. Recursively rescanning a
        // directory here made every entry request O(package size) and performed
        // unbounded work before `enumerateEntries()` could apply its limits.
        // A reimport or relaunch creates a fresh source; root metadata is enough
        // to reject replacement/deletion during this actor's lifetime.
        return "\(standardizedURL.path)|\(modificationDate)|\(fileSize)|\(isDirectory)"
    }
}
