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
        let extensionValue = (subpath as NSString).pathExtension
        let type = extensionValue.isEmpty ? nil : UTType(filenameExtension: extensionValue)
        let mimeType = type?.preferredMIMEType ?? Self.fallbackMimeType(forExtension: extensionValue)
        let textEncodingName = Self.isUTF8TextType(utType: type, mimeType: mimeType) ? "utf-8" : nil
        return ReaderPackageEntryResponseMetadata(mimeType: mimeType, textEncodingName: textEncodingName)
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
        let standardizedRootURL = rootURL.standardizedFileURL
        let resolvedURL = standardizedRootURL.appendingPathComponent(subpath).standardizedFileURL
        let rootPath = standardizedRootURL.path.hasSuffix("/") ? standardizedRootURL.path : standardizedRootURL.path + "/"
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
            let relativePath = fileURL.path.replacingOccurrences(of: standardizedRootURL.path + "/", with: "")
            let subpath = try Self.sanitizeSubpath(relativePath)
            entries.append(ReaderPackageEntryMetadata(path: subpath, size: values.fileSize ?? 0))
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func enumerateArchiveEntries(fileURL: URL) throws -> [ReaderPackageEntryMetadata] {
        guard let archive = Archive(url: fileURL, accessMode: .read) else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }

        return archive.compactMap { entry in
            guard entry.type == .file else { return nil }
            return ReaderPackageEntryMetadata(path: entry.path, size: Int(entry.uncompressedSize))
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func fallbackMimeType(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "xhtml", "html", "htm":
            return "application/xhtml+xml"
        case "opf":
            return "application/oebps-package+xml"
        case "ncx":
            return "application/x-dtbncx+xml"
        case "xml":
            return "application/xml"
        case "svg":
            return "image/svg+xml"
        case "css":
            return "text/css"
        case "js", "mjs":
            return "text/javascript"
        case "json":
            return "application/json"
        case "txt":
            return "text/plain"
        default:
            return "application/octet-stream"
        }
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
    private static let diagnosticLocalFilePathQueryItemName = "diagnosticLocalFilePath"

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
        let cacheKey = readerFileURL.absoluteString
        let localURL = try await Self.resolvedLocalURL(forPackageURL: readerFileURL, readerFileManager: readerFileManager)
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

    private static func resolvedLocalURL(
        forPackageURL readerFileURL: URL,
        readerFileManager: ReaderFileManager
    ) async throws -> URL {
        if let diagnosticLocalURL = diagnosticLocalURL(forPackageURL: readerFileURL) {
            return diagnosticLocalURL
        }
        if try await readerFileManager.directoryExists(directoryURL: readerFileURL) {
            return try readerFileManager.localDirectoryURL(forReaderFileURL: readerFileURL)
        }
        return try readerFileManager.localFileURL(forReaderFileURL: readerFileURL)
    }

    private static func diagnosticLocalURL(forPackageURL readerFileURL: URL) -> URL? {
        guard let components = URLComponents(url: readerFileURL, resolvingAgainstBaseURL: false),
              let encodedPath = components.queryItems?.first(where: { $0.name == diagnosticLocalFilePathQueryItemName })?.value,
              !encodedPath.isEmpty
        else {
            return nil
        }

        let localURL = URL(fileURLWithPath: encodedPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            return nil
        }
        return localURL
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
