import XCTest
@testable import LakeOfFireReader

private actor SidecarProcessorInvocationCounter {
    private var invocationCount = 0

    func increment() {
        invocationCount += 1
    }

    func value() -> Int {
        invocationCount
    }
}

final class ReaderExternalSegmentSidecarRetentionTests: XCTestCase {
    func testContentAddressedSidecarSurvivesMemoryEvictionAndStoreRecreation() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let firstStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )
        let retainedData = validSidecarData(runtimeIDToken: "!retained")
        let retained = firstStore.insert(retainedData)
        _ = firstStore.insert(validSidecarData(runtimeIDToken: "!evicting"))

        let recreatedStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )

        XCTAssertEqual(recreatedStore.entry(for: retained.token)?.data, retainedData)
        XCTAssertEqual(recreatedStore.entry(for: retained.token)?.signature, retained.signature)
    }

    func testCorruptDurableSidecarIsRejectedAndAtomicallyRegenerated() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let originalData = validSidecarData(runtimeIDToken: "!segment")
        let originalStore = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let stored = originalStore.insert(originalData)
        let fileURL = directoryURL.appendingPathComponent(stored.token)
        try Data("corrupt".utf8).write(to: fileURL, options: .atomic)

        let corruptedStore = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        XCTAssertNil(corruptedStore.entry(for: stored.token))

        XCTAssertEqual(corruptedStore.insert(originalData).token, stored.token)
        let recreatedStore = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        XCTAssertEqual(recreatedStore.entry(for: stored.token)?.data, originalData)
    }

    func testMissingExternalSidecarForcesProcessingRegeneration() async throws {
        let counter = SidecarProcessorInvocationCounter()
        let missingToken = String(repeating: "a", count: 64)
        let cachedHTML = """
        <html><head><meta name="mnb-segment-sidecar" content="ebook://ebook/processed-section-sidecar/\(missingToken)"></head><body><m-m id="runtime">猫</m-m></body></html>
        """
        let regeneratedHTML = inlineHTML(sidecarData: validSidecarData(runtimeIDToken: "!runtime"))
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in cachedHTML },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                await counter.increment()
                return regeneratedHTML
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/book.epub")!,
            location: "chapter.xhtml",
            text: "source",
            isCacheWarmer: false
        )

        let invocationCount = await counter.value()
        XCTAssertEqual(result, regeneratedHTML)
        XCTAssertEqual(invocationCount, 1)
    }

    func testSchemaNineRequiresExplicitSentenceIdentityAndExactRuntimeMapping() {
        let validCloneSidecar = sidecarData(
            runtimeIDTokens: ["!runtime-a", "!runtime-b"],
            segmentHashIndexes: [0, 0],
            sentenceIdentifierIndexes: [0, 0]
        )
        let duplicateRuntimeSidecar = sidecarData(
            runtimeIDTokens: ["!runtime-a", "!runtime-a"],
            segmentHashIndexes: [0, 0],
            sentenceIdentifierIndexes: [0, 0]
        )
        let hashOnlySidecar = sidecarData(
            runtimeIDTokens: ["!runtime"],
            segmentHashIndexes: [0],
            sentenceIdentifierIndexes: [nil]
        )

        XCTAssertTrue(ebookProcessedHTMLHasDurableSegmentIdentities(
            inlineHTML(sidecarData: validCloneSidecar, segmentCount: 2)
        ))
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(
            inlineHTML(sidecarData: duplicateRuntimeSidecar, segmentCount: 2)
        ))
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(
            inlineHTML(sidecarData: hashOnlySidecar)
        ))
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-sidecar-\(UUID().uuidString)", isDirectory: true)
    }

    private func validSidecarData(runtimeIDToken: String) -> Data {
        sidecarData(
            runtimeIDTokens: [runtimeIDToken],
            segmentHashIndexes: [0],
            sentenceIdentifierIndexes: [0]
        )
    }

    private func sidecarData(
        runtimeIDTokens: [String],
        segmentHashIndexes: [Int?],
        sentenceIdentifierIndexes: [Int?]
    ) -> Data {
        let segments = zip(runtimeIDTokens, zip(segmentHashIndexes, sentenceIdentifierIndexes)).map {
            runtimeIDToken, indexes -> [Any] in
            let segmentHashIndex: Any = indexes.0.map { $0 as Any } ?? NSNull()
            let sentenceIdentifierIndex: Any = indexes.1.map { $0 as Any } ?? NSNull()
            return [
                runtimeIDToken,
                segmentHashIndex,
                NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(),
                sentenceIdentifierIndex,
            ]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "v": 9,
            "t": ["h": ["segment-hash"], "sid": ["sentence-id"]],
            "s": segments,
        ], options: [.sortedKeys])
    }

    private func inlineHTML(sidecarData: Data, segmentCount: Int = 1) -> String {
        let segments = (0..<segmentCount).map { "<m-m id=\"runtime-\($0)\">猫</m-m>" }.joined()
        return "<html><body>\(segments)<script id=\"mnb-segment-metadata\">"
            + String(decoding: sidecarData, as: UTF8.self)
            + "</script></body></html>"
    }
}
