import Foundation
import XCTest
import ZIPFoundation
@testable import LakeOfFireContent

final class ReaderPackageResourceLimitTests: XCTestCase {
    func testEntryLimitBeforeReadForPackedAndDirectorySources() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed, entries: [("a", Data(repeating: 1, count: 9))])
            let source = try ReaderPackageEntrySource(localURL: fixture.url, limits: .init(maxEntryBytes: 8))
            XCTAssertThrowsError(try source.readEntry(subpath: "a")) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entrySizeExceeded(path: "a", size: 9, limit: 8))
            }
        }
    }

    func testExactReadLimitAndEmptyFilesForBothStorageKinds() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed, entries: [("a", Data([1, 2, 3, 4])), ("empty", Data())])
            let source = try ReaderPackageEntrySource(localURL: fixture.url, limits: .init(maxEntryBytes: 4))
            XCTAssertEqual(try source.readEntry(subpath: "a"), Data([1, 2, 3, 4]))
            XCTAssertEqual(try source.readEntry(subpath: "empty"), Data())
        }
    }

    func testCatalogAggregateForBothStorageKinds() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed, entries: [("a", Data([1, 2])), ("b", Data([3, 4]))])
            let source = try ReaderPackageEntrySource(localURL: fixture.url, limits: .init(maxAggregateUncompressedBytes: 3))
            XCTAssertThrowsError(try source.enumerateEntries()) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .aggregateSizeExceeded(limit: 3))
            }
        }
    }

    func testCatalogCountForBothStorageKinds() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed, entries: [("a", Data()), ("b", Data())])
            XCTAssertThrowsError(try ReaderPackageEntrySource(localURL: fixture.url,
                limits: .init(maxEntryCount: 1)).enumerateEntries()) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entryCountExceeded(limit: 1))
            }
        }
    }

    func testEmptyDirectoriesConsumeEntryBudget() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed, entries: [("one/", Data()), ("two/", Data())])
            XCTAssertThrowsError(try ReaderPackageEntrySource(localURL: fixture.url,
                limits: .init(maxEntryCount: 1)).enumerateEntries()) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entryCountExceeded(limit: 1))
            }
        }
    }

    func testIndividualAndAggregateNameBoundsForBothKinds() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed, entries: [("日本", Data()), ("語", Data())])
            XCTAssertThrowsError(try ReaderPackageEntrySource(localURL: fixture.url,
                limits: .init(maxPathUTF8Bytes: 5)).enumerateEntries()) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entryPathSizeExceeded(limit: 5))
            }
            XCTAssertThrowsError(try ReaderPackageEntrySource(localURL: fixture.url,
                limits: .init(maxAggregatePathUTF8Bytes: 8)).enumerateEntries()) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .aggregatePathSizeExceeded(limit: 8))
            }
        }
    }

    func testCorruptCRCIsRejectedByBothArchiveReadAPIs() throws {
        let fixture = try PackageResourceFixture(packed: true, entries: [("a", Data("readable".utf8))])
        try fixture.setUInt32(signature: [0x50, 0x4b, 0x01, 0x02], offset: 16, value: 0)
        let source = try ReaderPackageEntrySource(localURL: fixture.url)
        XCTAssertThrowsError(try source.readEntry(subpath: "a")) {
            XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .packageCorrupt)
        }
        let archive = try Archive(url: fixture.url, accessMode: .read)
        XCTAssertNil(archive.data(for: "a"))
    }

    func testUnderreportedZIPSizeCannotEvadeActualByteLimit() throws {
        let fixture = try PackageResourceFixture(packed: true, entries: [("a", Data(repeating: 1, count: 32_768))])
        try fixture.setUInt32(signature: [0x50, 0x4b, 0x03, 0x04], offset: 22, value: 1)
        try fixture.setUInt32(signature: [0x50, 0x4b, 0x01, 0x02], offset: 24, value: 1)
        let source = try ReaderPackageEntrySource(localURL: fixture.url, limits: .init(maxEntryBytes: 8))
        XCTAssertThrowsError(try source.readEntry(subpath: "a"))
    }

    func testLegacyArchiveConveniencePreservesValidReadsAndRejectsUnsafePath() throws {
        let fixture = try PackageResourceFixture(packed: true, entries: [("a", Data([1])), ("../outside", Data([2]))])
        let archive = try Archive(url: fixture.url, accessMode: .read)
        XCTAssertEqual(archive.data(for: "a"), Data([1]))
        XCTAssertNil(archive.data(for: "../outside"))
        XCTAssertNil(archive.data(for: "missing"))
    }

    func testCancelledProgressCannotPublishEvenAnEmptyEntry() throws {
        for packed in [false, true] {
            let fixture = try PackageResourceFixture(packed: packed, entries: [("a", Data())])
            let source = try ReaderPackageEntrySource(localURL: fixture.url)
            let progress = Progress(totalUnitCount: 0)
            progress.cancel()
            XCTAssertThrowsError(try source.readEntry(subpath: "a", progress: progress)) {
                XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .cancelled)
            }
        }
    }

    func testDirectoryGrowthAfterInspectionIsCheckedAtRead() throws {
        let fixture = try PackageResourceFixture(packed: false, entries: [("a", Data([1]))])
        let source = try ReaderPackageEntrySource(localURL: fixture.url, limits: .init(maxEntryBytes: 2))
        XCTAssertEqual(try source.enumerateEntries().first?.size, 1)
        try Data([1, 2, 3]).write(to: fixture.url.appendingPathComponent("a"))
        XCTAssertThrowsError(try source.readEntry(subpath: "a")) {
            XCTAssertEqual($0 as? ReaderPackageEntrySourceError, .entrySizeExceeded(path: "a", size: 3, limit: 2))
        }
    }
}

/// Synthetic files in a unique temporary directory; never opens a user's library.
final class PackageResourceFixture {
    let root: URL
    let url: URL

    init(packed: Bool, entries: [(String, Data)]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("resource-limits-\(UUID().uuidString)")
        url = root.appendingPathComponent("book.epub", isDirectory: !packed)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if packed {
            let archive = try Archive(url: url, accessMode: .create)
            for (path, data) in entries {
                try archive.addEntry(with: path, type: path.hasSuffix("/") ? .directory : .file,
                    uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                    data.subdata(in: Int(position)..<(Int(position) + size))
                }
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (path, data) in entries {
                let destination = url.appendingPathComponent(path)
                if path.hasSuffix("/") {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destination)
                }
            }
        }
    }

    func setUInt32(signature: [UInt8], offset: Int, value: UInt32) throws {
        var bytes = try Data(contentsOf: url)
        let start = try XCTUnwrap(bytes.range(of: Data(signature))).lowerBound + offset
        for i in 0..<4 { bytes[start + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        try bytes.write(to: url)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
