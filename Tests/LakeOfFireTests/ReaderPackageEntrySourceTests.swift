import XCTest
import ZIPFoundation
@testable import LakeOfFireContent

final class ReaderPackageEntrySourceTests: XCTestCase {
    func testKnownEbookMIMETypesAreDeterministicAndCaseInsensitive() throws {
        try withPackageSource { source in
            let expectations: [String: (mimeType: String, textEncodingName: String?)] = [
                "chapter.XHTML": ("application/xhtml+xml", "utf-8"),
                "chapter.HTML": ("text/html", "utf-8"),
                "package.OPF": ("application/oebps-package+xml", "utf-8"),
                "toc.NCX": ("application/x-dtbncx+xml", "utf-8"),
                "image.SVG": ("image/svg+xml", "utf-8"),
                "styles.CSS": ("text/css", "utf-8"),
                "module.MJS": ("text/javascript", "utf-8"),
                "font.TTF": ("font/ttf", nil),
                "font.OTF": ("font/otf", nil),
                "font.WOFF": ("font/woff", nil),
                "font.WOFF2": ("font/woff2", nil),
                "audio.WAV": ("audio/wav", nil),
                "audio.MP3": ("audio/mpeg", nil),
                "audio.M4A": ("audio/mp4", nil),
                "audio.AAC": ("audio/aac", nil),
                "video.MP4": ("video/mp4", nil),
                "video.WEBM": ("video/webm", nil),
            ]

            for (subpath, expected) in expectations {
                let metadata = try source.mimeType(subpath: subpath)
                XCTAssertEqual(metadata.mimeType, expected.mimeType, subpath)
                XCTAssertEqual(metadata.textEncodingName, expected.textEncodingName, subpath)
            }
        }
    }

    func testUnknownBinaryExtensionDoesNotClaimTextEncoding() throws {
        try withPackageSource { source in
            let metadata = try source.mimeType(subpath: "assets/payload.manabi-binary")

            XCTAssertEqual(metadata.mimeType, "application/octet-stream")
            XCTAssertNil(metadata.textEncodingName)
        }
    }

    func testDirectoryEnumerationAndReadUseStandardizedRelativePaths() throws {
        try withTemporaryDirectory { temporaryRoot in
            let packageRoot = temporaryRoot
                .appendingPathComponent("book.epub", isDirectory: true)
            let contentDirectory = packageRoot
                .appendingPathComponent("OPS", isDirectory: true)
            let chapterURL = contentDirectory.appendingPathComponent("日本語.xhtml")
            let chapter = Data("<html><body>本文</body></html>".utf8)
            try FileManager.default.createDirectory(
                at: contentDirectory,
                withIntermediateDirectories: true
            )
            try chapter.write(to: chapterURL)

            let source = try ReaderPackageEntrySource(
                localURL: packageRoot.appendingPathComponent(".").standardizedFileURL
            )

            XCTAssertEqual(try source.enumerateEntries().map(\.path), ["OPS/日本語.xhtml"])
            XCTAssertEqual(try source.readEntry(subpath: "OPS/日本語.xhtml"), chapter)
        }
    }

