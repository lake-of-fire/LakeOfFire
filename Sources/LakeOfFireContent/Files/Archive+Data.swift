import Foundation
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
        archiveCatalog = Self.makeArchiveCatalog(from: archive)
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

    private static func knownResponseMetadata(
        forExtension fileExtension: String
    ) -> ReaderPackageEntryResponseMetadata? {
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
        let standardizedRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedURL = standardizedRootURL
            .appendingPathComponent(subpath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = standardizedRootURL.path.hasSuffix("/")
            ? standardizedRootURL.path
            : standardizedRootURL.path + "/"
        guard resolvedURL.path.hasPrefix(rootPath) else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }
        return resolvedURL
    }

    private func enumerateDirectoryEntries(rootURL: URL) throws -> [ReaderPackageEntryMetadata] {
        let standardizedRootURL = rootURL.standardizedFileURL
        let enumerator = FileManager.default.enumerator(
            at: standardizedRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var entries = [ReaderPackageEntryMetadata]()
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = try Self.relativeSubpath(fileURL: fileURL, rootURL: standardizedRootURL)
            let subpath = try Self.sanitizeSubpath(relativePath)
            _ = try Self.resolveDirectoryURL(rootURL: standardizedRootURL, subpath: subpath)
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

    private static func makeArchiveCatalog(from archive: Archive) -> ArchiveCatalog {
        var metadataByPath = [String: ReaderPackageEntryMetadata]()
        var duplicatePaths = Set<String>()
        var hasInvalidEntry = false
        for entry in archive where entry.type == .file {
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
        if hasInvalidEntry {
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

    private var cachedSources: [String: CacheRecord] = [:]

    public init() { }

    public func cachedSource(
        forPackageURL readerFileURL: URL,
        readerFileManager: ReaderFileManager
    ) async throws -> CachedSource {
        let diagnosticLocalURL = Self.diagnosticLocalFileURL(forPackageURL: readerFileURL)
        let canonicalReaderBackingURL = readerFileManager.canonicalReaderBackingURL(for: readerFileURL) ?? readerFileURL
        let cacheKey = diagnosticLocalURL.map { "diagnosticLocalFilePath:\($0.standardizedFileURL.path)" }
            ?? canonicalReaderBackingURL.absoluteString
        if let cached = freshCachedSource(forKey: cacheKey) {
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
        let freshnessToken = try Self.freshnessToken(for: localURL)

        if let cached = cachedSources[cacheKey],
           cached.localURL == localURL,
           cached.freshnessToken == freshnessToken {
            return CachedSource(source: cached.source, entries: cached.entries)
        }

        let source = try ReaderPackageEntrySource(localURL: localURL)
        let entries = try source.enumerateEntries()
        cachedSources[cacheKey] = CacheRecord(
            source: source,
            entries: entries,
            localURL: localURL,
            freshnessToken: freshnessToken
        )
        return CachedSource(source: source, entries: entries)
    }

    private func freshCachedSource(forKey cacheKey: String) -> CachedSource? {
        guard let cached = cachedSources[cacheKey],
              let freshnessToken = try? Self.freshnessToken(for: cached.localURL),
              cached.freshnessToken == freshnessToken else {
            return nil
        }
        return CachedSource(source: cached.source, entries: cached.entries)
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
            return "\(standardizedURL.path)|\(modificationDate)|\(fileSize)|false"
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
