import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    private struct DirectoryIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct ArchiveState: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64

        var fingerprint: String {
            [
                device,
                inode,
                size,
                UInt64(bitPattern: modificationSeconds),
                UInt64(bitPattern: modificationNanoseconds),
                UInt64(bitPattern: statusChangeSeconds),
                UInt64(bitPattern: statusChangeNanoseconds),
            ]
            .map(String.init)
            .joined(separator: ":")
        }
    }

    private let kind: Kind
    private let archiveCatalog: ArchiveCatalog?
    private let directoryIdentity: DirectoryIdentity?
    private let archiveState: ArchiveState?

    public init(localURL: URL) throws {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            let rootURL = try Self.canonicalDirectoryRootURL(localURL)
            kind = .directory(rootURL: rootURL)
            archiveCatalog = nil
            directoryIdentity = try Self.currentDirectoryIdentity(at: rootURL)
            archiveState = nil
            return
        }

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }

        let fileURL = localURL.standardizedFileURL
        let archiveState = try Self.currentArchiveState(at: fileURL)
        kind = .archive(fileURL: fileURL)
        directoryIdentity = nil
        self.archiveState = archiveState
        archiveCatalog = try Self.withVerifiedArchive(
            at: fileURL,
            expectedState: archiveState
        ) { archive in
            Self.makeArchiveCatalog(from: archive, fileURL: fileURL)
        }
    }

    public func enumerateEntries() throws -> [ReaderPackageEntryMetadata] {
        switch kind {
        case .directory(let rootURL):
            return try enumerateDirectoryEntries(
                rootURL: rootURL,
                expectedRootIdentity: directoryIdentity
            )
        case .archive(let fileURL):
            guard let archiveState else {
                throw ReaderPackageEntrySourceError.unsupportedSource
            }
            return try Self.withVerifiedArchive(
                at: fileURL,
                expectedState: archiveState
            ) { _ in
                try enumerateArchiveEntries()
            }
        }
    }

    public func readEntry(
        subpath rawSubpath: String,
        progress: Progress? = nil
    ) throws -> Data {
        let subpath = try Self.sanitizeSubpath(rawSubpath)
        switch kind {
        case .directory(let rootURL):
            return try Self.readDirectoryEntry(
                rootURL: rootURL,
                expectedRootIdentity: directoryIdentity,
                subpath: subpath,
                progress: progress
            )
        case .archive(let fileURL):
            guard let archiveCatalog, let archiveState else {
                throw ReaderPackageEntrySourceError.unsupportedSource
            }
            if let validationError = archiveCatalog.validationError {
                throw validationError
            }
            guard archiveCatalog.paths.contains(subpath) else {
                throw ReaderPackageEntrySourceError.entryNotFound
            }
            return try Self.withVerifiedArchive(
                at: fileURL,
                expectedState: archiveState
            ) { archive in
                guard let entry = archive[subpath], entry.type == .file else {
                    throw ReaderPackageEntrySourceError.entryNotFound
                }
                var data = Data()
                do {
                    _ = try archive.extract(entry, progress: progress) { data.append($0) }
                } catch Archive.ArchiveError.cancelledOperation {
                    throw ReaderPackageEntrySourceError.cancelled
                } catch Archive.ArchiveError.invalidCompressionMethod {
                    throw ReaderPackageEntrySourceError.unsupportedSource
                }
                return data
            }
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
        let canonicalRootURL = try canonicalDirectoryRootURL(rootURL)
        let candidateURL = canonicalRootURL.appendingPathComponent(subpath)
        let rootPath = canonicalRootURL.path.hasSuffix("/")
            ? canonicalRootURL.path
            : canonicalRootURL.path + "/"
        guard candidateURL.path.hasPrefix(rootPath) else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        var existingPrefixURL = canonicalRootURL
        for component in subpath.split(separator: "/") {
            existingPrefixURL.appendPathComponent(String(component))
            do {
                let values = try existingPrefixURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw ReaderPackageEntrySourceError.invalidSubpath
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                break
            }
        }
        return candidateURL
    }

    fileprivate static func canonicalDirectoryRootURL(_ rootURL: URL) throws -> URL {
        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = rootURL.path.withCString { path in
            realpath(path, &resolvedPath)
        }
        guard result != nil else {
            throw directoryReadError(errorNumber: errno, path: rootURL.path)
        }
        let terminatorIndex = resolvedPath.firstIndex(of: 0) ?? resolvedPath.endIndex
        let path = String(
            decoding: resolvedPath[..<terminatorIndex].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func enumerateDirectoryEntries(
        rootURL: URL,
        expectedRootIdentity: DirectoryIdentity?
    ) throws -> [ReaderPackageEntryMetadata] {
        guard let expectedRootIdentity else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }
        let rootDescriptor = try Self.openDirectoryDescriptor(at: rootURL)
        defer { close(rootDescriptor) }
        guard try Self.directoryIdentity(
            forDescriptor: rootDescriptor,
            path: rootURL.path
        ) == expectedRootIdentity else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        let standardizedRootURL = rootURL
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: standardizedRootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        var entries = [ReaderPackageEntryMetadata]()
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            if values.isSymbolicLink == true {
                enumerator?.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let relativePath = try Self.relativeSubpath(fileURL: fileURL, rootURL: standardizedRootURL)
            let subpath = try Self.sanitizeSubpath(relativePath)
            _ = try Self.resolveDirectoryURL(rootURL: standardizedRootURL, subpath: subpath)
            entries.append(ReaderPackageEntryMetadata(path: subpath, size: values.fileSize ?? 0))
        }

        let currentRootDescriptor = try Self.openDirectoryDescriptor(at: rootURL)
        defer { close(currentRootDescriptor) }
        guard try Self.directoryIdentity(
            forDescriptor: currentRootDescriptor,
            path: rootURL.path
        ) == expectedRootIdentity else {
            throw ReaderPackageEntrySourceError.invalidSubpath
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
        rootURL: URL,
        expectedRootIdentity: DirectoryIdentity?,
        subpath: String,
        progress: Progress?
    ) throws -> Data {
        if progress?.isCancelled == true {
            throw ReaderPackageEntrySourceError.cancelled
        }

        let components = subpath.split(separator: "/").map(String.init)
        guard let finalComponent = components.last else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }
        let rootDescriptor = try openDirectoryDescriptor(at: rootURL)
        defer { close(rootDescriptor) }
        guard let expectedRootIdentity,
              try directoryIdentity(forDescriptor: rootDescriptor, path: rootURL.path) == expectedRootIdentity else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        var directoryDescriptor = rootDescriptor
        var ownsDirectoryDescriptor = false
        defer {
            if ownsDirectoryDescriptor {
                close(directoryDescriptor)
            }
        }
        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                throw directoryReadError(
                    errorNumber: errno,
                    path: rootURL.appendingPathComponent(subpath).path
                )
            }
            if ownsDirectoryDescriptor {
                close(directoryDescriptor)
            }
            directoryDescriptor = nextDescriptor
            ownsDirectoryDescriptor = true
        }

        let fileDescriptor = finalComponent.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard fileDescriptor >= 0 else {
            throw directoryReadError(
                errorNumber: errno,
                path: rootURL.appendingPathComponent(subpath).path
            )
        }
        var fileInfo = stat()
        guard fstat(fileDescriptor, &fileInfo) == 0 else {
            let errorNumber = errno
            close(fileDescriptor)
            throw directoryReadError(
                errorNumber: errorNumber,
                path: rootURL.appendingPathComponent(subpath).path
            )
        }
        guard (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fileInfo.st_size >= 0 else {
            close(fileDescriptor)
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        progress?.totalUnitCount = Int64(fileInfo.st_size)
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        if fileInfo.st_size <= Int.max {
            data.reserveCapacity(Int(fileInfo.st_size))
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

    private static func openDirectoryDescriptor(at rootURL: URL) throws -> Int32 {
        let pathComponents = rootURL.pathComponents
        guard pathComponents.first == "/" else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let initialDescriptor = "/".withCString { open($0, flags) }
        guard initialDescriptor >= 0 else {
            throw directoryReadError(errorNumber: errno, path: "/")
        }

        var directoryDescriptor = initialDescriptor
        var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
        for component in pathComponents.dropFirst() where component != "/" {
            let nextDescriptor = component.withCString {
                openat(directoryDescriptor, $0, flags)
            }
            guard nextDescriptor >= 0 else {
                let errorNumber = errno
                close(directoryDescriptor)
                currentURL.appendPathComponent(component, isDirectory: true)
                throw directoryReadError(errorNumber: errorNumber, path: currentURL.path)
            }
            close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
            currentURL.appendPathComponent(component, isDirectory: true)
        }
        return directoryDescriptor
    }

    private static func currentDirectoryIdentity(at rootURL: URL) throws -> DirectoryIdentity {
        let descriptor = try openDirectoryDescriptor(at: rootURL)
        defer { close(descriptor) }
        return try directoryIdentity(forDescriptor: descriptor, path: rootURL.path)
    }

    fileprivate static func directoryIdentityFingerprint(at rootURL: URL) throws -> String {
        let identity = try currentDirectoryIdentity(at: rootURL)
        return "\(identity.device):\(identity.inode)"
    }

    fileprivate static func archiveStateFingerprint(at fileURL: URL) throws -> String {
        try currentArchiveState(at: fileURL).fingerprint
    }

    private static func currentArchiveState(at fileURL: URL) throws -> ArchiveState {
        var fileInfo = stat()
        let result = fileURL.path.withCString { stat($0, &fileInfo) }
        guard result == 0 else {
            throw directoryReadError(errorNumber: errno, path: fileURL.path)
        }
        guard (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fileInfo.st_size >= 0 else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }
#if canImport(Darwin)
        let modificationSeconds = Int64(fileInfo.st_mtimespec.tv_sec)
        let modificationNanoseconds = Int64(fileInfo.st_mtimespec.tv_nsec)
        let statusChangeSeconds = Int64(fileInfo.st_ctimespec.tv_sec)
        let statusChangeNanoseconds = Int64(fileInfo.st_ctimespec.tv_nsec)
#else
        let modificationSeconds = Int64(fileInfo.st_mtim.tv_sec)
        let modificationNanoseconds = Int64(fileInfo.st_mtim.tv_nsec)
        let statusChangeSeconds = Int64(fileInfo.st_ctim.tv_sec)
        let statusChangeNanoseconds = Int64(fileInfo.st_ctim.tv_nsec)
#endif
        return ArchiveState(
            device: UInt64(fileInfo.st_dev),
            inode: UInt64(fileInfo.st_ino),
            size: UInt64(fileInfo.st_size),
            modificationSeconds: modificationSeconds,
            modificationNanoseconds: modificationNanoseconds,
            statusChangeSeconds: statusChangeSeconds,
            statusChangeNanoseconds: statusChangeNanoseconds
        )
    }

    private static func withVerifiedArchive<Result>(
        at fileURL: URL,
        expectedState: ArchiveState,
        operation: (Archive) throws -> Result
    ) throws -> Result {
        guard try currentArchiveState(at: fileURL) == expectedState else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }
        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }
        guard try currentArchiveState(at: fileURL) == expectedState else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }
        do {
            let result = try operation(archive)
            guard try currentArchiveState(at: fileURL) == expectedState else {
                throw ReaderPackageEntrySourceError.unsupportedSource
            }
            return result
        } catch {
            if (try? currentArchiveState(at: fileURL)) != expectedState {
                throw ReaderPackageEntrySourceError.unsupportedSource
            }
            throw error
        }
    }

    private static func directoryIdentity(
        forDescriptor descriptor: Int32,
        path: String
    ) throws -> DirectoryIdentity {
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0 else {
            throw directoryReadError(errorNumber: errno, path: path)
        }
        guard (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }
        return DirectoryIdentity(
            device: UInt64(directoryInfo.st_dev),
            inode: UInt64(directoryInfo.st_ino)
        )
    }

    private static func directoryReadError(errorNumber: Int32, path: String) -> Error {
        switch errorNumber {
        case ENOENT:
            return ReaderPackageEntrySourceError.entryNotFound
        case ELOOP, ENOTDIR:
            return ReaderPackageEntrySourceError.invalidSubpath
        default:
            return NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorNumber),
                userInfo: [NSFilePathErrorKey: path]
            )
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
                try ReaderPackageEntrySource.archiveStateFingerprint(at: standardizedURL),
                "false",
            ].joined(separator: "|")
        }

        let canonicalRootURL = try ReaderPackageEntrySource.canonicalDirectoryRootURL(standardizedURL)
        let initialIdentity = try ReaderPackageEntrySource.directoryIdentityFingerprint(at: canonicalRootURL)
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: canonicalRootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        var descendantMetadata = [String]()

        while let childURL = enumerator?.nextObject() as? URL {
            let childValues = try childURL.resourceValues(forKeys: resourceKeys)
            if childValues.isSymbolicLink == true {
                enumerator?.skipDescendants()
                continue
            }
            let childModificationDate = childValues.contentModificationDate?.timeIntervalSince1970 ?? 0
            let relativePath = try ReaderPackageEntrySource.relativeSubpath(
                fileURL: childURL,
                rootURL: canonicalRootURL
            )
            descendantMetadata.append([
                relativePath,
                String(childModificationDate.bitPattern),
                String(childValues.fileSize ?? 0),
                childValues.isDirectory == true ? "directory" : "file",
            ].joined(separator: "\u{0}"))
        }

        let finalIdentity = try ReaderPackageEntrySource.directoryIdentityFingerprint(at: canonicalRootURL)
        guard finalIdentity == initialIdentity else {
            throw ReaderPackageEntrySourceError.invalidSubpath
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
            canonicalRootURL.path,
            initialIdentity,
            String(modificationDate.bitPattern),
            String(fileSize),
            "true",
            metadataDigest,
        ].joined(separator: "|")
    }
}
