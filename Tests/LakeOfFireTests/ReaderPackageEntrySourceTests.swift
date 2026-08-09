import XCTest
import ZIPFoundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import LakeOfFireContent

final class ReaderPackageEntrySourceTests: XCTestCase {
    func testTextDecodingRecognizesUTF16BOMsAndXMLSignatures() throws {
        try withPackageSource { source in
            let text = "<html><body>日本語</body></html>"
            let littleEndian = Data([0xFF, 0xFE]) + (try XCTUnwrap(
                text.data(using: .utf16LittleEndian)
            ))
            let bigEndian = Data([0xFE, 0xFF]) + (try XCTUnwrap(
                text.data(using: .utf16BigEndian)
            ))
            let littleEndianSignature = try XCTUnwrap(text.data(using: .utf16LittleEndian))
            let bigEndianSignature = try XCTUnwrap(text.data(using: .utf16BigEndian))

            XCTAssertEqual(ReaderPackageEntrySource.decodeText(littleEndian), text)
            XCTAssertEqual(ReaderPackageEntrySource.decodeText(bigEndian), text)
            XCTAssertEqual(ReaderPackageEntrySource.decodeText(littleEndianSignature), text)
            XCTAssertEqual(ReaderPackageEntrySource.decodeText(bigEndianSignature), text)

            XCTAssertEqual(
                try source.mimeType(subpath: "chapter.xhtml", data: littleEndian).textEncodingName,
                "utf-16le"
            )
            XCTAssertEqual(
                try source.mimeType(subpath: "chapter.xhtml", data: bigEndianSignature).textEncodingName,
                "utf-16be"
            )
        }
    }

    func testDataAwareMIMETypeDoesNotAssignEncodingToBinaryContent() throws {
        try withPackageSource { source in
            let metadata = try source.mimeType(
                subpath: "font.ttf",
                data: Data([0xFF, 0xFE, 0x41, 0x00])
            )

            XCTAssertEqual(metadata.mimeType, "font/ttf")
            XCTAssertNil(metadata.textEncodingName)
        }
    }

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

