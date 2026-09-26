import Foundation
import ZIPFoundation

/// Foundation's directory snapshot ZIP contains an outer directory named after
/// the source. Remove only that known envelope, never a directory guessed from
/// an arbitrary imported EPUB. The resulting private archive is what both the
/// fingerprint scanner and the viewer read; their resource paths stay identical.
enum ReaderEBookDirectorySnapshotArchive {
    static func retainContents(of snapshot: ReaderEBookPackageSnapshot,
                               rootName: String, maximumBytes: Int64) throws -> ReaderEBookPackageSnapshot {
        try snapshot.validateObservation(snapshot.observationToken)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-epub-envelope-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let destination = workspace.appendingPathComponent("package.epub")
        try rewrite(snapshot.packageURL, rootName: rootName, to: destination,
                    spoolURL: workspace.appendingPathComponent("resource"), maximumBytes: maximumBytes)
        try snapshot.validateObservation(snapshot.observationToken)
        return try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: destination, maximumBytes: maximumBytes)
    }

    private static func rewrite(_ url: URL, rootName: String, to destination: URL,
                                spoolURL: URL, maximumBytes: Int64) throws {
        guard maximumBytes >= 0, !rootName.isEmpty, !rootName.contains("/"),
              !rootName.contains("\\"), rootName != ".", rootName != ".." else {
            throw ReaderEBookPackageSnapshotError.invalidSource
        }
        let expected = try ReaderEBookZIPDirectory.validate(url, maximumEntryCount: 65_534)
        let input = try Archive(url: url, accessMode: .read)
        let entries = Array(input)
        guard entries.count == expected else { throw ReaderEBookFingerprintError.invalidPackage }
        let prefix = Array((rootName + "/").utf8)
        var selected = [(Entry, String)]()
        var names = [(path: String, isDirectory: Bool)]()
        var total: UInt64 = 0
        var pathBytes = 0
        for entry in entries {
            try Task.checkCancellation()
            let bytes = Array(entry.path.utf8)
            guard bytes.starts(with: prefix) else {
                throw ReaderEBookFingerprintError.ambiguousPath(entry.path)
            }
            let relativeBytes = bytes.dropFirst(prefix.count)
            if relativeBytes.isEmpty {
                guard entry.type == .directory, entry.uncompressedSize == 0 else {
                    throw ReaderEBookFingerprintError.invalidPackage
                }
                continue
            }
            var path = String(decoding: relativeBytes, as: UTF8.self)
            let isDirectory = entry.type == .directory
            if isDirectory, path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty, path.utf8.count <= 16_384,
                  !path.contains("\\"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  path == path.trimmingCharacters(in: .whitespacesAndNewlines),
                  path.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  entry.type == .file || isDirectory else {
                throw ReaderEBookFingerprintError.unsupportedEntry(entry.path)
            }
            guard pathBytes <= 16 * 1024 * 1024 - path.utf8.count,
                  entry.uncompressedSize <= 128 * 1024 * 1024,
                  entry.uncompressedSize <= UInt64(maximumBytes) - total else {
                throw ReaderEBookFingerprintError.limitExceeded
            }
            pathBytes += path.utf8.count
            total += entry.uncompressedSize
            names.append((path, isDirectory))
            if isDirectory {
                guard entry.uncompressedSize == 0 else { throw ReaderEBookFingerprintError.invalidPackage }
            } else {
                selected.append((entry, path))
            }
        }
        if let conflict = try ReaderEBookPackageNamespace.conflictingPath(in: names) {
            throw ReaderEBookFingerprintError.ambiguousPath(conflict)
        }
        guard !selected.isEmpty else { throw ReaderEBookFingerprintError.invalidPackage }
        let output = try Archive(url: destination, accessMode: .create)
        guard FileManager.default.createFile(atPath: spoolURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ReaderEBookPackageSnapshotError.unavailable
        }
        let spool = try FileHandle(forUpdating: spoolURL)
        defer { try? spool.close() }
        // Keep mimetype first and stored. No resource bytes or internal paths are
        // changed; timestamps and empty directory entries are not identity data.
        selected.sort {
            if ($0.1 == "mimetype") != ($1.1 == "mimetype") { return $0.1 == "mimetype" }
            return $0.1.utf8.lexicographicallyPrecedes($1.1.utf8)
        }
        for (entry, path) in selected {
            try Task.checkCancellation()
            try spool.truncate(atOffset: 0)
            try spool.seek(toOffset: 0)
            var actual: UInt64 = 0
            let crc = try input.extract(entry, bufferSize: 65_536, skipCRC32: false) { bytes in
                try Task.checkCancellation()
                guard UInt64(bytes.count) <= entry.uncompressedSize - actual else {
                    throw ReaderEBookFingerprintError.sizeChanged(path)
                }
                try spool.write(contentsOf: bytes)
                actual += UInt64(bytes.count)
            }
            guard actual == entry.uncompressedSize, crc == entry.checksum else {
                throw ReaderEBookFingerprintError.checksumMismatch(path)
            }
            try output.addEntry(with: path, type: .file, uncompressedSize: Int64(actual),
                modificationDate: Date(timeIntervalSince1970: 315_532_800), compressionMethod: .none) { offset, count in
                    try Task.checkCancellation()
                    guard offset >= 0, UInt64(offset) <= actual, UInt64(count) <= actual - UInt64(offset) else {
                        throw ReaderEBookFingerprintError.sizeChanged(path)
                    }
                    try spool.seek(toOffset: UInt64(offset))
                    let data = try spool.read(upToCount: count) ?? Data()
                    guard data.count == count else { throw ReaderEBookFingerprintError.sizeChanged(path) }
                    return data
                }
            let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
            guard let size, size.int64Value <= maximumBytes else { throw ReaderEBookFingerprintError.limitExceeded }
        }
        try Task.checkCancellation()
    }
}
