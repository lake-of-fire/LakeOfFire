import Foundation
import CryptoKit

/// Transient import comparison only; this is NOT the EPUB fingerprint or a
/// persisted reading-state identity. Derived from the hotfix package manifest.
enum ReaderFileImportPackageManifest {
    enum ManifestError: Error {
        case invalidRoot
        case escapedEntry
        case unsupportedEntry
        case changedEntry
    }

    static func digest(at url: URL) throws -> Data {
        try Task.checkCancellation()
        let manager = FileManager.default
        let root = url.standardizedFileURL
        let attributes = try manager.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ManifestError.invalidRoot
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var hash = SHA256()
        try append(at: root, relativePath: "", resolvedRoot: resolvedRoot, manager: manager, hash: &hash)
        try Task.checkCancellation()
        return Data(hash.finalize())
    }

    private static func append(
        at directory: URL, relativePath: String, resolvedRoot: URL,
        manager: FileManager, hash: inout SHA256
    ) throws {
        try Task.checkCancellation()
        let children = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        ).sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        for child in children {
            try Task.checkCancellation()
            let path = relativePath.isEmpty ? child.lastPathComponent : relativePath + "/" + child.lastPathComponent
            if let target = try? manager.destinationOfSymbolicLink(atPath: child.path) {
                let bytes = Data(target.utf8)
                record(path: path, type: "symlink", size: bytes.count, hash: &hash)
                hash.update(data: bytes)
                hash.update(data: Data([0]))
                continue
            }
            let resolved = child.resolvingSymlinksInPath().standardizedFileURL
            let rootParts = resolvedRoot.pathComponents
            let parts = resolved.pathComponents
            guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else {
                throw ManifestError.escapedEntry
            }
            let attributes = try manager.attributesOfItem(atPath: child.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                record(path: path, type: "directory", size: 0, hash: &hash)
                try append(at: child, relativePath: path, resolvedRoot: resolvedRoot, manager: manager, hash: &hash)
            case .typeRegular:
                guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else {
                    throw ManifestError.changedEntry
                }
                record(path: path, type: "file", size: size.int64Value, hash: &hash)
                let handle = try FileHandle(forReadingFrom: resolved)
                defer { try? handle.close() }
                var remaining = size.uint64Value
                while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
                    try Task.checkCancellation()
                    guard UInt64(bytes.count) <= remaining else { throw ManifestError.changedEntry }
                    remaining -= UInt64(bytes.count)
                    hash.update(data: bytes)
                }
                guard remaining == 0 else { throw ManifestError.changedEntry }
                hash.update(data: Data([0]))
            default:
                // Unlike the old concatenation and hotfix's skip path, an
                // unreadable/unsupported item must not produce an equal manifest.
                throw ManifestError.unsupportedEntry
            }
        }
    }

    private static func record<T: BinaryInteger>(path: String, type: String, size: T, hash: inout SHA256) {
        for field in ["entry", path, type, String(size)] {
            hash.update(data: Data(field.utf8))
            hash.update(data: Data([0]))
        }
    }
}