    func testRelativeHrefResolutionMatchesRendererPackageSemantics() {
        XCTAssertEqual(
            ReaderPackageEntrySource.resolveSubpath(
                "../Images/cover%20art.jpg#thumbnail",
                relativeTo: "OPS/Text"
            ),
            "OPS/Images/cover art.jpg"
        )
        XCTAssertEqual(
            ReaderPackageEntrySource.resolveSubpath(
                "package%252Fname%20x.opf",
                relativeTo: "OPS"
            ),
            "OPS/package%2Fname x.opf"
        )
        XCTAssertEqual(
            ReaderPackageEntrySource.resolveSubpath(
                "chapter%2Fpart.xhtml",
                relativeTo: "OPS"
            ),
            "OPS/chapter%2Fpart.xhtml"
        )
        XCTAssertEqual(
            ReaderPackageEntrySource.resolveSubpath(" chapter.xhtml ", relativeTo: "OPS"),
            "OPS/chapter.xhtml"
        )
        XCTAssertEqual(
            ReaderPackageEntrySource.resolveSubpath(
                "\u{00A0}chapter.xhtml\u{00A0}",
                relativeTo: "OPS"
            ),
            "OPS/\u{00A0}chapter.xhtml\u{00A0}"
        )
        XCTAssertNil(
            ReaderPackageEntrySource.resolveSubpath("web+epub:external.opf", relativeTo: "OPS")
        )
        XCTAssertNil(
            ReaderPackageEntrySource.resolveSubpath("../../../outside.jpg", relativeTo: "OPS/Text")
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

    func testDirectoryEnumerationSkipsEscapingSymlinkAndKeepsValidEntries() throws {
        try withTemporaryDirectory { temporaryRoot in
            let packageRoot = temporaryRoot.appendingPathComponent("book", isDirectory: true)
            let outsideFileURL = temporaryRoot.appendingPathComponent("outside.xhtml")
            let validFileURL = packageRoot.appendingPathComponent("chapter.xhtml")
            let escapingLinkURL = packageRoot.appendingPathComponent("escaping.xhtml")
            try FileManager.default.createDirectory(
                at: packageRoot,
                withIntermediateDirectories: true
            )
            try Data("valid".utf8).write(to: validFileURL)
            try Data("outside".utf8).write(to: outsideFileURL)
            try FileManager.default.createSymbolicLink(
                at: escapingLinkURL,
                withDestinationURL: outsideFileURL
            )
            let source = try ReaderPackageEntrySource(localURL: packageRoot)

            XCTAssertEqual(try source.enumerateEntries().map(\.path), ["chapter.xhtml"])
        }
    }

    func testDirectoryEnumerationIncludesDotPrefixedPackageResources() throws {
        try withTemporaryDirectory { temporaryRoot in
            let packageRoot = temporaryRoot.appendingPathComponent("book.epub", isDirectory: true)
            let hiddenDirectory = packageRoot.appendingPathComponent("OPS/.assets", isDirectory: true)
            let hiddenChapterURL = hiddenDirectory.appendingPathComponent(".chapter.xhtml")
            try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
            try Data("<html></html>".utf8).write(to: hiddenChapterURL)

            let source = try ReaderPackageEntrySource(localURL: packageRoot)
            XCTAssertEqual(try source.enumerateEntries().map(\.path), ["OPS/.assets/.chapter.xhtml"])
            XCTAssertEqual(
                String(
                    decoding: try source.readEntry(subpath: "OPS/.assets/.chapter.xhtml"),
                    as: UTF8.self
                ),
                "<html></html>"
            )
        }
    }

#if canImport(Darwin) || canImport(Glibc)
    func testDirectoryReadRejectsFIFOWithoutBlocking() throws {
        try withTemporaryDirectory { temporaryRoot in
            let packageRoot = temporaryRoot.appendingPathComponent("book", isDirectory: true)
            let metadataDirectory = packageRoot.appendingPathComponent("META-INF", isDirectory: true)
            let fifoURL = metadataDirectory.appendingPathComponent("container.xml")
            try FileManager.default.createDirectory(
                at: metadataDirectory,
                withIntermediateDirectories: true
            )
            XCTAssertEqual(mkfifo(fifoURL.path, mode_t(0o600)), 0)
            let source = try ReaderPackageEntrySource(localURL: packageRoot)

            XCTAssertThrowsError(try source.readEntry(subpath: "META-INF/container.xml")) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .invalidSubpath)
            }
        }
    }

