import Foundation
import XCTest
import LakeOfFireContent
@_spi(ReaderProcessing) @testable import LakeOfFireReader

final class EbookProcessingCancellationTests: XCTestCase {
    private actor Events {
        private var values: [String] = []
        func record(_ value: String) { values.append(value) }
        func snapshot() -> [String] { values }
    }

    private func payload() -> EbookProcessedSectionPayload {
        .successfulReaderProcessing(
            documentHTML: Data("<m-c pid=\"p\"><m-s sid=\"s\" o=\"true\"><m-m id=\"m\">本文</m-m></m-s></m-c>".utf8),
            segmentSidecar: Data(#"{"v":\#(ReaderCompactSegmentSidecarSchema.currentVersion),"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["本文"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        )
    }

    private func processor(
        writer: EbookProcessedTextCacheWriter? = nil,
        process: EbookTextProcessor? = nil
    ) -> EBookProcessingActor {
        EBookProcessingActor(ebookProcessedTextCacheWriter: writer,
            ebookTextProcessor: process, processReadabilityContent: nil,
            processHTMLDocument: nil, processHTMLBytes: nil, processHTML: nil)
    }

    private func assertCancelled<T: Sendable>(_ operation: Task<T, Error>,
        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await operation.value
            XCTFail("Canceled work returned success", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, received \(error)", file: file, line: line)
        }
    }

    func testAlreadyCancelledProcessingDoesNotInvokeProcessorOrWriter() async {
        let events = Events()
        let result = payload()
        let adapter = processor(writer: { _, _, _, _ in await events.record("write") },
            process: { _, _, _, _, _, _, _, _, _ in
                await events.record("process")
                return result
            })
        await assertCancelled(Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.process(contentURL: URL(string: "ebook://book/test.epub")!,
                location: "chapter.xhtml", text: "本文", isCacheWarmer: false)
        })
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, [])
    }

    func testAlreadyCancelledFallbackDoesNotReturnPayload() async {
        let adapter = processor()
        await assertCancelled(Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.process(contentURL: URL(string: "ebook://book/test.epub")!,
                location: "chapter.xhtml", text: "本文", isCacheWarmer: false)
        })
    }

    func testAlreadyCancelledPrewarmStopsBeforeMissingEntryRead() async throws {
        // An existing directory requires no fixture writes. Reading this absent
        // entry would throw a file error if cancellation admission were missing.
        let source = try ReaderPackageEntrySource(
            localURL: FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
        let adapter = processor()
        await assertCancelled(Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.prewarm(contentURL: URL(string: "ebook://book/test.epub")!,
                sectionHref: "absent-\(UUID().uuidString).xhtml", source: source)
        })
    }

    func testNoncooperativeProcessorCannotPublishAfterCancellation() async {
        let events = Events()
        let result = payload()
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(result))
        let adapter = processor(writer: { _, _, _, _ in await events.record("write") },
            process: { _, _, _, _, _, _, _, _, _ in
                await events.record("process")
                withUnsafeCurrentTask { $0?.cancel() }
                return result
            })
        await assertCancelled(Task {
            try await adapter.process(contentURL: URL(string: "ebook://book/test.epub")!,
                location: "chapter.xhtml", text: "本文", isCacheWarmer: false)
        })
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["process"])
    }

    func testCancellationDuringWriterRejectsSuccessWithoutUndoingPublication() async {
        let events = Events()
        let result = payload()
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(result))
        let adapter = processor(writer: { _, _, _, _ in
            await events.record("write")
            withUnsafeCurrentTask { $0?.cancel() }
        }, process: { _, _, _, _, _, _, _, _, _ in result })
        await assertCancelled(Task {
            try await adapter.process(contentURL: URL(string: "ebook://book/test.epub")!,
                location: "chapter.xhtml", text: "本文", isCacheWarmer: false)
        })
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["write"])
    }

    func testCacheProbeRejectsNoncooperativeCancelledHitAndMiss() async {
        let result = payload()
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(result))
        for candidate in [result, nil] as [EbookProcessedSectionPayload?] {
            await assertCancelled(Task {
                try await probeEbookProcessedSectionCache(reader: { _, _, _ in
                    await Task.yield()
                    withUnsafeCurrentTask { $0?.cancel() }
                    return candidate
                }, contentURL: URL(string: "ebook://book/test.epub")!,
                    location: "chapter.xhtml", contentFingerprint: "fingerprint")
            })
        }
    }

    func testUncancelledProcessingPublishesOnlyForegroundPayload() async throws {
        let events = Events()
        let result = payload()
        let adapter = processor(writer: { _, _, fingerprint, written in
            XCTAssertEqual(fingerprint, "captured-fingerprint")
            XCTAssertEqual(written.documentHTML, result.documentHTML)
            await events.record("write")
        }, process: { _, _, _, fingerprint, _, _, _, _, _ in
            XCTAssertEqual(fingerprint, "captured-fingerprint")
            await events.record("process")
            return result
        })
        for isWarmer in [false, true] {
            let processed = try await adapter.process(contentURL: URL(string: "ebook://book/test.epub")!,
                location: "chapter.xhtml", text: "本文", contentFingerprint: "captured-fingerprint",
                isCacheWarmer: isWarmer)
            XCTAssertEqual(processed.documentHTML, result.documentHTML)
            XCTAssertEqual(processed.segmentSidecar, result.segmentSidecar)
        }
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["process", "write", "process"])
    }
}
