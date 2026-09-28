import Foundation
import XCTest
import ZIPFoundation
@testable import LakeOfFireContent

/// Real strict fingerprint + snapshot + the forward-ported bounded reader.
/// No user library is opened. All bytes are generated in a unique directory.
final class ReaderEBookPortCompositionTests: XCTestCase {
    func testAdmittedResourceAboveGenericReadLimitRemainsReadable() throws {
        let size = Int(ReaderPackageResourceLimits.default.maxEntryBytes) + 1
        try withPackage(resourceSize: size) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 2 * 1024 * 1024)
            let package = try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot)
            let store = ReaderEBookServingSessionStore()
            let lease = try store.install(package)
            let bytes = try lease.readEntry(subpath: "OPS/resource.bin")
            XCTAssertEqual(bytes.count, size)
            XCTAssertEqual(bytes.first, 7)
            XCTAssertEqual(bytes.last, 7)
            XCTAssertEqual(package.fingerprint.resources.first(where: { $0.path == "OPS/resource.bin" })?.byteCount, UInt64(size))
            // Ordinary readers keep their smaller budget; only this already
            // fingerprint-admitted serving package inherits its captured limits.
            XCTAssertThrowsError(try ReaderPackageEntrySource(localURL: snapshot.packageURL).readEntry(subpath: "OPS/resource.bin")) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError,
                    .entrySizeExceeded(path: "OPS/resource.bin", size: Int64(size), limit: ReaderPackageResourceLimits.default.maxEntryBytes))
            }
        }
    }

    func testSmallerExplicitFingerprintLimitIsStillEnforced() throws {
        try withPackage(resourceSize: 2049) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            XCTAssertThrowsError(try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot,
                limits: .init(maxEntryBytes: 2048))) {
                XCTAssertEqual($0 as? ReaderEBookFingerprintError, .limitExceeded)
            }
        }
    }

    func testExactCapturedBudgetServesUntilCapabilityIsWithdrawn() throws {
        try withPackage(resourceSize: 2048) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            let package = try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot,
                limits: .init(maxEntryBytes: 2048))
            let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
            XCTAssertEqual(try lease.readEntry(subpath: "OPS/resource.bin"), Data(repeating: 7, count: 2048))
            store.withdraw(lease)
            XCTAssertThrowsError(try lease.readEntry(subpath: "OPS/resource.bin"))
            XCTAssertThrowsError(try store.capture(sourceURL: sourceURL, sessionID: nil))
            XCTAssertThrowsError(try store.capture(sourceURL: sourceURL, sessionID: lease.id))
        }
    }

    func testAdmittedLongResourceAndDirectoryPathsKeepTheirLiteralBytes() throws {
        let longPath = String(repeating: "p", count: 16_384)
        let longDirectory = String(repeating: "d", count: 16_384) + "/"
        try withPackage(resourceSize: 1, extraEntries: [(longPath, false), (longDirectory, true)]) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            let package = try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot)
            let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
            XCTAssertEqual(try lease.readEntry(subpath: longPath), Data())
            XCTAssertTrue(package.fingerprint.resources.contains { $0.path.utf8.elementsEqual(longPath.utf8) })
            XCTAssertFalse(package.entries.contains { $0.path == longDirectory })
            XCTAssertThrowsError(try ReaderPackageEntrySource(localURL: snapshot.packageURL).enumerateEntries()) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entryPathSizeExceeded(limit: 4096))
            }
        }
    }

    func testExtraDirectorySlashesDoNotConsumeNormalizedFingerprintBudgetTwice() throws {
        let pathBudget = 16 * 1024 * 1024
        let fixedPaths = ["mimetype", "META-INF/container.xml", "OPS/book.opf", "OPS/resource.bin"]
        let available = pathBudget - fixedPaths.reduce(0) { $0 + $1.utf8.count }
        // Distinct short directory names: no resource is ever written to disk
        // at these archive member paths. Exact normalized v1 path total is
        // 16 MiB; raw directory entry names exceed it by one slash each.
        let count = 4096
        var remaining = available
        var names: [(String, Bool)] = []
        for index in 0..<count {
            let length = remaining / (count - index)
            let prefix = String(format: "%04x-", index)
            names.append((prefix + String(repeating: "p", count: length - prefix.utf8.count) + "/", true))
            remaining -= length
        }
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(names.reduce(0) { $0 + $1.0.utf8.count - 1 }, available)
        try withPackage(resourceSize: 1, extraEntries: names) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 64 * 1024 * 1024)
            let package = try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot)
            let store = ReaderEBookServingSessionStore(), lease = try store.install(package)
            XCTAssertEqual(try lease.readEntry(subpath: "OPS/resource.bin"), Data([7]))
            XCTAssertEqual(package.entries.count, fixedPaths.count)
        }
    }

    func testLargerReadEnvelopeCannotAuthorizeAnOverlongFingerprintPath() throws {
        let rejectedPath = String(repeating: "p", count: 16_385)
        try withPackage(resourceSize: 1, extraEntries: [(rejectedPath, false)]) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            XCTAssertThrowsError(try ReaderEBookServingPackage(sourceURL: sourceURL, snapshot: snapshot)) {
                XCTAssertEqual($0 as? ReaderEBookFingerprintError, .ambiguousPath(rejectedPath))
            }
        }
    }

    private var sourceURL: URL { URL(string: "ebook://ebook/load/local/Books/composition.epub")! }
    private func withPackage(resourceSize: Int, extraEntries: [(String, Bool)] = [], _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ebook-port-composition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.epub")
        do {
            let archive = try Archive(url: url, accessMode: .create)
            let files = [
                ("mimetype", "application/epub+zip"),
                ("META-INF/container.xml", "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='OPS/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"),
                ("OPS/book.opf", "<package><spine/></package>")
            ]
            for (path, text) in files {
                let data = Data(text.utf8)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, count in
                    data.subdata(in: Int(position)..<(Int(position) + count))
                }
            }
            try archive.addEntry(with: "OPS/resource.bin", type: .file, uncompressedSize: Int64(resourceSize), compressionMethod: .deflate) { _, count in
                Data(repeating: 7, count: count)
            }
            for (path, isDirectory) in extraEntries {
                try archive.addEntry(with: path, type: isDirectory ? .directory : .file,
                                     uncompressedSize: 0, compressionMethod: .none) { _, _ in Data() }
            }
        }
        try body(url)
    }
}