    func testDirectorySourceRejectsReplacedAncestorSymlink() throws {
        try withTemporaryDirectory { temporaryRoot in
            let originalParent = temporaryRoot.appendingPathComponent("mounted", isDirectory: true)
            let movedParent = temporaryRoot.appendingPathComponent("mounted-original", isDirectory: true)
            let replacementParent = temporaryRoot.appendingPathComponent("replacement", isDirectory: true)
            let originalPackageRoot = originalParent.appendingPathComponent("book", isDirectory: true)
            let replacementPackageRoot = replacementParent.appendingPathComponent("book", isDirectory: true)
            let subpath = "OPS/chapter.xhtml"
            let originalChapterURL = originalPackageRoot.appendingPathComponent(subpath)
            let replacementChapterURL = replacementPackageRoot.appendingPathComponent(subpath)
            try FileManager.default.createDirectory(
                at: originalChapterURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: replacementChapterURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("inside".utf8).write(to: originalChapterURL)
            try Data("outside".utf8).write(to: replacementChapterURL)
            let source = try ReaderPackageEntrySource(localURL: originalPackageRoot)

            try FileManager.default.moveItem(at: originalParent, to: movedParent)
            try FileManager.default.createSymbolicLink(
                at: originalParent,
                withDestinationURL: replacementParent
            )

            XCTAssertThrowsError(try source.readEntry(subpath: subpath)) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .invalidSubpath)
            }
            XCTAssertThrowsError(try source.enumerateEntries()) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .invalidSubpath)
            }
        }
    }

    func testDirectorySourceRejectsSamePathRootReplacement() throws {
        try withTemporaryDirectory { temporaryRoot in
            let mountedParent = temporaryRoot.appendingPathComponent("mounted", isDirectory: true)
            let movedParent = temporaryRoot.appendingPathComponent("mounted-original", isDirectory: true)
            let packageRoot = mountedParent.appendingPathComponent("book", isDirectory: true)
            let subpath = "OPS/chapter.xhtml"
            let chapterURL = packageRoot.appendingPathComponent(subpath)
            try FileManager.default.createDirectory(
                at: chapterURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("inside".utf8).write(to: chapterURL)
            let source = try ReaderPackageEntrySource(localURL: packageRoot)

            try FileManager.default.moveItem(at: mountedParent, to: movedParent)
            let replacementChapterURL = packageRoot.appendingPathComponent(subpath)
            try FileManager.default.createDirectory(
                at: replacementChapterURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("replacement".utf8).write(to: replacementChapterURL)

            XCTAssertThrowsError(try source.readEntry(subpath: subpath)) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .invalidSubpath)
            }
        }
    }

    func testArchiveSourceRejectsPathReplacementAfterConstruction() throws {
        try withTemporaryDirectory { temporaryRoot in
            let archiveURL = temporaryRoot.appendingPathComponent("book.epub")
            let replacementURL = temporaryRoot.appendingPathComponent("replacement.epub")
            let displacedURL = temporaryRoot.appendingPathComponent("book-original.epub")
            try makeArchive(
                at: archiveURL,
                entries: [("OPS/old.xhtml", Data("old".utf8))]
            )
            try makeArchive(
                at: replacementURL,
                entries: [("OPS/new.xhtml", Data("new".utf8))]
            )
            let source = try ReaderPackageEntrySource(localURL: archiveURL)
            XCTAssertEqual(try source.enumerateEntries().map(\.path), ["OPS/old.xhtml"])

            try FileManager.default.moveItem(at: archiveURL, to: displacedURL)
            try FileManager.default.moveItem(at: replacementURL, to: archiveURL)

            XCTAssertThrowsError(try source.enumerateEntries()) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .unsupportedSource)
            }
            XCTAssertThrowsError(try source.readEntry(subpath: "OPS/new.xhtml"))
        }
    }

    func testArchiveSourceRejectsSameInodeRewriteWithRestoredMetadata() throws {
        try withTemporaryDirectory { temporaryRoot in
            let archiveURL = temporaryRoot.appendingPathComponent("book.epub")
            let replacementURL = temporaryRoot.appendingPathComponent("replacement.epub")
            let subpath = "OPS/chapter.xhtml"
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            try makeArchive(at: archiveURL, entries: [(subpath, Data("old".utf8))])
            try makeArchive(at: replacementURL, entries: [(subpath, Data("new".utf8))])
            try FileManager.default.setAttributes(
                [.modificationDate: fixedDate],
                ofItemAtPath: archiveURL.path
            )
            let replacementData = try Data(contentsOf: replacementURL)
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber,
                try FileManager.default.attributesOfItem(atPath: replacementURL.path)[.size] as? NSNumber
            )
            let source = try ReaderPackageEntrySource(localURL: archiveURL)
            let originalInode = try inode(at: archiveURL)

            try replacementData.write(to: archiveURL, options: [])
            try FileManager.default.setAttributes(
                [.modificationDate: fixedDate],
                ofItemAtPath: archiveURL.path
            )
            XCTAssertEqual(try inode(at: archiveURL), originalInode)

            XCTAssertThrowsError(try source.enumerateEntries()) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .unsupportedSource)
            }
            XCTAssertThrowsError(try source.readEntry(subpath: subpath)) { error in
                XCTAssertEqual(error as? ReaderPackageEntrySourceError, .unsupportedSource)
            }
        }
    }
