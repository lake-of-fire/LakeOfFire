import Foundation
import XCTest
@testable import LakeOfFireReader

final class EbookProcessingCancellationTests: XCTestCase {
    private actor Events {
        private var values: [String] = []
        func record(_ value: String) { values.append(value) }
        func snapshot() -> [String] { values }
    }

    private func payload() -> EbookProcessedSectionPayload {
        EbookProcessedSectionPayload(
            documentHTML: Data("<html><head></head><body>plain text</body></html>".utf8),
            segmentSidecar: Data()
        )
    }

    private func processor(
        reader: EbookProcessedTextCacheReader? = nil,
        writer: EbookProcessedTextCacheWriter? = nil,
        process: EbookTextProcessor? = nil
    ) -> EBookProcessingActor {
        EBookProcessingActor(
            ebookProcessedTextCacheReader: reader,
            ebookProcessedTextCacheWriter: writer,
            ebookTextProcessor: process,
            processReadabilityContent: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )
    }

    private func run(
        _ processor: EBookProcessingActor,
        warmer: Bool = false,
        preCancelled: Bool = false
    ) -> Task<EbookProcessedSectionPayload, Error> {
        Task {
            if preCancelled { withUnsafeCurrentTask { $0?.cancel() } }
            return try await processor.process(
                contentURL: URL(string: "ebook://ebook/load/local/test.epub")!,
                location: "OPS/chapter.xhtml",
                text: "plain text",
                isCacheWarmer: warmer
            )
        }
    }

    private func assertCancelled(_ task: Task<EbookProcessedSectionPayload, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled processing returned a payload")
        } catch is CancellationError {
            XCTAssertTrue(task.isCancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPreCancelledProcessingStartsNoCacheReadOrProcessor() async {
        let events = Events()
        let value = payload()
        let actor = processor(
            reader: { _, _, _, _ in await events.record("read"); return value },
            process: { _, _, _, _, _, _, _, _, _ in await events.record("process"); return value }
        )
        await assertCancelled(run(actor, preCancelled: true))
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, [])
    }

    func testNonCooperativeCacheHitCannotReturnAfterCancellation() async {
        let events = Events()
        let value = payload()
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(value))
        let actor = processor(
            reader: { _, _, _, _ in
                await events.record("read")
                withUnsafeCurrentTask { $0?.cancel() }
                return value
            },
            process: { _, _, _, _, _, _, _, _, _ in await events.record("process"); return value }
        )
        await assertCancelled(run(actor))
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["read"])
    }

    func testNonCooperativeCacheMissCannotStartProcessorAfterCancellation() async {
        let events = Events()
        let value = payload()
        let actor = processor(
            reader: { _, _, _, _ in
                await events.record("read")
                withUnsafeCurrentTask { $0?.cancel() }
                return nil
            },
            process: { _, _, _, _, _, _, _, _, _ in await events.record("process"); return value }
        )
        await assertCancelled(run(actor))
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["read"])
    }

    func testNonCooperativeProcessorCannotPublishToCacheAfterCancellation() async {
        let events = Events()
        let value = payload()
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(value))
        let actor = processor(
            writer: { _, _, _, _, _ in await events.record("write") },
            process: { _, _, _, _, _, _, _, _, _ in
                await events.record("process")
                withUnsafeCurrentTask { $0?.cancel() }
                return value
            }
        )
        await assertCancelled(run(actor))
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["process"])
    }

    func testCancellationDuringCacheWriteSuppressesReturnedPayloadWithoutUndoingWrite() async {
        let events = Events()
        let value = payload()
        let actor = processor(
            writer: { _, _, _, _, _ in
                await events.record("write")
                withUnsafeCurrentTask { $0?.cancel() }
            },
            process: { _, _, _, _, _, _, _, _, _ in await events.record("process"); return value }
        )
        await assertCancelled(run(actor))
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["process", "write"])
    }

    func testCancelledWarmerDoesNotReturnProcessedPayload() async {
        let events = Events()
        let value = payload()
        let actor = processor(
            reader: { _, _, _, _ in await events.record("read"); return value },
            writer: { _, _, _, _, _ in await events.record("write") },
            process: { _, _, _, _, _, _, _, _, _ in
                await events.record("process")
                withUnsafeCurrentTask { $0?.cancel() }
                return value
            }
        )
        await assertCancelled(run(actor, warmer: true))
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["process"])
    }

    func testCurrentProcessingStillWaitsForCachePublicationAndReturnsPayload() async throws {
        let events = Events()
        let value = payload()
        let actor = processor(
            reader: { _, _, _, _ in await events.record("read"); return nil },
            writer: { _, _, _, _, _ in await Task.yield(); await events.record("write") },
            process: { _, _, _, _, _, _, _, _, _ in await events.record("process"); return value }
        )
        let result = try await run(actor).value
        let recorded = await events.snapshot()
        XCTAssertEqual(recorded, ["read", "process", "write"])
        XCTAssertEqual(result.documentHTML, value.documentHTML)
        XCTAssertEqual(result.segmentSidecar, value.segmentSidecar)
    }
}