    func testArchiveEnumerationAndReadDoNotExpandArchive() throws {
        try withTemporaryDirectory { temporaryRoot in
            let archiveURL = temporaryRoot.appendingPathComponent("book.epub")
            let chapterPath = "OPS/日本語.xhtml"
            let chapter = Data("<html><body>本文</body></html>".utf8)
            try makeArchive(at: archiveURL, entries: [(chapterPath, chapter)])

            let source = try ReaderPackageEntrySource(localURL: archiveURL)

            XCTAssertEqual(try source.enumerateEntries().map(\.path), [chapterPath])
            XCTAssertEqual(try source.readEntry(subpath: chapterPath), chapter)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path),
                ["book.epub"]
            )
        }
    }

    func testSubpathValidationRejectsEscapeAndPreservesEncodedNames() throws {
        let invalidSubpaths = [
            "",
            "/OPS/chapter.xhtml",
            "OPS//chapter.xhtml",
            "OPS/./chapter.xhtml",
            "OPS/../chapter.xhtml",
            "OPS\\chapter.xhtml",
            "OPS/\0/chapter.xhtml",
        ]
        for subpath in invalidSubpaths {
            XCTAssertThrowsError(try ReaderPackageEntrySource.sanitizeSubpath(subpath), subpath)
        }
        XCTAssertEqual(
            try ReaderPackageEntrySource.sanitizeSubpath("OPS/%E6%97%A5%E6%9C%AC%E8%AA%9E.xhtml"),
            "OPS/%E6%97%A5%E6%9C%AC%E8%AA%9E.xhtml"
        )
    }

    func testArchiveEntryPathsRemainCaseSensitive() throws {
        try withTemporaryDirectory { temporaryRoot in
            let archiveURL = temporaryRoot.appendingPathComponent("case-sensitive.epub")
            try makeArchive(at: archiveURL, entries: [
                ("OPS/Chapter.xhtml", Data("uppercase".utf8)),
                ("OPS/chapter.xhtml", Data("lowercase".utf8)),
            ])
            let source = try ReaderPackageEntrySource(localURL: archiveURL)

            XCTAssertEqual(
                String(decoding: try source.readEntry(subpath: "OPS/Chapter.xhtml"), as: UTF8.self),
                "uppercase"
            )
            XCTAssertEqual(
                String(decoding: try source.readEntry(subpath: "OPS/chapter.xhtml"), as: UTF8.self),
                "lowercase"
            )
        }
    }

    func testDirectoryReadRejectsSymlinkEscape() throws {
        try withTemporaryDirectory { temporaryRoot in
            let packageRoot = temporaryRoot.appendingPathComponent("book", isDirectory: true)
            let outsideRoot = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(
                at: packageRoot,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: outsideRoot,
                withIntermediateDirectories: true
            )
            try Data("secret".utf8).write(to: outsideRoot.appendingPathComponent("secret.txt"))
            try FileManager.default.createSymbolicLink(
                at: packageRoot.appendingPathComponent("escape"),
                withDestinationURL: outsideRoot
            )
            let source = try ReaderPackageEntrySource(localURL: packageRoot)

            XCTAssertThrowsError(try source.readEntry(subpath: "escape/secret.txt")) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .invalidSubpath)
            }
        }
    }

    func testArchiveEnumerationRejectsUnsafeEntryPaths() throws {
        try withTemporaryDirectory { temporaryRoot in
            let archiveURL = temporaryRoot.appendingPathComponent("unsafe.epub")
            try makeArchive(at: archiveURL, entries: [
                ("OPS/chapter.xhtml", Data("safe".utf8)),
                ("../outside.xhtml", Data("unsafe".utf8)),
            ])
            let source = try ReaderPackageEntrySource(localURL: archiveURL)

            XCTAssertThrowsError(try source.enumerateEntries()) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .invalidSubpath)
            }
        }
    }

    func testArchiveReadRejectsDuplicateEntryPaths() throws {
        try withTemporaryDirectory { temporaryRoot in
            let archiveURL = temporaryRoot.appendingPathComponent("duplicate.epub")
            try makeArchive(at: archiveURL, entries: [
                ("OPS/chapter.xhtml", Data("first".utf8)),
                ("OPS/chapter.xhtml", Data("second".utf8)),
            ])
            let source = try ReaderPackageEntrySource(localURL: archiveURL)

            XCTAssertThrowsError(try source.readEntry(subpath: "OPS/chapter.xhtml")) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .ambiguousEntry)
            }
        }
    }

    func testArchiveReadPropagatesCancellation() throws {
        try withTemporaryDirectory { temporaryRoot in
            let archiveURL = temporaryRoot.appendingPathComponent("cancel.epub")
            try makeArchive(
                at: archiveURL,
                entries: [("OPS/chapter.xhtml", Data(repeating: 0x41, count: 1_000_000))]
            )
            let source = try ReaderPackageEntrySource(localURL: archiveURL)
            let progress = Progress(totalUnitCount: 0)
            progress.cancel()

            XCTAssertThrowsError(
                try source.readEntry(subpath: "OPS/chapter.xhtml", progress: progress)
            )
        }
    }

    func testArchiveEnumerationRejectsEncryptedEntriesOmittedByZIPFoundation() throws {
        try withTemporaryDirectory { temporaryRoot in
            let archiveURL = temporaryRoot.appendingPathComponent("encrypted.epub")
            try makeArchive(
                at: archiveURL,
                entries: [("OPS/chapter.xhtml", Data("encrypted".utf8))]
            )
            try setZIPUInt16Bit(
                atRecordSignature: [0x50, 0x4B, 0x01, 0x02],
                fieldOffset: 8,
                bit: 0,
                in: archiveURL
            )
            let source = try ReaderPackageEntrySource(localURL: archiveURL)

            XCTAssertThrowsError(try source.enumerateEntries()) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .unsupportedSource)
            }
        }
    }

    func testArchiveReadMapsUnsupportedCompressionToTypedSourceError() throws {
        try withTemporaryDirectory { temporaryRoot in
            let archiveURL = temporaryRoot.appendingPathComponent("unsupported-compression.epub")
            try makeArchive(
                at: archiveURL,
                entries: [("OPS/chapter.xhtml", Data("unsupported".utf8))]
            )
            try replaceZIPUInt16(
                atRecordSignature: [0x50, 0x4B, 0x03, 0x04],
                fieldOffset: 8,
                with: 99,
                in: archiveURL
            )
            try replaceZIPUInt16(
                atRecordSignature: [0x50, 0x4B, 0x01, 0x02],
                fieldOffset: 10,
                with: 99,
                in: archiveURL
            )
            let source = try ReaderPackageEntrySource(localURL: archiveURL)

            XCTAssertThrowsError(try source.readEntry(subpath: "OPS/chapter.xhtml")) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .unsupportedSource)
            }
        }
    }

    private func withPackageSource(
        _ operation: (ReaderPackageEntrySource) throws -> Void
    ) throws {
        try withTemporaryDirectory { directoryURL in
            try operation(ReaderPackageEntrySource(localURL: directoryURL))
        }
    }

    private func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reader-package-source-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try operation(directoryURL)
    }

    private func makeArchive(
        at archiveURL: URL,
        entries: [(path: String, data: Data)]
    ) throws {
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for entry in entries {
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(entry.data.count),
                compressionMethod: .deflate
            ) { position, size in
                entry.data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
    }

    private func setZIPUInt16Bit(
        atRecordSignature signature: [UInt8],
        fieldOffset: Int,
        bit: UInt16,
        in archiveURL: URL
    ) throws {
        var archiveData = try Data(contentsOf: archiveURL)
        let recordRange = try XCTUnwrap(archiveData.range(of: Data(signature)))
        let valueOffset = recordRange.lowerBound + fieldOffset
        let value = UInt16(archiveData[valueOffset])
            | (UInt16(archiveData[valueOffset + 1]) << 8)
            | (1 << bit)
        archiveData[valueOffset] = UInt8(truncatingIfNeeded: value)
        archiveData[valueOffset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        try archiveData.write(to: archiveURL, options: .atomic)
    }

    private func replaceZIPUInt16(
        atRecordSignature signature: [UInt8],
        fieldOffset: Int,
        with value: UInt16,
        in archiveURL: URL
    ) throws {
        var archiveData = try Data(contentsOf: archiveURL)
        let recordRange = try XCTUnwrap(archiveData.range(of: Data(signature)))
        let valueOffset = recordRange.lowerBound + fieldOffset
        archiveData[valueOffset] = UInt8(truncatingIfNeeded: value)
        archiveData[valueOffset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        try archiveData.write(to: archiveURL, options: .atomic)
    }
}