#endif

    func testPackageEntrySourceCacheEvictsLeastRecentlyUsedSources() async throws {
        try await withTemporaryDirectory { temporaryRoot in
            let packages = try (1...4).map { index in
                let packageURL = temporaryRoot.appendingPathComponent("book-\(index)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: packageURL,
                    withIntermediateDirectories: true
                )
                try Data("chapter-\(index)".utf8).write(
                    to: packageURL.appendingPathComponent("chapter.xhtml")
                )
                return (packageURL, try diagnosticReaderURL(for: packageURL, index: index))
            }
            let cache = ReaderPackageEntrySourceCache(countLimit: 2)
            let readerFileManager = ReaderFileManager()

            for package in packages.prefix(3) {
                _ = try await cache.cachedSource(
                    forPackageURL: package.1,
                    readerFileManager: readerFileManager
                )
            }
            let initialCount = await cache.cachedSourceCountForTesting()
            let initialOrder = await cache.cachedSourcePathsInLRUOrderForTesting()
            XCTAssertEqual(initialCount, 2)
            XCTAssertEqual(
                initialOrder,
                packages[1...2].map { $0.0.standardizedFileURL.path }
            )

            _ = try await cache.cachedSource(
                forPackageURL: packages[1].1,
                readerFileManager: readerFileManager
            )
            _ = try await cache.cachedSource(
                forPackageURL: packages[3].1,
                readerFileManager: readerFileManager
            )
            let finalOrder = await cache.cachedSourcePathsInLRUOrderForTesting()
            XCTAssertEqual(
                finalOrder,
                [packages[1].0.standardizedFileURL.path, packages[3].0.standardizedFileURL.path]
            )
        }
    }

    func testPackageEntrySourceCacheDoesNotPublishPrecancelledRequest() async throws {
        try await withTemporaryDirectory { temporaryRoot in
            let packageURL = temporaryRoot.appendingPathComponent("cancelled", isDirectory: true)
            try FileManager.default.createDirectory(
                at: packageURL,
                withIntermediateDirectories: true
            )
            try Data("chapter".utf8).write(to: packageURL.appendingPathComponent("chapter.xhtml"))
            let readerURL = try diagnosticReaderURL(for: packageURL, index: 1)
            let cache = ReaderPackageEntrySourceCache(countLimit: 2)
            let readerFileManager = ReaderFileManager()
            var continuation: AsyncStream<Void>.Continuation!
            let startStream = AsyncStream<Void> { continuation = $0 }
            let request = Task {
                var iterator = startStream.makeAsyncIterator()
                _ = await iterator.next()
                return try await cache.cachedSource(
                    forPackageURL: readerURL,
                    readerFileManager: readerFileManager
                )
            }
            await Task.yield()
            request.cancel()
            continuation.yield(())
            continuation.finish()

            do {
                _ = try await request.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            }
            let cachedSourceCount = await cache.cachedSourceCountForTesting()
            XCTAssertEqual(cachedSourceCount, 0)
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

#if canImport(Darwin) || canImport(Glibc)
    private func inode(at url: URL) throws -> UInt64 {
        var information = stat()
        guard url.path.withCString({ stat($0, &information) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return UInt64(information.st_ino)
    }
#endif

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

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reader-package-source-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try await operation(directoryURL)
    }

    private func diagnosticReaderURL(for packageURL: URL, index: Int) throws -> URL {
        var components = URLComponents()
        components.scheme = "ebook"
        components.host = "ebook"
        components.path = "/load/local/Books/book-\(index).epub"
        components.queryItems = [
            URLQueryItem(name: "diagnosticLocalFilePath", value: packageURL.path),
        ]
        return try XCTUnwrap(components.url)
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
