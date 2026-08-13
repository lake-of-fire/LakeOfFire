import XCTest
import WebKit
@testable import LakeOfFireReader

private final class CapturingURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: URLResponse?
    private(set) var data = Data()
    private(set) var finished = false
    private(set) var failure: Error?

    init(url: URL) {
        request = URLRequest(url: url)
    }

    func didReceive(_ response: URLResponse) {
        self.response = response
    }

    func didReceive(_ data: Data) {
        self.data.append(data)
    }

    func didFinish() {
        finished = true
    }

    func didFailWithError(_ error: Error) {
        failure = error
    }
}

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
    @MainActor
    func testInternalReaderSchemeHandlerServesStoredSidecar() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let data = validSidecarData(runtimeIDToken: "!article")
        let externalized = externalizingCanonicalReaderSegmentSidecar(
            in: Array(inlineHTML(sidecarData: data).utf8),
            scheme: .internalReader,
            store: store
        )
        let endpointString = try XCTUnwrap(externalized.endpointURL)
        let endpoint = try XCTUnwrap(URL(string: endpointString))
        let task = CapturingURLSchemeTask(url: endpoint)
        let handler = InternalURLSchemeHandler()
        handler.externalSegmentSidecarStore = store

        handler.webView(WKWebView(), start: task)

        XCTAssertEqual(task.data, data)
        XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            (task.response as? HTTPURLResponse)?.value(
                forHTTPHeaderField: "X-Manabi-Sidecar-Signature"
            ),
            externalized.signature
        )
        XCTAssertFalse(String(decoding: externalized.documentHTML, as: UTF8.self).contains(
            #"id="mnb-segment-metadata""#
        ))
        XCTAssertTrue(task.finished)
        XCTAssertNil(task.failure)
    }

    func testContentAddressedSidecarSurvivesMemoryEvictionAndStoreRecreation() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let firstStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )
        let retainedData = validSidecarData(runtimeIDToken: "!retained")
        let retained = try XCTUnwrap(firstStore.insert(retainedData))
        _ = firstStore.insert(validSidecarData(runtimeIDToken: "!evicting"))

        let recreatedStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )

        XCTAssertEqual(recreatedStore.entry(for: retained.token)?.data, retainedData)
        XCTAssertEqual(recreatedStore.entry(for: retained.token)?.signature, retained.signature)
    }

    func testOversizedDurableSidecarIsNotRetainedAboveMemoryBudget() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let data = validSidecarData(runtimeIDToken: "!runtime-0")
        let store = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: data.count - 1,
            countLimit: 1
        )
        let stored = try XCTUnwrap(store.insert(data))
        let fileURL = directoryURL.appendingPathComponent(stored.token)

        try Data("corrupt".utf8).write(to: fileURL, options: .atomic)

        XCTAssertNil(store.entry(for: stored.token))
    }

    func testCorruptDurableSidecarIsRejectedAndAtomicallyRegenerated() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let originalData = validSidecarData(runtimeIDToken: "!segment")
        let originalStore = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let stored = try XCTUnwrap(originalStore.insert(originalData))
        let fileURL = directoryURL.appendingPathComponent(stored.token)
        try Data("corrupt".utf8).write(to: fileURL, options: .atomic)

        let corruptedStore = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        XCTAssertNil(corruptedStore.entry(for: stored.token))

        XCTAssertEqual(try XCTUnwrap(corruptedStore.insert(originalData)).token, stored.token)
        let recreatedStore = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        XCTAssertEqual(recreatedStore.entry(for: stored.token)?.data, originalData)
    }

    func testPersistenceFailureKeepsCanonicalSidecarInlineWithoutAdvertisingURL() throws {
        let directoryURL = temporaryDirectoryURL()
        try Data("not a directory".utf8).write(to: directoryURL)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let data = validSidecarData(runtimeIDToken: "!runtime-0")
        let store = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: data.count,
            countLimit: 1
        )
        let result = externalizingReaderSegmentSidecar(
            documentHTML: Array("<html><body><m-m id=\"runtime-0\">猫</m-m></body></html>".utf8),
            canonicalSidecar: data,
            scheme: .internalReader,
            store: store
        )

        XCTAssertNil(store.insert(data))
        XCTAssertNil(result.endpointURL)
        XCTAssertNil(result.signature)
        XCTAssertTrue(String(decoding: result.documentHTML, as: UTF8.self).contains(
            #"id="mnb-segment-metadata""#
        ))
        XCTAssertTrue(ebookProcessedHTMLHasDurableSegmentIdentities(
            String(decoding: result.documentHTML, as: UTF8.self),
            store: store
        ))
    }

    func testInlinePersistenceFallbackEscapesScriptClosingContent() throws {
        let directoryURL = temporaryDirectoryURL()
        try Data("not a directory".utf8).write(to: directoryURL)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let data = Data(
            #"{"v":9,"t":{"j":[[1001]],"n":[],"s":["term"],"ns":[],"p":[],"h":["hash"],"x":["</script><m-m id=\"injected\">"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!runtime-0",0,0,null,0,null,null,null,0,0,0]]}"#.utf8
        )

        let result = externalizingReaderSegmentSidecar(
            documentHTML: Array("<html><body><m-m id=\"runtime-0\">猫</m-m></body></html>".utf8),
            canonicalSidecar: data,
            scheme: .internalReader,
            store: store
        )
        let html = String(decoding: result.documentHTML, as: UTF8.self)

        XCTAssertFalse(html.contains(#"</script><m-m id=\"injected\">"#))
        XCTAssertTrue(html.contains(#"\u003C/script>"#))
        XCTAssertTrue(ebookProcessedHTMLHasDurableSegmentIdentities(html, store: store))
    }

    func testStreamingPublicationFallsBackToInlineCanonicalSidecar() throws {
        let directoryURL = temporaryDirectoryURL()
        try Data("not a directory".utf8).write(to: directoryURL)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let payload = EbookProcessedSectionPayload(
            documentHTML: Data("<html><head></head><body><m-m id=\"runtime-0\">猫</m-m></body></html>".utf8),
            segmentSidecar: validSidecarData(runtimeIDToken: "!runtime-0")
        )

        let publication = publishingCanonicalReaderSegmentSidecar(
            payload,
            scheme: .ebook,
            store: store
        )
        let descriptor = try XCTUnwrap(publication.headDescriptor)
        let publishedHTML = ebookHTMLDataByInjectingHeadMarkup(
            descriptor,
            into: publication.documentHTML
        )

        XCTAssertNil(publication.endpointURL)
        XCTAssertNil(publication.signature)
        XCTAssertTrue(String(decoding: descriptor, as: UTF8.self).hasPrefix(
            #"<script id="mnb-segment-metadata""#
        ))
        XCTAssertTrue(ebookProcessedHTMLHasDurableSegmentIdentities(
            String(decoding: publishedHTML, as: UTF8.self),
            store: store
        ))
    }

    func testMissingExternalSidecarForcesProcessingRegeneration() async throws {
        let counter = SidecarProcessorInvocationCounter()
        let cachedPayload = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body><m-m id=\"runtime\">猫</m-m></body></html>".utf8),
            segmentSidecar: Data()
        )
        let regeneratedHTML = inlineHTML(sidecarData: validSidecarData(runtimeIDToken: "!runtime"))
        let regeneratedPayload = try XCTUnwrap(
            splitCanonicalReaderSegmentSidecar(from: Array(regeneratedHTML.utf8))
        )
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in cachedPayload },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                await counter.increment()
                return regeneratedPayload
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
        XCTAssertEqual(result.documentHTML, regeneratedPayload.documentHTML)
        XCTAssertEqual(result.segmentSidecar, regeneratedPayload.segmentSidecar)
        XCTAssertEqual(invocationCount, 1)
    }

    func testSchemaNineRequiresExplicitSentenceIdentityAndExactRuntimeMapping() {
        let validCloneSidecar = sidecarData(
            runtimeIDTokens: ["!runtime-0", "!runtime-1"],
            segmentHashIndexes: [0, 0],
            sentenceIdentifierIndexes: [0, 0],
            paragraphIdentifierIndexes: [0, 0]
        )
        let duplicateRuntimeSidecar = sidecarData(
            runtimeIDTokens: ["!runtime-0", "!runtime-0"],
            segmentHashIndexes: [0, 0],
            sentenceIdentifierIndexes: [0, 0],
            paragraphIdentifierIndexes: [0, 0]
        )
        let hashOnlySidecar = sidecarData(
            runtimeIDTokens: ["!runtime-0"],
            segmentHashIndexes: [0],
            sentenceIdentifierIndexes: [nil],
            paragraphIdentifierIndexes: [0]
        )
        let sentenceOnlySidecar = sidecarData(
            runtimeIDTokens: ["!runtime-0"],
            segmentHashIndexes: [0],
            sentenceIdentifierIndexes: [0],
            paragraphIdentifierIndexes: [nil]
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
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(
            inlineHTML(sidecarData: sentenceOnlySidecar)
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
            sentenceIdentifierIndexes: [0],
            paragraphIdentifierIndexes: [0]
        )
    }

    private func sidecarData(
        runtimeIDTokens: [String],
        segmentHashIndexes: [Int?],
        sentenceIdentifierIndexes: [Int?],
        paragraphIdentifierIndexes: [Int?]
    ) -> Data {
        let segments = zip(
            runtimeIDTokens,
            zip(segmentHashIndexes, zip(sentenceIdentifierIndexes, paragraphIdentifierIndexes))
        ).map { runtimeIDToken, indexes -> [Any] in
            let segmentHashIndex: Any = indexes.0.map { $0 as Any } ?? NSNull()
            let sentenceIdentifierIndex: Any = indexes.1.0.map { $0 as Any } ?? NSNull()
            let paragraphIdentifierIndex: Any = indexes.1.1.map { $0 as Any } ?? NSNull()
            return [
                runtimeIDToken,
                segmentHashIndex,
                NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(),
                sentenceIdentifierIndex,
                paragraphIdentifierIndex,
            ]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "v": 9,
            "t": [
                "j": [],
                "n": [],
                "s": [],
                "ns": [],
                "p": [],
                "h": ["segment-hash"],
                "sid": ["sentence-id"],
                "pid": ["paragraph-id"],
            ],
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
