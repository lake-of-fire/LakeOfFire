import CryptoKit
import Foundation
import ZIPFoundation

/// Strict identity scans have their own resource budget. They never inherit a
/// metadata-only read limit or silently skip entries the viewer cannot use.
public struct ReaderEBookFingerprintLimits: Sendable {
    public let maxEntryCount: Int
    public let maxEntryBytes: Int64
    public let maxAggregateUncompressedBytes: Int64
    public init(maxEntryCount: Int = 65_534, maxEntryBytes: Int64 = 128 * 1024 * 1024,
                maxAggregateUncompressedBytes: Int64 = 8 * 1024 * 1024 * 1024) {
        self.maxEntryCount = max(0, maxEntryCount)
        self.maxEntryBytes = max(0, maxEntryBytes)
        self.maxAggregateUncompressedBytes = max(0, maxAggregateUncompressedBytes)
    }
    public static let `default` = Self()
}

public enum ReaderEBookFingerprintError: Error, Equatable {
    case invalidPackage
    case ambiguousPath(String)
    case unsupportedEntry(String)
    case limitExceeded
    case sizeChanged(String)
    case checksumMismatch(String)
}

/// Exact-copy recognition, not an identity that follows arbitrary edits.
///
/// The caller must supply an immutable/coordinated local snapshot and the OPF
/// path selected by the same parser as the viewer. This function does not
/// download iCloud files or claim that a changing live file was snapshotted.
/// Enrollment must revalidate the caller's file-version observation at commit.
public struct ReaderEBookPackageFingerprint: Equatable, Sendable {
    public struct Resource: Equatable, Sendable {
        public let path: String
        public let byteCount: UInt64
        public let sha256: String
    }
    public let packageSHA256: String
    public let packageDocumentPath: String
    public let resources: [Resource]

