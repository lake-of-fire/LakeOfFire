import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    private static let urlInputEdgeWhitespace = CharacterSet(
        charactersIn: "\t\n\u{000C}\r "
    )

    private static let decodeURIReservedBytes: Set<UInt8> = [
        0x23, // #
        0x24, // $
        0x26, // &
        0x2B, // +
        0x2C, // ,
        0x2F, // /
        0x3A, // :
        0x3B, // ;
        0x3D, // =
        0x3F, // ?
        0x40, // @
    ]

    private let kind: Kind
    private let directoryIdentity: DirectoryIdentity?
    private let archiveState: ArchiveState?

    public init(localURL: URL) throws {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            let rootURL = Self.canonicalDirectoryRootURL(localURL)
            kind = .directory(rootURL: rootURL)
            directoryIdentity = try Self.currentDirectoryIdentity(at: rootURL)
            archiveState = nil
            return
        }

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw ReaderPackageEntrySourceError.unsupportedSource
        }

        let archiveURL = localURL.standardizedFileURL
        let archiveState = try Self.currentArchiveState(at: archiveURL)
        kind = .archive(fileURL: archiveURL)
        directoryIdentity = nil
        self.archiveState = archiveState
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
            ) { archive in
                var seenSubpaths = Set<String>()
                return archive.compactMap { entry in
                    guard entry.type == .file,
                          let subpath = try? Self.sanitizeSubpath(entry.path),
                          subpath == entry.path,
                          seenSubpaths.insert(subpath).inserted else {
                        return nil
                    }
                    return ReaderPackageEntryMetadata(
                        path: subpath,
                        size: Int(entry.uncompressedSize)
                    )
                }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }
        }
    }

    public func readEntry(subpath rawSubpath: String) throws -> Data {
        let subpath = try Self.sanitizeSubpath(rawSubpath)
        switch kind {
        case .directory(let rootURL):
            return try Self.readDirectoryEntry(
                rootURL: rootURL,
                expectedRootIdentity: directoryIdentity,
                subpath: subpath
            )
        case .archive(let fileURL):
            guard let archiveState else {
                throw ReaderPackageEntrySourceError.unsupportedSource
            }
            return try Self.withVerifiedArchive(
                at: fileURL,
                expectedState: archiveState
            ) { archive in
                guard let entry = archive[subpath], entry.type == .file else {
                    throw ReaderPackageEntrySourceError.entryNotFound
                }
                var data = Data()
                try archive.extract(entry) { data.append($0) }
                return data
            }
        }
    }

    public func mimeType(subpath rawSubpath: String) throws -> ReaderPackageEntryResponseMetadata {
        let subpath = try Self.sanitizeSubpath(rawSubpath)
        var fileExtension = (subpath as NSString).pathExtension
        // OCF package paths preserve Unicode whitespace exactly. Trailing
        // whitespace belongs to the entry name, but it must not hide an otherwise
        // recognizable media type from the custom-scheme response. Keep path
        // identity untouched and normalize only the extension used for MIME
        // inference.
        while fileExtension.last?.isWhitespace == true {
            fileExtension.removeLast()
        }
        fileExtension = fileExtension.lowercased()
        if let metadata = Self.knownResponseMetadata(forExtension: fileExtension) {
            return metadata
        }
        let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        let textEncodingName = Self.isTextType(utType: type, mimeType: mimeType) ? "utf-8" : nil
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
        let detectedEncoding = detectedTextEncoding(in: data)
        if let decoded = String(data: data, encoding: detectedEncoding.foundationEncoding) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Resolves a package href using the same one-pass `decodeURI` semantics as
    /// the renderer. Reserved delimiter escapes remain literal package-name
    /// characters while ordinary escapes and dot segments are normalized.
    public static func resolveSubpath(
        _ href: String,
        relativeTo baseDirectory: String
    ) -> String? {
        // WHATWG URL parsing ignores surrounding ASCII URL whitespace. Keep
        // that normalization separate from percent decoding so encoded spaces
        // and non-ASCII whitespace remain exact package-name characters.
        let normalizedHref = href.trimmingCharacters(
            in: urlInputEdgeWhitespace
        )
        guard !hasURIScheme(normalizedHref) else { return nil }
        let hrefWithoutFragment = normalizedHref.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? normalizedHref
        let hrefWithoutQuery = hrefWithoutFragment.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? hrefWithoutFragment
        guard let decodedHref = decodePackageURI(hrefWithoutQuery) else {
            return nil
        }
        let hrefComponents = decodedHref.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !decodedHref.isEmpty,
              !decodedHref.hasPrefix("/"),
              !decodedHref.contains("\\"),
              !decodedHref.contains("\0"),
              !hrefComponents.contains(where: \.isEmpty) else {
            return nil
        }

        let combined = baseDirectory.isEmpty
            ? decodedHref
            : (baseDirectory as NSString).appendingPathComponent(decodedHref)
        var components: [String] = []
        for component in combined.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init) {
            guard !component.isEmpty, component != "." else { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        let normalized = components.joined(separator: "/")
        guard !normalized.isEmpty,
              (try? sanitizeSubpath(normalized)) != nil else {
            return nil
        }
        return normalized
    }

    private static func hasURIScheme(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard let first = scalars.first,
              (65...90).contains(first.value) || (97...122).contains(first.value) else {
            return false
        }
        for scalar in scalars.dropFirst() {
            switch scalar.value {
            case 58: // :
                return true
            case 43, 45, 46, 48...57, 65...90, 97...122: // + - . 0-9 A-Z a-z
                continue
            default:
                return false
            }
        }
        return false
    }

    private static func decodePackageURI(_ value: String) -> String? {
        let scalars = Array(value.unicodeScalars)
        var protectedValue = ""
        protectedValue.reserveCapacity(value.utf8.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "%",
                  index + 2 < scalars.count,
                  let high = hexadecimalValue(of: scalars[index + 1]),
                  let low = hexadecimalValue(of: scalars[index + 2]) else {
                protectedValue.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            if decodeURIReservedBytes.contains((high << 4) | low) {
                protectedValue.append("%25")
            } else {
                protectedValue.append("%")
            }
            protectedValue.unicodeScalars.append(scalars[index + 1])
            protectedValue.unicodeScalars.append(scalars[index + 2])
            index += 3
        }
        return protectedValue.removingPercentEncoding
    }

    private static func hexadecimalValue(of scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 48...57:
            UInt8(scalar.value - 48)
        case 65...70:
            UInt8(scalar.value - 65 + 10)
        case 97...102:
            UInt8(scalar.value - 97 + 10)
        default:
            nil
        }
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
                return DetectedTextEncoding(ianaName: "utf-16le", foundationEncoding: .utf16LittleEndian)
            }
            if prefix[0] == 0x00,
               prefix[2] == 0x00,
               prefix[1] != 0x00 || prefix[3] != 0x00 {
                return DetectedTextEncoding(ianaName: "utf-16be", foundationEncoding: .utf16BigEndian)
            }
        }
        return DetectedTextEncoding(ianaName: "utf-8", foundationEncoding: .utf8)
    }

    public static func sanitizeSubpath(_ rawSubpath: String) throws -> String {
        // Package paths are scalar-value strings. Preserve spaces and literal
        // percent sequences exactly while rejecting traversal and POSIX hazards.
        guard !rawSubpath.isEmpty,
              !rawSubpath.hasPrefix("/"),
              !rawSubpath.contains("\\"),
              !rawSubpath.contains("\0") else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        let components = rawSubpath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        return rawSubpath
    }

    /// Reads one directory-backed package entry without reopening a validated
    /// pathname. Every component is resolved relative to an already-open directory
    /// descriptor with `O_NOFOLLOW`, so a concurrent rename/symlink swap cannot
    /// escape the package root between validation and the actual read. The final
    /// descriptor must also be a regular file; `O_NONBLOCK` prevents a malicious
    /// FIFO or device node from stalling the reader before that check completes.
    private static func readDirectoryEntry(
        rootURL: URL,
        expectedRootIdentity: DirectoryIdentity?,
        subpath: String
    ) throws -> Data {
        let components = subpath.split(separator: "/").map(String.init)
        guard let finalComponent = components.last else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        let rootDescriptor = try openDirectoryDescriptor(at: rootURL)
        defer { close(rootDescriptor) }
        guard let expectedRootIdentity,
              try directoryIdentity(
                forDescriptor: rootDescriptor,
                path: rootURL.path
              ) == expectedRootIdentity else {
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
                let errorNumber = errno
                throw directoryReadError(
                    errorNumber: errorNumber,
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
            let errorNumber = errno
            throw directoryReadError(
                errorNumber: errorNumber,
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
        guard (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(fileDescriptor)
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        let fileHandle = FileHandle(
            fileDescriptor: fileDescriptor,
            closeOnDealloc: true
        )
        defer { try? fileHandle.close() }
        return try fileHandle.readToEnd() ?? Data()
    }

    /// Opens the canonical package root without allowing any pathname component to
    /// become a symlink after source construction. `O_NOFOLLOW` on a single absolute
    /// `open()` protects only the final component; an attacker could otherwise replace
    /// a writable ancestor with a symlink and redirect the entire package root before
    /// the read begins. Walking from `/` keeps the same no-follow contract for every
    /// package-root component as well as every descendant component opened above.
    private static func openDirectoryDescriptor(at rootURL: URL) throws -> Int32 {
        let standardizedRootURL = rootURL.standardizedFileURL
        let pathComponents = standardizedRootURL.pathComponents
        guard pathComponents.first == "/" else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let initialDescriptor = "/".withCString {
            open($0, flags)
        }
        guard initialDescriptor >= 0 else {
            let errorNumber = errno
            throw directoryReadError(errorNumber: errorNumber, path: "/")
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
                throw directoryReadError(
                    errorNumber: errorNumber,
                    path: currentURL.path
                )
            }
            close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
            currentURL.appendPathComponent(component, isDirectory: true)
        }
        return directoryDescriptor
    }

    private static func currentDirectoryIdentity(at rootURL: URL) throws -> DirectoryIdentity {
        let rootDescriptor = try openDirectoryDescriptor(at: rootURL)
        defer { close(rootDescriptor) }
        return try directoryIdentity(
            forDescriptor: rootDescriptor,
            path: rootURL.path
        )
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
        let result = fileURL.path.withCString { path in
            stat(path, &fileInfo)
        }
        guard result == 0 else {
            let errorNumber = errno
            throw directoryReadError(errorNumber: errorNumber, path: fileURL.path)
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
        guard try currentArchiveState(at: fileURL) == expectedState,
              let archive = Archive(url: fileURL, accessMode: .read),
              try currentArchiveState(at: fileURL) == expectedState else {
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
            let errorNumber = errno
            throw directoryReadError(errorNumber: errorNumber, path: path)
        }
        guard (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }
        return DirectoryIdentity(
            device: UInt64(directoryInfo.st_dev),
            inode: UInt64(directoryInfo.st_ino)
        )
    }

    private static func directoryReadError(
        errorNumber: Int32,
        path: String
    ) -> Error {
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

    public static func resolveDirectoryURL(rootURL: URL, subpath rawSubpath: String) throws -> URL {
        let subpath = try sanitizeSubpath(rawSubpath)
        let canonicalRootURL = canonicalDirectoryRootURL(rootURL)
        let candidateURL = canonicalRootURL.appendingPathComponent(subpath).standardizedFileURL
        let rootPath = directoryDescendantPrefix(for: canonicalRootURL)
        guard candidateURL.path.hasPrefix(rootPath) else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        // Resolve the package root once, but reject every symlink below it so a
        // directory-backed EPUB cannot expose files outside its package boundary.
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

    fileprivate static func canonicalDirectoryRootURL(_ rootURL: URL) -> URL {
        rootURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func directoryDescendantPrefix(for rootURL: URL) -> String {
        rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
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

        let canonicalRootURL = rootURL.standardizedFileURL
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: canonicalRootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )

        var entries = [ReaderPackageEntryMetadata]()
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            if values.isSymbolicLink == true {
                enumerator?.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let relativePath = try Self.relativeSubpath(fileURL: fileURL, rootURL: canonicalRootURL)
            let subpath = try Self.sanitizeSubpath(relativePath)
            _ = try Self.resolveDirectoryURL(rootURL: canonicalRootURL, subpath: subpath)
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

    private static func isTextType(utType: UTType?, mimeType: String) -> Bool {
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
    private static let defaultMaximumSourceCount = 8
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

    private let maximumSourceCount: Int
    private var cachedSources: [String: CacheRecord] = [:]
    private var sourceKeysInAccessOrder = [String]()

    public init(countLimit: Int = 8) {
        maximumSourceCount = max(countLimit, 1)
    }

#if DEBUG
    init(maximumSourceCount: Int) {
        self.maximumSourceCount = max(maximumSourceCount, 1)
    }

    var cachedSourceCount: Int {
        cachedSources.count
    }
#endif

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
            localURL = try await readerFileManager.resolveReadableLocalURL(
                forReaderBackingURL: canonicalReaderBackingURL
            )
        }
        try Task.checkCancellation()
        let freshnessToken = try Self.freshnessToken(for: localURL)
        try Task.checkCancellation()

        if let cached = cachedSources[cacheKey],
           cached.localURL == localURL,
           cached.freshnessToken == freshnessToken {
            try Task.checkCancellation()
            touchCachedSource(forKey: cacheKey)
            return CachedSource(source: cached.source, entries: cached.entries)
        }

        let source = try ReaderPackageEntrySource(localURL: localURL)
        let entries = try source.enumerateEntries()
        try Task.checkCancellation()
        storeCachedSource(
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
        touchCachedSource(forKey: cacheKey)
        return CachedSource(source: cached.source, entries: cached.entries)
    }

    private func storeCachedSource(_ source: CacheRecord, forKey cacheKey: String) {
        cachedSources[cacheKey] = source
        touchCachedSource(forKey: cacheKey)
        while cachedSources.count > maximumSourceCount,
              let leastRecentlyUsedKey = sourceKeysInAccessOrder.first {
            removeCachedSource(forKey: leastRecentlyUsedKey)
        }
    }

    private func touchCachedSource(forKey cacheKey: String) {
        sourceKeysInAccessOrder.removeAll { $0 == cacheKey }
        sourceKeysInAccessOrder.append(cacheKey)
    }

    private func removeCachedSource(forKey cacheKey: String) {
        cachedSources.removeValue(forKey: cacheKey)
        sourceKeysInAccessOrder.removeAll { $0 == cacheKey }
    }

#if DEBUG
    func cachedSourceCountForTesting() -> Int {
        cachedSources.count
    }

    func cachedSourcePathsInLRUOrderForTesting() -> [String] {
        sourceKeysInAccessOrder.compactMap { cachedSources[$0]?.localURL.standardizedFileURL.path }
    }
#endif

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
        let standardizedURL: URL
        let isDirectory: Bool
        var directoryFlag = ObjCBool(false)
        if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &directoryFlag),
           directoryFlag.boolValue {
            standardizedURL = ReaderPackageEntrySource.canonicalDirectoryRootURL(localURL)
            isDirectory = true
        } else {
            standardizedURL = localURL.standardizedFileURL
            isDirectory = false
        }

        if !isDirectory {
            let archiveState = try ReaderPackageEntrySource.archiveStateFingerprint(
                at: standardizedURL
            )
            return "\(standardizedURL.path)|\(archiveState)|false"
        }

        let initialRootIdentity = try ReaderPackageEntrySource.directoryIdentityFingerprint(
            at: standardizedURL
        )
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: standardizedURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )

        var entryMetadata = [(path: String, modificationDate: TimeInterval, fileSize: Int)]()
        while let childURL = enumerator?.nextObject() as? URL {
            let childValues = try childURL.resourceValues(forKeys: resourceKeys)
            if childValues.isSymbolicLink == true {
                enumerator?.skipDescendants()
                continue
            }
            guard childValues.isRegularFile == true else { continue }
            let relativePath = try ReaderPackageEntrySource.relativeSubpath(
                fileURL: childURL,
                rootURL: standardizedURL
            )
            let subpath = try ReaderPackageEntrySource.sanitizeSubpath(relativePath)
            entryMetadata.append((
                path: subpath,
                modificationDate: childValues.contentModificationDate?.timeIntervalSince1970 ?? 0,
                fileSize: childValues.fileSize ?? 0
            ))
        }

        let finalRootIdentity = try ReaderPackageEntrySource.directoryIdentityFingerprint(
            at: standardizedURL
        )
        guard finalRootIdentity == initialRootIdentity else {
            throw ReaderPackageEntrySourceError.invalidSubpath
        }

        entryMetadata.sort { lhs, rhs in
            lhs.path < rhs.path
        }
        var metadataHasher = Hasher()
        for entry in entryMetadata {
            metadataHasher.combine(entry.path)
            metadataHasher.combine(entry.modificationDate.bitPattern)
            metadataHasher.combine(entry.fileSize)
        }

        return "\(standardizedURL.path)|\(initialRootIdentity)|\(metadataHasher.finalize())|true|\(entryMetadata.count)"
    }
}
