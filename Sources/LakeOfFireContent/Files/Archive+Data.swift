import Foundation
import LakeOfFireCore
import SwiftUIWebView
import UniformTypeIdentifiers
import ZIPFoundation

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

public enum ReaderPackageEntrySourceError: Error {
    case invalidSubpath
    case entryNotFound
    case unsupportedSource
}

public struct ReaderPackageEntrySource: Sendable {
    public enum Kind: Sendable {
        case directory(rootURL: URL)
        case archive(fileURL: URL)
    }

    private let kind: Kind

    public init(localURL: URL) throws {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            kind = .directory(rootURL: localURL.standardizedFileURL)
            return
        }

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw ReaderPackageEntrySourceError.unsupportedSource
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
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ReaderPackageEntrySourceError.entryNotFound
            }
            return try Data(contentsOf: fileURL)
        case .archive(let fileURL):
            guard let archive = Archive(url: fileURL, accessMode: .read),
                  let entry = archive[subpath],
                  entry.type == .file else {
                throw ReaderPackageEntrySourceError.entryNotFound
            }
            var data = Data()
            try archive.extract(entry) { data.append($0) }
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
            options: [.skipsHiddenFiles]
        )

        var entries = [ReaderPackageEntryMetadata]()
        while let fileURL = enumerator?.nextObject() as? URL {
            let relativePath = try Self.relativeSubpath(fileURL: fileURL, rootURL: standardizedRootURL)
            let subpath = try Self.sanitizeSubpath(relativePath)
            guard (try? Self.resolveDirectoryURL(rootURL: standardizedRootURL, subpath: subpath)) != nil else {
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

    private func enumerateArchiveEntries(fileURL: URL) throws -> [ReaderPackageEntryMetadata] {
        guard let archive = Archive(url: fileURL, accessMode: .read) else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }

        var seenSubpaths = Set<String>()
        return archive.compactMap { entry in
            guard entry.type == .file,
                  let subpath = try? Self.sanitizeSubpath(entry.path),
                  subpath == entry.path,
                  seenSubpaths.insert(subpath).inserted else {
                return nil
            }
            return ReaderPackageEntryMetadata(path: subpath, size: Int(entry.uncompressedSize))
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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
        guard isDirectory else {
            return "\(standardizedURL.path)|\(modificationDate)|\(fileSize)|false"
        }

        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: standardizedURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        var newestModificationDate = modificationDate
        var aggregateFileSize = fileSize
        var descendantCount = 0

        while let childURL = enumerator?.nextObject() as? URL {
            let childValues = try childURL.resourceValues(forKeys: resourceKeys)
            descendantCount += 1
            aggregateFileSize += childValues.fileSize ?? 0
            let childModificationDate = childValues.contentModificationDate?.timeIntervalSince1970 ?? 0
            newestModificationDate = max(newestModificationDate, childModificationDate)
        }

        return "\(standardizedURL.path)|\(newestModificationDate)|\(aggregateFileSize)|true|\(descendantCount)"
    }
}