    public static func readSnapshot(
        at url: URL, packageDocumentPath: String,
        limits: ReaderEBookFingerprintLimits = .default
    ) throws -> Self {
        try Task.checkCancellation()
        try validatePath(packageDocumentPath)
        guard url.isFileURL else { throw ReaderEBookFingerprintError.invalidPackage }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ReaderEBookFingerprintError.unsupportedEntry("<root>") }
        guard values.isDirectory == true || values.isRegularFile == true else { throw ReaderEBookFingerprintError.invalidPackage }
        let entries = values.isDirectory == true
            ? try readDirectory(url, limits: limits)
            : try readArchive(url, limits: limits)
        let paths = Set(entries.map(\.path))
        guard paths.contains("META-INF/container.xml"),
              entries.contains(where: { $0.path.utf8.elementsEqual(packageDocumentPath.utf8) }),
              let mime = entries.first(where: { $0.path == "mimetype" }),
              mime.byteCount == 20, mime.sha256 == hex(SHA256.hash(data: Data("application/epub+zip".utf8))) else {
            throw ReaderEBookFingerprintError.invalidPackage
        }
        let sorted = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        var hash = SHA256()
        appendField(Data("manabi-epub-package-v1".utf8), to: &hash)
        appendInteger(UInt64(sorted.count), to: &hash)
        for entry in sorted {
            appendField(Data(entry.path.utf8), to: &hash)
            appendInteger(entry.byteCount, to: &hash)
            // ASCII lowercase hex is intentionally part of this frozen format.
            appendField(Data(entry.sha256.utf8), to: &hash)
        }
        try Task.checkCancellation()
        return Self(packageSHA256: hex(hash.finalize()), packageDocumentPath: packageDocumentPath, resources: sorted)
    }

    private struct Budget {
        let limits: ReaderEBookFingerprintLimits
        var entryCount = 0
        var byteCount: UInt64 = 0
        var pathBytes = 0
        // String equality intentionally rejects canonically equivalent names
        // inside one package: the viewer's ZIP lookup cannot disambiguate them.
        // Otherwise the fingerprint continues to hash the original UTF-8 bytes.
        var paths = [String: Bool]() // true is a directory

        mutating func countEntry() throws {
            try Task.checkCancellation()
            guard entryCount < limits.maxEntryCount else { throw ReaderEBookFingerprintError.limitExceeded }
            entryCount += 1
        }
        mutating func add(path: String, size: UInt64, isDirectory: Bool = false) throws {
            try validatePath(path)
            guard paths[path] == nil else { throw ReaderEBookFingerprintError.ambiguousPath(path) }
            guard pathBytes <= 16 * 1024 * 1024 - path.utf8.count,
                  size <= UInt64(limits.maxEntryBytes),
                  size <= UInt64(limits.maxAggregateUncompressedBytes) - byteCount else {
                throw ReaderEBookFingerprintError.limitExceeded
            }
            paths[path] = isDirectory
            pathBytes += path.utf8.count
            byteCount += size
        }
        func validateNamespace() throws {
            if let conflict = try ReaderEBookPackageNamespace.conflictingPath(
                in: paths.map { (path: $0.key, isDirectory: $0.value) }
            ) {
                throw ReaderEBookFingerprintError.ambiguousPath(conflict)
            }
        }
    }

    private static func readArchive(_ url: URL, limits: ReaderEBookFingerprintLimits) throws -> [Resource] {
        let expectedCount = try ReaderEBookZIPDirectory.validate(url, maximumEntryCount: limits.maxEntryCount)
        let archive = try Archive(url: url, accessMode: .read)
        var budget = Budget(limits: limits)
        var resources = [Resource]()
        for entry in archive {
            try budget.countEntry()
            if entry.type == .directory {
                guard entry.uncompressedSize == 0, entry.compressedSize == 0 else {
                    throw ReaderEBookFingerprintError.unsupportedEntry(entry.path)
                }
                let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
                try budget.add(path: path, size: 0, isDirectory: true)
                continue
            }
            guard entry.type == .file else { throw ReaderEBookFingerprintError.unsupportedEntry(entry.path) }
            try budget.add(path: entry.path, size: entry.uncompressedSize)
            var actual: UInt64 = 0
            var digest = SHA256()
            let checksum = try archive.extract(entry, bufferSize: 65_536, skipCRC32: false) { chunk in
                try Task.checkCancellation()
                guard UInt64(chunk.count) <= entry.uncompressedSize - actual,
                      UInt64(chunk.count) <= UInt64(limits.maxEntryBytes) - actual else {
                    throw ReaderEBookFingerprintError.sizeChanged(entry.path)
                }
                actual += UInt64(chunk.count)
                digest.update(data: chunk)
            }
            guard actual == entry.uncompressedSize else { throw ReaderEBookFingerprintError.sizeChanged(entry.path) }
            guard checksum == entry.checksum else { throw ReaderEBookFingerprintError.checksumMismatch(entry.path) }
            resources.append(Resource(path: entry.path, byteCount: actual, sha256: hex(digest.finalize())))
        }
        guard budget.entryCount == expectedCount else { throw ReaderEBookFingerprintError.invalidPackage }
        try budget.validateNamespace()
        return resources
    }

    private static func readDirectory(_ root: URL, limits: ReaderEBookFingerprintLimits) throws -> [Resource] {
        var error: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [], errorHandler: { _, failure in error = failure; return false }) else {
            throw ReaderEBookFingerprintError.invalidPackage
        }
        let rootComponents = root.standardizedFileURL.pathComponents
        var budget = Budget(limits: limits)
        var resources = [Resource]()
        while let url = enumerator.nextObject() as? URL {
            try budget.countEntry()
            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else {
                throw ReaderEBookFingerprintError.invalidPackage
            }
            let path = components.dropFirst(rootComponents.count).joined(separator: "/")
            try validatePath(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw ReaderEBookFingerprintError.unsupportedEntry(path) }
            if values.isDirectory == true {
                try budget.add(path: path, size: 0, isDirectory: true)
                continue
            }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw ReaderEBookFingerprintError.unsupportedEntry(path)
            }
            try budget.add(path: path, size: UInt64(size))
            let input = try FileHandle(forReadingFrom: url)
            let digest = try hashFile(input, path: path, expectedSize: UInt64(size))
            resources.append(Resource(path: path, byteCount: UInt64(size), sha256: digest))
        }
        if let error { throw error }
        try budget.validateNamespace()
        return resources
    }

    private static func hashFile(_ input: FileHandle, path: String, expectedSize: UInt64) throws -> String {
        defer { try? input.close() }
        var digest = SHA256()
        var actual: UInt64 = 0
        while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            guard UInt64(chunk.count) <= expectedSize - actual else { throw ReaderEBookFingerprintError.sizeChanged(path) }
            actual += UInt64(chunk.count)
            digest.update(data: chunk)
        }
        guard actual == expectedSize else { throw ReaderEBookFingerprintError.sizeChanged(path) }
        return hex(digest.finalize())
    }
    static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 16_384, !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ReaderEBookFingerprintError.ambiguousPath(path)
        }
    }
    private static func appendInteger(_ number: UInt64, to hash: inout SHA256) {
        var value = number.bigEndian
        withUnsafeBytes(of: &value) { hash.update(data: Data($0)) }
    }
    private static func appendField(_ data: Data, to hash: inout SHA256) {
        appendInteger(UInt64(data.count), to: &hash)
        hash.update(data: data)
    }
    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
