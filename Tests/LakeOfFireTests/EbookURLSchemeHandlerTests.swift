import XCTest
import SwiftSoup
import ZIPFoundation
@preconcurrency import WebKit
@testable import LakeOfFireContent
@testable import LakeOfFireFiles
@testable import LakeOfFireReader

private final class EbookNavigationDelegate: NSObject, WKNavigationDelegate {
    let completionExpectation: XCTestExpectation
    private(set) var error: Error?

    init(completionExpectation: XCTestExpectation) {
        self.completionExpectation = completionExpectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completionExpectation.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        self.error = error
        completionExpectation.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        self.error = error
        completionExpectation.fulfill()
    }
}

private enum EbookJavaScriptProbeError: Error {
    case timedOut
}

private struct EbookJavaScriptProbeValue: @unchecked Sendable {
    let value: Any?
}

@MainActor
private final class EbookJavaScriptProbeCompletion {
    private var continuation: CheckedContinuation<EbookJavaScriptProbeValue, Error>?
    private var task: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<EbookJavaScriptProbeValue, Error>) {
        self.continuation = continuation
    }

    func install(task: Task<Void, Never>) {
        self.task = task
    }

    func resume(with result: Result<EbookJavaScriptProbeValue, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task?.cancel()
        task = nil
        continuation.resume(with: result)
    }
}

@MainActor
private func callEbookJavaScriptProbe(
    in webView: WKWebView,
    script: String,
    timeout: TimeInterval = 30
) async throws -> Any? {
    let result = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<EbookJavaScriptProbeValue, Error>) in
        let completion = EbookJavaScriptProbeCompletion(continuation)
        let task = Task { @MainActor in
            do {
                let result = try await webView.callAsyncJavaScript(
                    script,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                )
                completion.resume(with: .success(EbookJavaScriptProbeValue(value: result)))
            } catch {
                completion.resume(with: .failure(error))
            }
        }
        completion.install(task: task)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            completion.resume(with: .failure(EbookJavaScriptProbeError.timedOut))
        }
    }
    return result.value
}

private final class TestURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var responses: [URLResponse] = []
    private(set) var finishCount = 0
    private(set) var failures: [Error] = []

    init(request: URLRequest) {
        self.request = request
    }

    func didReceive(_ response: URLResponse) {
        responses.append(response)
    }

    func didReceive(_ data: Data) {}

    func didFinish() {
        finishCount += 1
    }

    func didFailWithError(_ error: Error) {
        failures.append(error)
    }
}

private func malformedURLRequest() -> URLRequest {
    var request = URLRequest(url: URL(string: "about:blank")!)
    request.url = nil
    return request
}

private actor EBookProcessorInvocationCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private final class SynchronousInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private actor EBookProcessingGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    func waitUntilReleased() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func isWaitingForRelease() -> Bool {
        isWaiting
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func ebookTestPayload(
    _ documentHTML: String,
    sidecar: String = "",
    isAuthoritativelyProcessed: Bool = true
) -> EbookProcessedSectionPayload {
    EbookProcessedSectionPayload(
        documentHTML: Data(documentHTML.utf8),
        segmentSidecar: Data(sidecar.utf8),
        isAuthoritativelyProcessed: isAuthoritativelyProcessed
    )
}

private let nestedResourceDocumentHTML = """
<!doctype html><html><head>
<link id="book-style" rel="stylesheet" href="../Styles/book.css#theme">
</head><body><m-s><m-m id="a">本文</m-m></m-s>
<img id="cover" src="../Images/cover.svg#shape">
<audio id="sample-audio" preload="metadata" src="../Media/tone.wav"></audio>
</body></html>
"""

private let nestedResourceStylesheet = """
body {
    background-color: rgb(1, 2, 3);
    writing-mode: vertical-rl;
}
"""

private let nestedResourceImage = """
<svg xmlns="http://www.w3.org/2000/svg" width="4" height="3">
<rect id="shape" width="4" height="3" fill="red"/>
</svg>
"""

private func nestedResourceAudio() -> Data {
    let sampleRate: UInt32 = 8_000
    let sampleCount = 800
    let dataByteCount = UInt32(sampleCount)
    var data = Data()

    func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { data.append(contentsOf: $0) }
    }

    data.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(UInt32(36) + dataByteCount)
    data.append(contentsOf: "WAVEfmt ".utf8)
    appendLittleEndian(UInt32(16))
    appendLittleEndian(UInt16(1))
    appendLittleEndian(UInt16(1))
    appendLittleEndian(sampleRate)
    appendLittleEndian(sampleRate)
    appendLittleEndian(UInt16(1))
    appendLittleEndian(UInt16(8))
    data.append(contentsOf: "data".utf8)
    appendLittleEndian(dataByteCount)
    data.append(contentsOf: repeatElement(UInt8(128), count: sampleCount))
    return data
}

final class EbookURLSchemeHandlerTests: XCTestCase {
    func testURLSchemeCompletionOwnershipKeepsHashCollisionsIndependent() {
        final class CollidingTask: NSObject {
            override var hash: Int { 1 }
        }
        let ownership = URLSchemeTaskCompletionOwnership()
        let first = CollidingTask()
        let second = CollidingTask()
        XCTAssertEqual(first.hash, second.hash)

        ownership.begin(first)
        ownership.begin(second)

        XCTAssertTrue(ownership.cancel(first))
        XCTAssertFalse(ownership.claimCompletion(first))
        XCTAssertTrue(ownership.claimCompletion(second))
    }

    func testURLSchemeCompletionOwnershipCancelsAttachedWorkExactlyOnce() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()
        let counter = SynchronousInvocationCounter()
        ownership.begin(task)
        XCTAssertTrue(ownership.attachCancellation(task) { counter.increment() })

        XCTAssertTrue(ownership.cancel(task))
        XCTAssertFalse(ownership.cancel(task))
        XCTAssertFalse(ownership.claimCompletion(task))
        XCTAssertEqual(counter.value(), 1)
    }

    func testURLSchemeCompletionOwnershipCancelsLateWorkAttachment() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()
        let counter = SynchronousInvocationCounter()
        ownership.begin(task)
        XCTAssertTrue(ownership.cancel(task))

        XCTAssertFalse(ownership.attachCancellation(task) { counter.increment() })
        XCTAssertEqual(counter.value(), 1)
    }

    @MainActor
    func testReaderFileHandlerTerminatesMalformedRequestExactlyOnce() {
        let handler = ReaderFileURLSchemeHandler()
        let task = TestURLSchemeTask(request: malformedURLRequest())

        handler.webView(WKWebView(), start: task)
        handler.webView(WKWebView(), stop: task)

        XCTAssertEqual(task.failures.count, 1)
        XCTAssertEqual(task.finishCount, 0)
        XCTAssertTrue(task.responses.isEmpty)
    }

    @MainActor
    func testEbookHandlerTerminatesMalformedRequestExactlyOnce() {
        let handler = EbookURLSchemeHandler()
        let task = TestURLSchemeTask(request: malformedURLRequest())

        handler.webView(WKWebView(), start: task)
        handler.webView(WKWebView(), stop: task)

        XCTAssertEqual(task.failures.count, 1)
        XCTAssertEqual(task.finishCount, 0)
        XCTAssertTrue(task.responses.isEmpty)
    }

    func testExternalizingTypedSidecarAvoidsEmbeddedJSONRoundTrip() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let canonicalJSON = #"{"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!a",0,null,null,null,null,null,null,null,0,0]]}"#
        let documentHTML = "<html><head></head><body><m-m>A</m-m></body></html>"

        let result = externalizingReaderSegmentSidecar(
            documentHTML: Array(documentHTML.utf8),
            canonicalSidecar: Data(canonicalJSON.utf8),
            scheme: .ebook,
            store: store
        )
        let output = String(decoding: result.documentHTML, as: UTF8.self)

        XCTAssertFalse(output.contains(canonicalJSON))
        XCTAssertTrue(output.contains("meta name=\"mnb-segment-sidecar\""))
        XCTAssertEqual(result.canonicalSidecarByteCount, canonicalJSON.utf8.count)
        XCTAssertTrue(ebookProcessedHTMLHasDurableSegmentIdentities(output, store: store))
        let endpoint = try XCTUnwrap(result.endpointURL.flatMap(URL.init(string:)))
        XCTAssertEqual(
            readerExternalSegmentSidecarResponse(for: endpoint, scheme: .ebook, store: store)?.data,
            Data(canonicalJSON.utf8)
        )
    }

    func testExternalizingTypedSidecarUsesStructuralHeadBoundaryAndPreservesDocumentBytes() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let documentHTML = """
        <!doctype html><HTML><HEAD><script>const marker = "</head>";</script></HEAD>\
        <BODY data-note='2>1'>本文</BODY></HTML>
        """

        let result = externalizingReaderSegmentSidecar(
            documentHTML: Array(documentHTML.utf8),
            canonicalSidecar: Data(#"{"v":9,"t":{},"s":[]}"#.utf8),
            scheme: .ebook,
            store: store
        )
        let endpointURL = try XCTUnwrap(result.endpointURL)
        let signature = try XCTUnwrap(result.signature)
        let descriptor = endpointURL.utf8
        let expectedDescriptor = """
        <meta name="mnb-segment-sidecar" content="\(endpointURL)" \
        data-mnb-segment-sidecar-signature="\(signature)">
        """
        let output = String(decoding: result.documentHTML, as: UTF8.self)

        XCTAssertTrue(output.contains("<HEAD><script>"))
        XCTAssertTrue(output.contains("</script><meta name=\"mnb-segment-sidecar\""))
        XCTAssertTrue(output.contains(String(decoding: descriptor, as: UTF8.self)))
        XCTAssertTrue(output.contains("</HEAD><BODY data-note='2>1'>本文</BODY></HTML>"))
        XCTAssertEqual(
            output.replacingOccurrences(
                of: expectedDescriptor,
                with: ""
            ),
            documentHTML
        )
    }

    func testExternalizingTypedSidecarReplacesExistingDescriptor() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let documentHTML = "<html><head><title>Test</title></head><body>本文</body></html>"
        let first = externalizingReaderSegmentSidecar(
            documentHTML: Array(documentHTML.utf8),
            canonicalSidecar: Data(#"{"v":9,"t":{},"s":[]}"#.utf8),
            scheme: .ebook,
            store: store
        )
        let second = externalizingReaderSegmentSidecar(
            documentHTML: Array(first.documentHTML),
            canonicalSidecar: Data(#"{"v":9,"t":{"sid":["replacement"]},"s":[]}"#.utf8),
            scheme: .ebook,
            store: store
        )
        let output = String(decoding: second.documentHTML, as: UTF8.self)

        XCTAssertEqual(output.components(separatedBy: "meta name=\"mnb-segment-sidecar\"").count - 1, 1)
        XCTAssertFalse(output.contains(try XCTUnwrap(first.endpointURL)))
        XCTAssertTrue(output.contains(try XCTUnwrap(second.endpointURL)))
        XCTAssertTrue(output.contains("<title>Test</title>"))
        XCTAssertTrue(output.contains("<body>本文</body>"))
    }

    func testDescriptorBackedCacheValidationRejectsMissingOrInvalidSidecar() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let documentHTML = "<html><head></head><body><m-m>A</m-m></body></html>"
        let invalidJSON = #"{"v":9,"t":{"sid":[]},"s":[["!a"]]}"#
        let invalid = externalizingReaderSegmentSidecar(
            documentHTML: Array(documentHTML.utf8),
            canonicalSidecar: Data(invalidJSON.utf8),
            scheme: .ebook,
            store: store
        )
        let invalidHTML = String(decoding: invalid.documentHTML, as: UTF8.self)
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(invalidHTML, store: store))

        let missingHTML = invalidHTML.replacingOccurrences(
            of: invalid.endpointURL ?? "",
            with: "ebook://ebook/processed-section-sidecar/" + String(repeating: "0", count: 64)
        )
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(missingHTML, store: store))
    }

    func testExternalizingCanonicalSidecarPublishesContentAddressedJSON() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let canonicalJSON = #"{"v":9,"t":{},"s":[]}"#
        let aggregateJSON = #"{"count":0}"#
        let html = """
        <html><head><title>Test</title></head><body>
        <script id="mnb-segment-metadata-aggregate">\(aggregateJSON)</script>
        <script id="mnb-segment-metadata" type="application/json">\(canonicalJSON)</script>
        </body></html>
        """

        let result = externalizingCanonicalReaderSegmentSidecar(
            in: Array(html.utf8),
            scheme: .ebook,
            store: store
        )
        let output = String(decoding: result.documentHTML, as: UTF8.self)

        XCTAssertFalse(output.contains("id=\"mnb-segment-metadata\""))
        XCTAssertTrue(output.contains("id=\"mnb-segment-metadata-aggregate\""))
        XCTAssertTrue(output.contains("meta name=\"mnb-segment-sidecar\""))
        XCTAssertLessThan(
            try XCTUnwrap(output.range(of: "meta name=\"mnb-segment-sidecar\"")?.lowerBound),
            try XCTUnwrap(output.range(of: "</head>")?.lowerBound)
        )
        XCTAssertEqual(result.canonicalSidecarByteCount, canonicalJSON.utf8.count)
        let endpoint = try XCTUnwrap(result.endpointURL.flatMap(URL.init(string:)))
        let served = try XCTUnwrap(readerExternalSegmentSidecarResponse(
            for: endpoint,
            scheme: .ebook,
            store: store
        ))
        XCTAssertEqual(served.data, Data(canonicalJSON.utf8))
        XCTAssertEqual(served.response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(
            served.response.value(forHTTPHeaderField: "X-Manabi-Sidecar-Signature"),
            result.signature
        )
    }

    func testExternalSidecarSurvivesMemoryEvictionAndStoreRestart() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let firstStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )
        let firstHTML = """
        <html><head></head><body>
        <script id="mnb-segment-metadata">{"v":9,"t":{},"s":[]}</script>
        </body></html>
        """
        let first = externalizingCanonicalReaderSegmentSidecar(
            in: Array(firstHTML.utf8),
            scheme: .ebook,
            store: firstStore
        )
        let endpoint = try XCTUnwrap(first.endpointURL.flatMap(URL.init(string:)))

        let secondHTML = """
        <html><body>
        <script id="mnb-segment-metadata">{"v":9,"t":{},"s":[["1"]]}</script>
        </body></html>
        """
        _ = externalizingCanonicalReaderSegmentSidecar(
            in: Array(secondHTML.utf8),
            scheme: .ebook,
            store: firstStore
        )
        XCTAssertNotNil(readerExternalSegmentSidecarResponse(
            for: endpoint,
            scheme: .ebook,
            store: firstStore
        ))

        let restartedStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )
        XCTAssertNotNil(readerExternalSegmentSidecarResponse(
            for: endpoint,
            scheme: .ebook,
            store: restartedStore
        ))
        let token = endpoint.lastPathComponent
        try Data("corrupt".utf8).write(to: directoryURL.appendingPathComponent(token), options: [.atomic])
        let corruptedStore = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        XCTAssertNil(readerExternalSegmentSidecarResponse(
            for: endpoint,
            scheme: .ebook,
            store: corruptedStore
        ))
        _ = externalizingCanonicalReaderSegmentSidecar(
            in: Array(firstHTML.utf8),
            scheme: .ebook,
            store: corruptedStore
        )
        XCTAssertNotNil(readerExternalSegmentSidecarResponse(
            for: endpoint,
            scheme: .ebook,
            store: corruptedStore
        ))
        XCTAssertNil(readerExternalSegmentSidecarResponse(
            for: URL(string: "ebook://ebook/processed-section-sidecar/not-a-token")!,
            scheme: .ebook,
            store: restartedStore
        ))
    }

    func testProcessTextResponseExternalizesOnlyCanonicalSidecar() throws {
        let canonicalJSON = #"{"v":9,"t":{},"s":[]}"#
        let html = """
        <html><head></head><body>
        <script id="mnb-segment-metadata">\(canonicalJSON)</script>
        </body></html>
        """

        let response = try XCTUnwrap(ebookProcessTextResponseData(
            processedText: html,
            isCacheWarmer: false
        ))
        let responseHTML = String(decoding: response, as: UTF8.self)

        XCTAssertFalse(responseHTML.contains("id=\"mnb-segment-metadata\""))
        XCTAssertTrue(responseHTML.contains("meta name=\"mnb-segment-sidecar\""))
        XCTAssertEqual(
            ebookProcessTextResponseData(processedText: html, isCacheWarmer: true),
            Data()
        )
    }

    func testProcessedHTMLCacheRequiresDurableIdentityForEveryGeneratedSegment() {
        let valid = """
        <html><body><m-m>A</m-m><m-m>B</m-m>
        <script id="mnb-segment-metadata" type="application/json">
        {"v":9,"t":{"h":["hash-a","hash-b"],"sid":["sentence-a","sentence-b"],"pid":["paragraph-a"]},"s":[["!a",0,null,null,null,null,null,null,null,0,0],["!b",1,null,null,null,null,null,null,null,1,0]]}
        </script></body></html>
        """
        let missingStableIdentity = """
        <html><body><m-m>A</m-m>
        <script id="mnb-segment-metadata" type="application/json">
        {"v":9,"t":{"sid":[]},"s":[["!a"]]}
        </script></body></html>
        """
        let incompleteCoverage = """
        <html><body><m-m>A</m-m><m-m>B</m-m>
        <script id="mnb-segment-metadata" type="application/json">
        {"v":9,"t":{"h":["hash-a"],"sid":["sentence-a"]},"s":[["!a",0,null,null,null,null,null,null,null,0]]}
        </script></body></html>
        """

        XCTAssertTrue(ebookProcessedHTMLHasDurableSegmentIdentities(valid))
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(missingStableIdentity))
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(incompleteCoverage))
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities("<m-m>A</m-m>"))
        XCTAssertTrue(ebookProcessedHTMLHasDurableSegmentIdentities("<mnb-segment-metadata></mnb-segment-metadata>"))
    }

    func testProcessedSectionEnvelopeRoundTripsSeparatedDocumentAndSidecar() throws {
        let payload = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body><m-m id=\"runtime\">猫</m-m></body></html>".utf8),
            segmentSidecar: Data(
                #"{"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!runtime",0,null,null,null,null,null,null,null,0,0]]}"#.utf8
            )
        )

        let encoded = encodedEbookProcessedSectionCacheValue(payload)
        let decoded = try XCTUnwrap(decodedEbookProcessedSectionCacheValue(encoded))

        XCTAssertEqual(decoded.documentHTML, payload.documentHTML)
        XCTAssertEqual(decoded.segmentSidecar, payload.segmentSidecar)
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(decoded))
    }

    func testRawFallbackWithoutGeneratedSegmentsIsNotDurableCacheAuthority() {
        let payload = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body>raw source</body></html>".utf8),
            segmentSidecar: Data(),
            isAuthoritativelyProcessed: false
        )

        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(payload))
    }

    func testEbookTextProcessorPropagatesCancellation() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))

        do {
            _ = try await ebookTextProcessor(
                contentURL: contentURL,
                sectionLocation: "item/xhtml/title.xhtml",
                content: "<html><body>Original</body></html>",
                contentFingerprint: "fingerprint",
                isCacheWarmer: false,
                processReadabilityContent: { _, _, _, _, _, _, _ in
                    throw CancellationError()
                },
                processHTMLDocument: nil,
                processHTMLBytes: nil,
                processHTML: nil
            )
            XCTFail("Cancellation must not become a successful raw section response")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testEbookTextProcessorRejectsSuccessfulResultAfterTaskCancellation() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))
        let task = Task {
            try await ebookTextProcessor(
                contentURL: contentURL,
                sectionLocation: "item/xhtml/title.xhtml",
                content: "<html><body>Original</body></html>",
                contentFingerprint: "fingerprint",
                isCacheWarmer: false,
                processReadabilityContent: { content, _, sectionURL, _, _, _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try SwiftSoup.parse(content, sectionURL?.absoluteString ?? "")
                },
                processHTMLDocument: nil,
                processHTMLBytes: nil,
                processHTML: nil
            )
        }

        do {
            _ = try await task.value
            XCTFail("Cancelled processing must not publish a successful document")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testEbookTextProcessorMarksRecoverableFallbackAsNonAuthoritative() async throws {
        enum ExpectedProcessingError: Error {
            case failed
        }
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))
        let originalText = "<html><body>Original</body></html>"

        let result = try await ebookTextProcessor(
            contentURL: contentURL,
            sectionLocation: "item/xhtml/title.xhtml",
            content: originalText,
            contentFingerprint: "fingerprint",
            isCacheWarmer: false,
            processReadabilityContent: { _, _, _, _, _, _, _ in
                throw ExpectedProcessingError.failed
            },
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), originalText)
        XCTAssertTrue(result.segmentSidecar.isEmpty)
        XCTAssertFalse(result.isAuthoritativelyProcessed)
    }

    func testProcessedSectionEnvelopeRejectsLegacyAndTruncatedValues() {
        let payload = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body>猫</body></html>".utf8),
            segmentSidecar: Data()
        )
        let encoded = encodedEbookProcessedSectionCacheValue(payload)
        var legacy = encoded
        legacy.replaceSubrange(0..<7, with: Array("MNBPSC2".utf8))

        XCTAssertNil(decodedEbookProcessedSectionCacheValue(legacy))
        XCTAssertNil(decodedEbookProcessedSectionCacheValue(Array(encoded.dropLast())))
    }

    func testProcessedSectionDurabilityRequiresExactV9SegmentCoverage() {
        let document = Data("<m-m id=\"a\">猫</m-m><m-m id=\"b\">犬</m-m>".utf8)
        let incomplete = EbookProcessedSectionPayload(
            documentHTML: document,
            segmentSidecar: Data(
                #"{"v":9,"t":{"h":["hash"],"sid":["sentence"]},"s":[["!a",0,null,null,null,null,null,null,null,0]]}"#.utf8
            )
        )
        let legacy = EbookProcessedSectionPayload(
            documentHTML: document,
            segmentSidecar: Data(
                #"{"v":3,"t":{"h":["hash"],"sid":["sentence"]},"s":[["!a",0,null,null,null,null,null,null,null,0],["!b",0,null,null,null,null,null,null,null,0]]}"#.utf8
            )
        )
        let duplicateRuntimeIdentifier = EbookProcessedSectionPayload(
            documentHTML: document,
            segmentSidecar: Data(
                #"{"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!a",0,null,null,null,null,null,null,null,0,0],["!a",0,null,null,null,null,null,null,null,0,0]]}"#.utf8
            )
        )
        let transitionalTenFieldTuple = EbookProcessedSectionPayload(
            documentHTML: Data("<m-m id=\"a\">猫</m-m>".utf8),
            segmentSidecar: Data(
                #"{"v":9,"t":{"h":["hash"],"sid":["sentence"]},"s":[["!a",0,null,null,null,null,null,null,null,0]]}"#.utf8
            )
        )
        let canonicalBareToken = EbookProcessedSectionPayload(
            documentHTML: Data("<m-m id=\"mnb-sAb09\">猫</m-m>".utf8),
            segmentSidecar: Data(
                #"""
                {"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},
                 "s":[["Ab09",0,null,null,null,null,null,null,null,0,0]]}
                """#.utf8
            )
        )

        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(incomplete))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(legacy))
        XCTAssertFalse(
            ebookProcessedSectionPayloadHasDurableSegmentIdentities(duplicateRuntimeIdentifier)
        )
        XCTAssertFalse(
            ebookProcessedSectionPayloadHasDurableSegmentIdentities(transitionalTenFieldTuple)
        )
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(canonicalBareToken))
    }

    func testProcessingRegeneratesCachedHTMLWithoutDurableSegmentIdentity() async throws {
        let cachedPayload = ebookTestPayload("<html><body><m-m>stale</m-m></body></html>")
        let regeneratedHTML = """
        <html><body><m-m>fresh</m-m>
        <script id="mnb-segment-metadata" type="application/json">
        {"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!fresh",0,null,null,null,null,null,null,null,0,0]]}
        </script></body></html>
        """
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in cachedPayload },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                ebookTestPayload(regeneratedHTML)
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: false
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), regeneratedHTML)
    }

    func testDirectSectionRequestPreservesUnicodeIdentityAndRejectsDuplicateOrUnsafeSubpaths() throws {
        var components = URLComponents()
        components.scheme = "ebook"
        components.host = "ebook"
        components.path = "/processed-section"
        components.queryItems = [
            URLQueryItem(name: "sourceURL", value: "ebook://ebook/load/local/Books/日本語.epub"),
            URLQueryItem(name: "subpath", value: "OPS/日本語/chapter 1.xhtml"),
            URLQueryItem(name: "direct", value: "1")
        ]
        let request = try XCTUnwrap(ebookDirectSectionRequest(from: try XCTUnwrap(components.url)))

        XCTAssertEqual(
            request.sourceURL.absoluteString,
            "ebook://ebook/load/local/Books/%E6%97%A5%E6%9C%AC%E8%AA%9E.epub"
        )
        XCTAssertEqual(request.subpath, "OPS/日本語/chapter 1.xhtml")

        components.queryItems?.append(URLQueryItem(name: "subpath", value: "OPS/other.xhtml"))
        XCTAssertNil(ebookDirectSectionRequest(from: try XCTUnwrap(components.url)))
        XCTAssertNil(normalizedEbookEntrySubpath("../secret.xhtml"))
        XCTAssertNil(normalizedEbookEntrySubpath("OPS/../secret.xhtml"))
        XCTAssertNil(normalizedEbookEntrySubpath("/OPS/chapter.xhtml"))
        XCTAssertNil(normalizedEbookEntrySubpath("OPS\\chapter.xhtml"))
    }

    func testEPubParserUsesTypedContainedPackageAndPrimaryNamespacedMetadata() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-metadata-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = temporaryRoot.appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot.appendingPathComponent("META-INF", isDirectory: true)
        let packageDirectory = packageRoot.appendingPathComponent("OPS/Text", isDirectory: true)
        let outsidePackageURL = temporaryRoot.appendingPathComponent("outside.opf")
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try Data("""
        <c:container xmlns:c="urn:oasis:names:tc:opendocument:xmlns:container">
          <c:rootfiles>
            <c:rootfile full-path="../outside.opf" media-type="application/x-other"/>
            <c:rootfile full-path="OPS/Text/package.opf"
                        media-type="application/oebps-package+xml"/>
          </c:rootfiles>
        </c:container>
        """.utf8).write(to: metadataDirectory.appendingPathComponent("container.xml"))
        try Data("""
        <pkg:package xmlns:pkg="http://www.idpf.org/2007/opf"
                     xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <pkg:metadata>
            <dc:title>Primary
              Title</dc:title>
            <dc:title>Secondary Title</dc:title>
            <dc:creator>Primary
              Author</dc:creator>
          </pkg:metadata>
          <pkg:manifest>
            <pkg:item id="cover" href="../Images/cover%20art.jpg"
                      media-type="image/jpeg" properties="other cover-image"/>
          </pkg:manifest>
        </pkg:package>
        """.utf8).write(to: packageDirectory.appendingPathComponent("package.opf"))
        try Data("""
        <package xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata><dc:title>Outside Book</dc:title></metadata>
          <manifest><item id="cover" href="outside.jpg" properties="cover-image"/></manifest>
        </package>
        """.utf8).write(to: outsidePackageURL)

        let metadata = try XCTUnwrap(EPubParser.parseMetadataAndCover(from: packageRoot))
        XCTAssertEqual(metadata.title, "Primary Title")
        XCTAssertEqual(metadata.author, "Primary Author")
        XCTAssertEqual(metadata.coverHref, "OPS/Images/cover art.jpg")
    }

    func testEPubParserKeepsCoverlessMetadataAndParsesReducedPublicationDates() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-coverless-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = temporaryRoot.appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot.appendingPathComponent("META-INF", isDirectory: true)
        let packageDirectory = packageRoot.appendingPathComponent("OPS", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OPS/package.opf"
            media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8).write(to: metadataDirectory.appendingPathComponent("container.xml"))

        let cases = [
            ("2024", 2024, 1, 1),
            ("2024-05", 2024, 5, 1),
            ("2024-05-12", 2024, 5, 12),
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for testCase in cases {
            try Data("""
            <package xmlns="http://www.idpf.org/2007/opf"
                     xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
              <metadata>
                <dc:title>Coverless Book</dc:title>
                <dc:creator>Metadata Author</dc:creator>
                <dc:date>\(testCase.0)</dc:date>
              </metadata>
              <manifest/>
            </package>
            """.utf8).write(to: packageDirectory.appendingPathComponent("package.opf"))

            let metadata = try XCTUnwrap(
                EPubParser.parseMetadataAndCover(from: packageRoot),
                "Failed to retain coverless metadata for \(testCase.0)"
            )
            XCTAssertEqual(metadata.title, "Coverless Book")
            XCTAssertEqual(metadata.author, "Metadata Author")
            XCTAssertNil(metadata.coverHref)
            let date = try XCTUnwrap(metadata.publicationDate)
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            XCTAssertEqual(components.year, testCase.1)
            XCTAssertEqual(components.month, testCase.2)
            XCTAssertEqual(components.day, testCase.3)
        }
    }

    func testEPubParserRejectsNestedRootfileAndMalformedContainerGraphs() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-invalid-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = temporaryRoot.appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot.appendingPathComponent("META-INF", isDirectory: true)
        let packageDirectory = packageRoot.appendingPathComponent("OPS", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let containerURL = metadataDirectory.appendingPathComponent("container.xml")

        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:x="urn:extension">
          <x:wrapper><rootfile full-path="OPS/package.opf"
            media-type="application/oebps-package+xml"/></x:wrapper>
        </container>
        """.utf8).write(to: containerURL)
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf"
                 xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <metadata><dc:title>Nested Rootfile</dc:title></metadata>
          <manifest><item id="cover" href="cover.jpg" properties="cover-image"/></manifest>
        </package>
        """.utf8).write(to: packageDirectory.appendingPathComponent("package.opf"))
        XCTAssertNil(
            try EPubParser.parseMetadataAndCover(from: packageRoot),
            "A nested rootfile must not become the package document"
        )

        try Data("""
        <container><rootfiles><rootfile full-path="OPS/package.opf"
          media-type="application/oebps-package+xml"/>
        """.utf8).write(to: containerURL)
        XCTAssertNil(
            try EPubParser.parseMetadataAndCover(from: packageRoot),
            "A rootfile discovered before malformed XML terminates must not be accepted"
        )
    }

    func testEPubParserReadsMetadataThroughArchiveEntrySource() throws {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-metadata-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let entries = [
            (
                "META-INF/container.xml",
                Data("""
                <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles><rootfile full-path="OPS/package.opf"
                    media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """.utf8)
            ),
            (
                "OPS/package.opf",
                Data("""
                <package xmlns="http://www.idpf.org/2007/opf"
                         xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
                  <metadata><dc:title>Archived Book</dc:title></metadata>
                  <manifest/>
                </package>
                """.utf8)
            ),
        ]
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }

        let metadata = try XCTUnwrap(EPubParser.parseMetadataAndCover(from: archiveURL))
        XCTAssertEqual(metadata.title, "Archived Book")
        XCTAssertNil(metadata.coverHref)
    }

    func testPathBackedEntryRequiresOwningProcessedDocumentSource() throws {
        let sourceURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))
        let token = ebookBase64URLToken(for: sourceURL.absoluteString)
        let generationID = "g1-" + String(repeating: "a", count: 64)
        let entryURL = try XCTUnwrap(URL(
            string: "ebook://ebook/entry-source/\(token)/\(generationID)/OPS/images/cover.jpg"
        ))
        var ownerComponents = URLComponents()
        ownerComponents.scheme = "ebook"
        ownerComponents.host = "ebook"
        ownerComponents.path = "/processed-section"
        ownerComponents.queryItems = [
            URLQueryItem(name: "sourceURL", value: sourceURL.absoluteString),
            URLQueryItem(name: "subpath", value: "OPS/chapter.xhtml")
        ]

        let request = try XCTUnwrap(ebookPathBackedEntryRequest(
            from: entryURL,
            mainDocumentURL: try XCTUnwrap(ownerComponents.url)
        ))
        XCTAssertEqual(request.sourceURL, sourceURL)
        XCTAssertEqual(request.generationID, generationID)
        XCTAssertEqual(request.subpath, "OPS/images/cover.jpg")

        XCTAssertNil(ebookPathBackedEntryRequest(
            from: try XCTUnwrap(URL(
                string: "ebook://ebook/entry-source/\(token)/OPS/images/cover.jpg"
            )),
            mainDocumentURL: try XCTUnwrap(ownerComponents.url)
        ))

        ownerComponents.queryItems = [
            URLQueryItem(name: "sourceURL", value: "ebook://ebook/load/local/Books/other.epub"),
            URLQueryItem(name: "subpath", value: "OPS/chapter.xhtml")
        ]
        XCTAssertNil(ebookPathBackedEntryRequest(
            from: entryURL,
            mainDocumentURL: try XCTUnwrap(ownerComponents.url)
        ))
        XCTAssertNil(ebookPathBackedEntryRequest(from: entryURL, mainDocumentURL: nil))
    }

    func testProcessedSectionBaseURLCarriesPackageGeneration() throws {
        let sourceURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))
        let generationID = "g1-" + String(repeating: "a", count: 64)

        let baseURL = ebookProcessedSectionBaseURL(
            sourceURL: sourceURL,
            sectionHref: "OPS/Text/chapter.xhtml",
            generationID: generationID
        )

        XCTAssertTrue(baseURL.contains("/\(generationID)/OPS/Text/"))
        XCTAssertFalse(baseURL.contains("chapter.xhtml"))
    }

    func testPackageEntrySourceGenerationChangesOnlyWhenPackageChanges() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-package-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let chapterURL = directoryURL.appendingPathComponent("chapter.xhtml")
        let newerAssetURL = directoryURL.appendingPathComponent("newer.css")
        try Data("first".utf8).write(to: chapterURL)
        try Data("newer".utf8).write(to: newerAssetURL)
        let baselineDate = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: baselineDate],
            ofItemAtPath: chapterURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: baselineDate.addingTimeInterval(20)],
            ofItemAtPath: newerAssetURL.path
        )

        var components = URLComponents()
        components.scheme = "ebook"
        components.host = "ebook"
        components.path = "/load/local/Books/test.epub"
        components.queryItems = [
            URLQueryItem(name: "diagnosticLocalFilePath", value: directoryURL.path),
        ]
        let packageURL = try XCTUnwrap(components.url)
        let cache = ReaderPackageEntrySourceCache()
        let readerFileManager = ReaderFileManager()

        let first = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        let unchanged = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        XCTAssertEqual(first.generationID, unchanged.generationID)

        try Data("other".utf8).write(to: chapterURL)
        try FileManager.default.setAttributes(
            [.modificationDate: baselineDate.addingTimeInterval(10)],
            ofItemAtPath: chapterURL.path
        )
        let changed = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        XCTAssertNotEqual(first.generationID, changed.generationID)
    }

    func testDirectSectionMetadataInjectionPreservesDocumentBytesAndInstallsPathBackedBase() throws {
        let html = """
        <!doctype html><HTML data-note='1>0'><HEAD><base href="old/"></HEAD><BODY class="book">
        <m-s><m-m>本文</m-m></m-s></BODY></HTML>
        """
        let result = ebookHTMLWithInjectedDirectSectionMetadata(
            html,
            baseURL: "ebook://ebook/entry-source/token/OPS/",
            sourceHref: "OPS/chapter.xhtml"
        )

        XCTAssertTrue(result.contains(
            "<HEAD><base href=\"ebook://ebook/entry-source/token/OPS/\"><base href=\"old/\">"
        ))
        let body = try XCTUnwrap(SwiftSoup.parse(result).body())
        XCTAssertEqual(try body.attr("class"), "book")
        XCTAssertEqual(try body.attr("data-mnb-source-href"), "OPS/chapter.xhtml")
        XCTAssertEqual(try body.attr("data-mnb-has-sentences"), "true")
        XCTAssertEqual(try body.attr("data-mnb-has-segments"), "true")
        XCTAssertEqual(try body.select("m-s > m-m").text(), "本文")

        XCTAssertEqual(
            ebookHTMLWithInjectedDirectSectionMetadata(
                "<section>fragment</section>",
                baseURL: "ebook://ebook/entry-source/token/",
                sourceHref: "chapter.xhtml"
            ),
            "<!doctype html><html><head><base href=\"ebook://ebook/entry-source/token/\">"
                + "<style id=\"mnb-paginator-layout-bootstrap\">html{display:none!important}</style></head>"
                + "<body data-mnb-source-href=\"chapter.xhtml\"><section>fragment</section></body></html>"
        )
    }

    func testResponseMetadataByteInjectionDecoratesUppercaseDocumentWithoutReserializingContent() {
        let html = "<!doctype html><HTML><HEAD><title>T</title></HEAD><BODY class=\"book\"><p>本文</p></BODY></HTML>"
        let result = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            Data(html.utf8),
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml?x=1&y=2",
            writingHint: EBookProcessedSectionWritingHint(
                direction: "vertical",
                writingMode: "vertical-rl"
            ),
            bodyAttributes: ["data-mnb-native-cache-outcome": "final-direct-hit"]
        ), as: UTF8.self)

        XCTAssertTrue(result.contains(
            "<HEAD><base href=\"ebook://ebook/entry-source/token/chapter.xhtml?x=1&amp;y=2\">"
        ))
        XCTAssertTrue(result.contains("<BODY class=\"book\""))
        XCTAssertTrue(result.contains("data-mnb-native-cache-outcome=\"final-direct-hit\""))
        XCTAssertTrue(result.contains("data-mnb-writing-direction=\"vertical\""))
        XCTAssertTrue(result.contains("data-mnb-writing-mode=\"vertical-rl\""))
        XCTAssertTrue(result.contains("<p>本文</p>"))
    }

    func testResponseMetadataByteInjectionWrapsHTMLFragment() {
        let result = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            Data("<section>本文</section>".utf8),
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
            writingHint: nil,
            bodyAttributes: ["data-test": "ok"]
        ), as: UTF8.self)

        XCTAssertEqual(
            result,
            "<!doctype html><html><head><base href=\"ebook://ebook/entry-source/token/chapter.xhtml\">"
                + "</head><body data-test=\"ok\"><section>本文</section></body></html>"
        )
    }

    func testResponseMetadataScannerHandlesGreaterThanInsideQuotedAttributesAndInjectsPresentation() {
        let html = """
        <HTML data-note='1>0'><HEAD data-note="2>1"></HEAD>\
        <BODY data-note='3>2' style='color:red'>本文</BODY></HTML>
        """
        let result = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            Data(html.utf8),
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
            writingHint: nil,
            bodyAttributes: ["data-response": "ready"],
            presentation: EbookSectionPresentation(
                revision: "presentation-1",
                bodyAttributes: ["data-mnb-dark-theme": "current"],
                bodyStyleProperties: [
                    "font-family": "'not allowlisted'",
                    "font-size": "18px",
                ]
            )
        ), as: UTF8.self)

        XCTAssertTrue(result.contains("<HEAD data-note=\"2>1\"><base href="))
        XCTAssertTrue(result.contains(
            "<BODY data-note='3>2' style='color:red;font-size:18px!important;' "
                + "data-mnb-dark-theme=\"current\" data-mnb-presentation-revision=\"presentation-1\" "
                + "data-mnb-presentation-schema-version=\"1\" data-response=\"ready\">"
        ))
    }

    func testResponseMetadataScannerIgnoresCommentAndRawTextTagLookalikes() {
        let html = """
        <!-- <html><head><body>comment lookalikes</body></head></html> -->
        <HTML><HEAD><script>const fake = "<body data-fake='true'>";</script></HEAD>\
        <BODY data-publisher="kept">本文</BODY></HTML>
        """
        let result = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            Data(html.utf8),
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
            writingHint: nil,
            bodyAttributes: ["data-response": "ready"]
        ), as: UTF8.self)

        XCTAssertTrue(result.hasPrefix("<!-- <html><head><body>"))
        XCTAssertTrue(result.contains(
            "<HTML><HEAD><base href=\"ebook://ebook/entry-source/token/chapter.xhtml\">"
                + "<script>const fake = \"<body data-fake='true'>\";</script></HEAD>"
        ))
        XCTAssertTrue(result.contains(
            "<BODY data-publisher=\"kept\" data-response=\"ready\">本文</BODY>"
        ))
        XCTAssertEqual(result.components(separatedBy: "data-response=").count - 1, 1)
    }

    func testResponseMetadataPreservesNonUTF8DocumentBytesOutsideInsertions() {
        var html = Data("<html><head></head><body>".utf8)
        html.append(contentsOf: [0x80, 0xFF])
        html.append(contentsOf: "</body></html>".utf8)
        let result = ebookHTMLDataWithInjectedResponseMetadata(
            html,
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
            writingHint: nil,
            bodyAttributes: ["data-response": "ready"]
        )
        var expected = Data(
            """
            <html><head><base href="ebook://ebook/entry-source/token/chapter.xhtml"></head>\
            <body data-response="ready">
            """.utf8
        )
        expected.append(contentsOf: [0x80, 0xFF])
        expected.append(contentsOf: "</body></html>".utf8)

        XCTAssertEqual(result, expected)
    }

    func testResponseMetadataReplacesManagedPresentationAttributesAndPublishesSidecarInHead() {
        let html = """
        <html><head></head><body data-mnb-dark-theme="stale" \
        data-mnb-settings-initialized="false" data-publisher="kept" \
        style="color:red;font-size:9px">Text</body></html>
        """
        let sidecarDescriptor = Data(
            #"<meta name="mnb-segment-sidecar" content="ebook://ebook/processed-section-sidecar/token">"#.utf8
        )
        let result = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            Data(html.utf8),
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
            writingHint: nil,
            bodyAttributes: [:],
            presentation: EbookSectionPresentation(
                revision: "presentation-2",
                bodyAttributes: [
                    "data-mnb-dark-theme": "current",
                    "data-mnb-settings-initialized": "true",
                    "data-publisher": "not-allowlisted",
                ],
                bodyStyleProperties: [
                    "font-size": "18px",
                    "background": "red",
                    "font-weight": "600;display:none",
                ]
            ),
            additionalHeadMarkup: sidecarDescriptor
        ), as: UTF8.self)

        XCTAssertEqual(result.components(separatedBy: "data-mnb-dark-theme=").count - 1, 1)
        XCTAssertEqual(result.components(separatedBy: "data-mnb-settings-initialized=").count - 1, 1)
        XCTAssertTrue(result.contains("<head><base href="))
        XCTAssertTrue(result.contains(String(decoding: sidecarDescriptor, as: UTF8.self)))
        XCTAssertTrue(result.contains("data-mnb-dark-theme=\"current\""))
        XCTAssertTrue(result.contains("data-mnb-settings-initialized=\"true\""))
        XCTAssertTrue(result.contains("data-mnb-presentation-schema-version=\"1\""))
        XCTAssertTrue(result.contains("data-mnb-presentation-revision=\"presentation-2\""))
        XCTAssertTrue(result.contains("data-publisher=\"kept\""))
        XCTAssertFalse(result.contains("not-allowlisted"))
        XCTAssertTrue(result.contains("style=\"color:red;font-size:18px!important;\""))
        XCTAssertFalse(result.contains("background:red"))
        XCTAssertFalse(result.contains("display:none"))
    }

    func testDirectSectionPresentationHintInjectionPreservesProcessedDocument() throws {
        let html = "<html><head></head><body data-note=\"2 > 1\" class=\"book\"><m-m>本文</m-m></body></html>"
        let result = ebookHTMLWithInjectedPresentationHints(
            html,
            writingHint: EBookProcessedSectionWritingHint(
                direction: "vertical",
                writingMode: "vertical-lr"
            )
        )
        let body = try XCTUnwrap(SwiftSoup.parse(result).body())

        XCTAssertEqual(try body.attr("data-note"), "2 > 1")
        XCTAssertEqual(try body.attr("class"), "book")
        XCTAssertEqual(try body.attr("data-mnb-writing-direction"), "vertical")
        XCTAssertEqual(try body.attr("data-mnb-writing-mode"), "vertical-lr")
        XCTAssertEqual(try body.attr("data-mnb-foliate-writing-direction"), "vertical")
        XCTAssertEqual(try body.attr("data-mnb-foliate-writing-mode"), "vertical-lr")
        XCTAssertEqual(try body.select("m-m").text(), "本文")
    }

    func testDirectSectionWritingHintRequiresOneCompleteNormalizedPair() throws {
        let accepted = try XCTUnwrap(URL(string:
            "ebook://ebook/processed-section?mnbWritingDirection=vertical&mnbWritingMode=vertical-lr"
        ))
        let acceptedHint = try XCTUnwrap(ebookProcessedSectionWritingHint(from: accepted))
        XCTAssertEqual(acceptedHint.direction, "vertical")
        XCTAssertEqual(acceptedHint.writingMode, "vertical-lr")

        let rejectedURLs = [
            "ebook://ebook/processed-section?mnbWritingDirection=vertical",
            "ebook://ebook/processed-section?mnbWritingDirection=horizontal&mnbWritingMode=horizontal-tb",
            "ebook://ebook/processed-section?mnbWritingDirection=vertical&mnbWritingMode=sideways-rl",
            "ebook://ebook/processed-section?mnbWritingDirection=vertical&mnbWritingDirection=vertical&mnbWritingMode=vertical-rl"
        ]
        for rawURL in rejectedURLs {
            XCTAssertNil(ebookProcessedSectionWritingHint(from: try XCTUnwrap(URL(string: rawURL))))
        }
    }

    func testSectionPresentationReplacesStaleCachedSettingsAndRejectsUnknownFields() throws {
        let html = """
        <html><body data-mnb-romaji-mode-enabled="false" data-unknown="preserved"
        style='font-size:12px;color:red'>本文</body></html>
        """
        let result = ebookHTMLApplyingSectionPresentation(
            html,
            presentation: EbookSectionPresentation(
                revision: "ABC123",
                bodyAttributes: [
                    "data-mnb-romaji-mode-enabled": "true",
                    "data-mnb-settings-initialized": "true",
                    "data-not-allowlisted": "rejected"
                ],
                bodyStyleProperties: [
                    "font-size": "24px",
                    "font-weight": "600",
                    "--mnb-content-font": "'YuKyokasho Yoko', 'YuKyokasho'",
                    "position": "fixed"
                ]
            )
        )
        let body = try XCTUnwrap(SwiftSoup.parse(result).body())

        XCTAssertEqual(try body.attr("data-mnb-romaji-mode-enabled"), "true")
        XCTAssertEqual(try body.attr("data-mnb-settings-initialized"), "true")
        XCTAssertEqual(try body.attr("data-mnb-presentation-schema-version"), "1")
        XCTAssertEqual(try body.attr("data-mnb-presentation-revision"), "ABC123")
        XCTAssertEqual(try body.attr("data-unknown"), "preserved")
        XCTAssertFalse(body.hasAttr("data-not-allowlisted"))
        let style = try body.attr("style")
        XCTAssertTrue(style.contains("color:red"))
        XCTAssertTrue(style.contains("font-size:24px!important"))
        XCTAssertTrue(style.contains("font-weight:600!important"))
        XCTAssertTrue(style.contains("--mnb-content-font:'YuKyokasho Yoko', 'YuKyokasho'!important"))
        XCTAssertFalse(style.contains("position:fixed"))
        XCTAssertEqual(result.components(separatedBy: "data-mnb-romaji-mode-enabled=").count - 1, 1)
        XCTAssertEqual(result.components(separatedBy: "font-size:24px!important").count - 1, 1)
        XCTAssertEqual(
            ebookHTMLApplyingSectionPresentation(result, presentation: EbookSectionPresentation(
                revision: "ABC123",
                bodyAttributes: ["data-mnb-romaji-mode-enabled": "true"],
                bodyStyleProperties: ["font-size": "24px"]
            )).components(separatedBy: "font-size:24px!important").count - 1,
            1
        )
    }

    func testEbookSchemeTaskPriorityKeepsOnlyDirectSectionLoadsForeground() throws {
        let foregroundURLs = [
            "ebook://ebook/load/local/Books/test.epub",
            "ebook://ebook/load/viewer-assets/foliate-js/paginator.js",
            "ebook://ebook/processed-section?subpath=chapter.xhtml&direct=1",
        ]
        let utilityURLs = [
            "ebook://ebook/processed-section?subpath=chapter.xhtml",
            "ebook://ebook/processed-section?subpath=chapter.xhtml&direct=0",
            "ebook://ebook/processed-section?subpath=chapter.xhtml&direct=true",
            "ebook://ebook/processed-section?subpath=chapter.xhtml&direct=1&direct=1",
            "ebook://ebook/processed-section?subpath=chapter.xhtml&direct",
        ]

        for rawURL in foregroundURLs {
            XCTAssertEqual(
                ebookURLSchemeTaskPriority(for: try XCTUnwrap(URL(string: rawURL))),
                .userInitiated,
                rawURL
            )
        }
        for rawURL in utilityURLs {
            XCTAssertEqual(
                ebookURLSchemeTaskPriority(for: try XCTUnwrap(URL(string: rawURL))),
                .utility,
                rawURL
            )
        }
    }

    func testEbookViewerAssetCacheReadsEachResolvedBundleURLOnce() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let firstURL = directoryURL.appendingPathComponent("first.js")
        let secondURL = directoryURL.appendingPathComponent("second.css")
        try Data("first-revision".utf8).write(to: firstURL)
        try Data("second-asset".utf8).write(to: secondURL)
        let cache = EbookViewerAssetCache()

        let firstRead = try await cache.data(for: firstURL)
        XCTAssertEqual(firstRead, Data("first-revision".utf8))
        try Data("changed-on-disk".utf8).write(to: firstURL)

        let cachedRead = try await cache.data(for: firstURL)
        let secondRead = try await cache.data(for: secondURL)
        XCTAssertEqual(cachedRead, Data("first-revision".utf8))
        XCTAssertEqual(secondRead, Data("second-asset".utf8))
    }

    func testEbookViewerAssetCacheCoalescesConcurrentReads() async throws {
        let fileURL = URL(fileURLWithPath: "/bundle/foliate-js/ebook-viewer.js")
        let expectedData = Data("viewer-module".utf8)
        let invocationCounter = SynchronousInvocationCounter()
        let cache = EbookViewerAssetCache { requestedURL in
            XCTAssertEqual(requestedURL, fileURL)
            invocationCounter.increment()
            return expectedData
        }

        let values = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await cache.data(for: fileURL)
                }
            }
            var values = [Data]()
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(values, Array(repeating: expectedData, count: 32))
        XCTAssertEqual(invocationCounter.value(), 1)
    }

    func testEbookViewerHTMLUsesOneRevisionForPreloadAndModuleExecution() throws {
        let html = """
        <html>
        <head>
        <link rel="modulepreload" href="/load/viewer-assets/__MNB_VIEWER_ASSET_REVISION__/foliate-js/ebook-viewer.js">
        </head>
        <body>
        <script src="/load/viewer-assets/__MNB_VIEWER_ASSET_REVISION__/foliate-js/ebook-viewer.js" type="module"></script>
        </body>
        </html>
        """

        let revisedHTML = try ebookViewerHTMLApplyingAssetRevision(html, revision: "v1-abc123")

        XCTAssertFalse(revisedHTML.contains("__MNB_VIEWER_ASSET_REVISION__"))
        XCTAssertEqual(
            revisedHTML.components(
                separatedBy: "/load/viewer-assets/v1-abc123/foliate-js/ebook-viewer.js"
            ).count - 1,
            2
        )
    }

    func testEbookViewerAssetPathRequiresCurrentRevisionAndSafeComponents() throws {
        let currentURL = try XCTUnwrap(URL(
            string: "ebook://ebook/load/viewer-assets/v1-current/foliate-js/ui/tree.js"
        ))
        XCTAssertEqual(
            ebookViewerAssetRelativePath(from: currentURL, activeRevision: "v1-current"),
            "foliate-js/ui/tree.js"
        )

        let rejectedURLs = [
            "ebook://ebook/load/viewer-assets/foliate-js/ui/tree.js",
            "ebook://ebook/load/viewer-assets/v1-stale/foliate-js/ui/tree.js",
            "ebook://ebook/load/viewer-assets/v1-current/foliate-js/%2E%2E/secret.js",
            "ebook://ebook/load/viewer-assets/v1-current/foliate-js/%5Csecret.js",
            "ebook://ebook/load/viewer-assets/v1-current/",
        ]
        for rawURL in rejectedURLs {
            XCTAssertNil(
                ebookViewerAssetRelativePath(
                    from: try XCTUnwrap(URL(string: rawURL)),
                    activeRevision: "v1-current"
                ),
                rawURL
            )
        }
    }

    func testEbookViewerBundledResourceResolverUsesPackagedAssets() throws {
        let viewerURL = try XCTUnwrap(
            ebookViewerBundledResourceURL(relativePath: "foliate-js/ebook-viewer.html")
        )
        let moduleURL = try XCTUnwrap(
            ebookViewerBundledResourceURL(relativePath: "foliate-js/ebook-viewer.js")
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: viewerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moduleURL.path))
        XCTAssertNil(
            ebookViewerBundledResourceURL(relativePath: "foliate-js/../Package.swift")
        )
        XCTAssertNil(
            ebookViewerBundledResourceURL(relativePath: "/foliate-js/ebook-viewer.html")
        )
    }

    func testEbookViewerAssetRevisionChangesWithApplicationBuild() {
        let firstRevision = ebookViewerAssetRevision(
            applicationIdentifier: "com.example.reader",
            applicationVersion: "3.0",
            applicationBuild: "100",
            resourceSchemaVersion: 1
        )
        let nextBuildRevision = ebookViewerAssetRevision(
            applicationIdentifier: "com.example.reader",
            applicationVersion: "3.0",
            applicationBuild: "101",
            resourceSchemaVersion: 1
        )

        XCTAssertNotEqual(firstRevision, nextBuildRevision)
        XCTAssertTrue(firstRevision.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    }

    func testEbookBundleResourceResponseUsesImmutableCachingForRevisionedURL() throws {
        let response = ebookHTTPResponse(
            url: URL(string: "ebook://ebook/load/viewer-assets/v1-current/ebook-viewer.js")!,
            mimeType: "text/javascript",
            byteCount: 123,
            textEncodingName: "utf-8",
            additionalHeaderFields: ebookViewerAssetCacheHeaderFields
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/javascript; charset=utf-8")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "123")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "public, max-age=31536000, immutable")
        XCTAssertNil(response.value(forHTTPHeaderField: "Pragma"))
        XCTAssertNil(response.value(forHTTPHeaderField: "Expires"))
    }

    func testPackageEntryResponseCachesOnlyGenerationBackedResources() throws {
        let url = try XCTUnwrap(URL(
            string: "ebook://ebook/entry-source/token/g1-\(String(repeating: "a", count: 64))/image.jpg"
        ))

        let generationBacked = ebookPackageEntryResponse(
            url: url,
            metadata: ReaderPackageEntryResponseMetadata(
                mimeType: "image/jpeg",
                textEncodingName: nil
            ),
            byteCount: 10,
            isGenerationBacked: true
        )
        let queryBacked = ebookPackageEntryResponse(
            url: url,
            metadata: ReaderPackageEntryResponseMetadata(
                mimeType: "image/jpeg",
                textEncodingName: nil
            ),
            byteCount: 10,
            isGenerationBacked: false
        )

        XCTAssertEqual(
            generationBacked.value(forHTTPHeaderField: "Cache-Control"),
            "public, max-age=31536000, immutable"
        )
        XCTAssertEqual(queryBacked.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    @MainActor
    func testProcessedSectionLoadsDirectoryBackedNestedResourcesInWebKit() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-webkit-package-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let textDirectoryURL = directoryURL.appendingPathComponent("OPS/Text", isDirectory: true)
        let stylesDirectoryURL = directoryURL.appendingPathComponent("OPS/Styles", isDirectory: true)
        let imagesDirectoryURL = directoryURL.appendingPathComponent("OPS/Images", isDirectory: true)
        let mediaDirectoryURL = directoryURL.appendingPathComponent("OPS/Media", isDirectory: true)
        try FileManager.default.createDirectory(at: textDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stylesDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaDirectoryURL, withIntermediateDirectories: true)

        try Data(nestedResourceDocumentHTML.utf8).write(
            to: textDirectoryURL.appendingPathComponent("chapter.xhtml")
        )
        try Data(nestedResourceStylesheet.utf8).write(
            to: stylesDirectoryURL.appendingPathComponent("book.css")
        )
        try Data(nestedResourceImage.utf8).write(
            to: imagesDirectoryURL.appendingPathComponent("cover.svg")
        )
        try nestedResourceAudio().write(
            to: mediaDirectoryURL.appendingPathComponent("tone.wav")
        )

        try await assertProcessedSectionLoadsNestedResources(
            from: diagnosticPackageURL(localURL: directoryURL)
        )
    }

    @MainActor
    func testProcessedSectionLoadsArchiveBackedNestedResourcesInWebKit() async throws {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-webkit-package-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let entries = [
            ("OPS/Text/chapter.xhtml", Data(nestedResourceDocumentHTML.utf8)),
            ("OPS/Styles/book.css", Data(nestedResourceStylesheet.utf8)),
            ("OPS/Images/cover.svg", Data(nestedResourceImage.utf8)),
            ("OPS/Media/tone.wav", nestedResourceAudio()),
        ]
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for entry in entries {
            try archive.addEntry(
                with: entry.0,
                type: .file,
                uncompressedSize: Int64(entry.1.count),
                compressionMethod: .deflate
            ) { position, size in
                entry.1.subdata(in: Int(position)..<(Int(position) + size))
            }
        }

        try await assertProcessedSectionLoadsNestedResources(
            from: diagnosticPackageURL(localURL: archiveURL)
        )
    }

    private func diagnosticPackageURL(localURL: URL) throws -> URL {
        var sourceComponents = URLComponents()
        sourceComponents.scheme = "ebook"
        sourceComponents.host = "ebook"
        sourceComponents.path = "/load/local/Books/test.epub"
        sourceComponents.queryItems = [
            URLQueryItem(name: "diagnosticLocalFilePath", value: localURL.path),
        ]
        return try XCTUnwrap(sourceComponents.url)
    }

    @MainActor
    private func assertProcessedSectionLoadsNestedResources(from sourceURL: URL) async throws {
        var sectionComponents = URLComponents()
        sectionComponents.scheme = "ebook"
        sectionComponents.host = "ebook"
        sectionComponents.path = "/processed-section"
        sectionComponents.queryItems = [
            URLQueryItem(name: "sourceURL", value: sourceURL.absoluteString),
            URLQueryItem(name: "subpath", value: "OPS/Text/chapter.xhtml"),
            URLQueryItem(name: "direct", value: "1"),
        ]
        let sectionURL = try XCTUnwrap(sectionComponents.url)
        let sidecar = """
        {"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},\
        "s":[["!a",0,null,null,null,null,null,null,null,0,0]]}
        """

        let processorInvocationCounter = EBookProcessorInvocationCounter()
        let handler = EbookURLSchemeHandler()
        handler.readerFileManager = ReaderFileManager()
        handler.ebookTextProcessor = { _, _, text, _, _, _, _, _, _ in
            _ = await processorInvocationCounter.increment()
            return ebookTestPayload(text, sidecar: sidecar)
        }
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.setURLSchemeHandler(handler, forURLScheme: "ebook")
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: configuration
        )
        let completionExpectation = expectation(description: "processed section loaded")
        let navigationDelegate = EbookNavigationDelegate(
            completionExpectation: completionExpectation
        )
        webView.navigationDelegate = navigationDelegate

        webView.load(URLRequest(url: sectionURL))
        await fulfillment(of: [completionExpectation], timeout: 10)
        XCTAssertNil(navigationDelegate.error)

        let readyState = try await callEbookJavaScriptProbe(
            in: webView,
            script:
            """
            if (document.readyState !== "complete") {
                await new Promise(resolve => {
                    addEventListener("load", resolve, { once: true });
                });
            }
            return document.readyState;
            """,
            timeout: 5
        )
        XCTAssertEqual(readyState as? String, "complete")

        let result = try await callEbookJavaScriptProbe(
            in: webView,
            script:
            """
            const withTimeout = (label, operation, milliseconds = 2000) => Promise.race([
                Promise.resolve(operation),
                new Promise((_, reject) => setTimeout(
                    () => reject(new Error(`${label}-timeout`)),
                    milliseconds
                )),
            ]);
            document.getElementById("mnb-paginator-layout-bootstrap")?.remove();
            void document.documentElement.offsetWidth;
            const image = document.getElementById("cover");
            const audio = document.getElementById("sample-audio");
            const mediaBootstrap = document.querySelector('script[src*="ebook-package-media.js"]');
            const mediaBootstrapStatus = mediaBootstrap
                ? await withTimeout(
                    "media-bootstrap-fetch",
                    fetch(mediaBootstrap.src).then(response => response.status)
                )
                : null;
            let mediaBootstrapError = null;
            try {
                await withTimeout(
                    "media-bootstrap-hydration",
                    globalThis.manabiEbookPackageMediaHydration
                );
            } catch (error) {
                mediaBootstrapError = String(error);
            }
            const fetchedAudioResponse = await withTimeout(
                "audio-fetch",
                fetch("../Media/tone.wav")
            );
            const fetchedAudioBlob = await withTimeout(
                "audio-blob",
                fetchedAudioResponse.blob()
            );
            const missingStatus = await withTimeout(
                "missing-resource-fetch",
                fetch("../Styles/missing.css").then(response => response.status)
            );
            return {
                baseURL: document.baseURI,
                backgroundColor: getComputedStyle(document.body).backgroundColor,
                stylesheetURL: document.getElementById("book-style").href,
                imageComplete: image.complete,
                imageURL: image.src,
                imageWidth: image.naturalWidth,
                audioURL: audio.src,
                fetchedAudioByteCount: fetchedAudioBlob.size,
                fetchedAudioType: fetchedAudioBlob.type,
                mediaBootstrapError,
                mediaBootstrapState: document.documentElement.dataset.mnbPackageMediaState ?? null,
                mediaBootstrapStatus,
                mediaBootstrapURL: mediaBootstrap?.src ?? null,
                missingStatus,
                bodyText: document.body.textContent.trim(),
            };
            """
        )
        let values = try XCTUnwrap(result as? [String: Any])
        let baseURL = try XCTUnwrap(values["baseURL"] as? String)
        XCTAssertTrue(baseURL.contains("/entry-source/"))
        XCTAssertTrue(baseURL.contains("/g1-"))
        XCTAssertEqual(values["backgroundColor"] as? String, "rgb(1, 2, 3)")
        XCTAssertTrue((values["stylesheetURL"] as? String)?.hasSuffix("/OPS/Styles/book.css#theme") == true)
        XCTAssertEqual(values["imageComplete"] as? Bool, true)
        XCTAssertTrue((values["imageURL"] as? String)?.hasSuffix("/OPS/Images/cover.svg#shape") == true)
        XCTAssertEqual((values["imageWidth"] as? NSNumber)?.intValue, 4)
        XCTAssertTrue((values["audioURL"] as? String)?.hasPrefix("blob:") == true)
        XCTAssertEqual((values["fetchedAudioByteCount"] as? NSNumber)?.intValue, 844)
        XCTAssertTrue((values["fetchedAudioType"] as? String)?.hasPrefix("audio/") == true)
        XCTAssertTrue(values["mediaBootstrapError"] is NSNull)
        XCTAssertEqual(values["mediaBootstrapState"] as? String, "ready")
        XCTAssertEqual((values["mediaBootstrapStatus"] as? NSNumber)?.intValue, 200)
        XCTAssertTrue((values["mediaBootstrapURL"] as? String)?.contains("/load/viewer-assets/") == true)
        XCTAssertEqual((values["missingStatus"] as? NSNumber)?.intValue, 404)
        XCTAssertEqual(values["bodyText"] as? String, "本文")
        let processorInvocationCount = await processorInvocationCounter.value()
        XCTAssertEqual(processorInvocationCount, 1)
    }

    func testMissingViewerAssetReturns404InsteadOfViewerHTMLFallback() throws {
        let assetURL = try XCTUnwrap(URL(string: "ebook://ebook/load/viewer-assets/foliate-js/missing.js"))
        let response = try XCTUnwrap(missingEbookViewerAssetResponse(for: assetURL))

        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(missingEbookViewerAssetResponse(
            for: try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/example.epub"))
        ))
    }

    func testForegroundProcessingWaitsForCachePublicationBeforeReturning() async throws {
        let writerGate = EBookProcessingGate()
        let completionCounter = EBookProcessorInvocationCounter()
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: nil,
            ebookProcessedTextCacheWriter: { _, _, _, _, _ in
                await writerGate.waitUntilReleased()
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in ebookTestPayload("processed") },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let processingTask = Task {
            let result = try await actor.process(
                contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
                location: "item/xhtml/chapter.xhtml",
                text: "raw",
                isCacheWarmer: false
            )
            _ = await completionCounter.increment()
            return result
        }

        for _ in 0..<1_000 {
            if await writerGate.isWaitingForRelease() { break }
            await Task.yield()
        }
        let writerIsWaiting = await writerGate.isWaitingForRelease()
        let completionCountBeforeRelease = await completionCounter.value()
        XCTAssertTrue(writerIsWaiting)
        XCTAssertEqual(completionCountBeforeRelease, 0)

        await writerGate.release()
        let processedPayload = try await processingTask.value
        XCTAssertEqual(String(decoding: processedPayload.documentHTML, as: UTF8.self), "processed")
        let completionCountAfterRelease = await completionCounter.value()
        XCTAssertEqual(completionCountAfterRelease, 1)
    }

    func testProcessTextRequestKeySeparatesYomitanGenerations() {
        let contentURL = URL(string: "ebook://ebook/load/local/Books/test.epub")!
        let firstVariant = EbookProcessingVariant(
            availableDictionaryIDs: ["jmdict", "jmnedict"],
            yomitanResolvedDictionaryID: 42,
            yomitanJMDictGenerationKey: "jmdict-generation-1",
            yomitanJMnedictGenerationKey: "jmnedict-generation-1",
            includeJLPTClasses: true,
            romajiModeEnabled: false
        )
        let secondVariant = EbookProcessingVariant(
            availableDictionaryIDs: ["jmnedict", "jmdict"],
            yomitanResolvedDictionaryID: 42,
            yomitanJMDictGenerationKey: "jmdict-generation-2",
            yomitanJMnedictGenerationKey: "jmnedict-generation-1",
            includeJLPTClasses: true,
            romajiModeEnabled: false
        )

        let firstKey = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: "<html><body>raw</body></html>",
            processingVariant: firstVariant
        )
        let secondKey = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: "<html><body>raw</body></html>",
            processingVariant: secondVariant
        )

        XCTAssertNotEqual(firstKey, secondKey)
    }

    func testEbookProcessingVariantNormalizesDictionaryOrderAndDuplicates() {
        let first = EbookProcessingVariant(
            availableDictionaryIDs: ["jmnedict", "jmdict", "jmdict"],
            includeJLPTClasses: false,
            romajiModeEnabled: true
        )
        let second = EbookProcessingVariant(
            availableDictionaryIDs: ["jmdict", "jmnedict"],
            includeJLPTClasses: false,
            romajiModeEnabled: true
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.availableDictionaryIDs, ["jmdict", "jmnedict"])
    }

    func testOptionalEbookProcessingVariantPreservesMissingContext() async throws {
        let absent = try await withEbookProcessingVariant(nil) {
            EbookProcessingVariantContext.current
        }
        XCTAssertNil(absent)

        let variant = EbookProcessingVariant(
            availableDictionaryIDs: ["jmdict"],
            includeJLPTClasses: true,
            romajiModeEnabled: false
        )
        let present = try await withEbookProcessingVariant(variant) {
            EbookProcessingVariantContext.current
        }
        XCTAssertEqual(present, variant)
    }

    func testReaderModeRenderGenerationRejectsStaleAndCancelledOwners() {
        let current = UUID()

        XCTAssertTrue(readerModeRenderGenerationIsCurrent(
            activeGeneration: current,
            expectedGeneration: current,
            taskIsCancelled: false
        ))
        XCTAssertFalse(readerModeRenderGenerationIsCurrent(
            activeGeneration: UUID(),
            expectedGeneration: current,
            taskIsCancelled: false
        ))
        XCTAssertFalse(readerModeRenderGenerationIsCurrent(
            activeGeneration: current,
            expectedGeneration: current,
            taskIsCancelled: true
        ))
    }

    func testReaderModeReadyGenerationAcceptsOnlyCurrentOrCompletedOwner() {
        let current = UUID()
        let stale = UUID()

        XCTAssertTrue(readerModeReadyGenerationIsCurrent(
            activeGeneration: current,
            completedGeneration: nil,
            reportedGeneration: current
        ))
        XCTAssertFalse(readerModeReadyGenerationIsCurrent(
            activeGeneration: current,
            completedGeneration: stale,
            reportedGeneration: stale
        ))
        XCTAssertTrue(readerModeReadyGenerationIsCurrent(
            activeGeneration: nil,
            completedGeneration: current,
            reportedGeneration: current
        ))
    }

    func testProcessTextRequestKeyDistinguishesRawBytesWithSameLossyUTF8Text() {
        let contentURL = URL(string: "ebook://ebook/load/local/Books/test.epub")!
        let firstData = Data([0x80])
        let secondData = Data([0x81])
        XCTAssertEqual(
            String(decoding: firstData, as: UTF8.self),
            String(decoding: secondData, as: UTF8.self)
        )

        let firstKey = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            contentData: firstData
        )
        let secondKey = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            contentData: secondData
        )

        XCTAssertNotEqual(firstKey, secondKey)
    }

    func testProcessTextRequestDeduperDoesNotRetainCompletedResponses() async throws {
        let counter = EBookProcessorInvocationCounter()
        let key = EBookProcessTextRequestKey(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: "<html><body>raw</body></html>"
        )
        let deduper = EBookProcessTextRequestDeduper()

        let first = try await deduper.process(key: key) {
            let invocation = await counter.increment()
            return ebookTestPayload("<html><body>processed-\(invocation)</body></html>")
        }
        let second = try await deduper.process(key: key) {
            let invocation = await counter.increment()
            return ebookTestPayload("<html><body>processed-\(invocation)</body></html>")
        }
        let invocationCount = await counter.value()

        XCTAssertEqual(String(decoding: first.payload.documentHTML, as: UTF8.self), "<html><body>processed-1</body></html>")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertEqual(String(decoding: second.payload.documentHTML, as: UTF8.self), "<html><body>processed-2</body></html>")
        XCTAssertFalse(second.didCoalesce)
        XCTAssertEqual(invocationCount, 2)
    }

    func testProcessTextRequestDeduperCoalescesEquivalentInFlightRequests() async throws {
        let key = EBookProcessTextRequestKey(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: "<html><body>raw</body></html>"
        )
        let counter = EBookProcessorInvocationCounter()
        let gate = EBookProcessingGate()
        let started = expectation(description: "Processing starts")
        let deduper = EBookProcessTextRequestDeduper()

        let firstTask = Task {
            try await deduper.process(key: key) {
                _ = await counter.increment()
                started.fulfill()
                await gate.waitUntilReleased()
                return ebookTestPayload("<html><body>shared</body></html>")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let secondTask = Task {
            try await deduper.process(key: key) {
                XCTFail("Equivalent in-flight work should reuse the active operation")
                return ebookTestPayload("<html><body>duplicate</body></html>")
            }
        }
        for _ in 0..<1_000 {
            if await deduper.inFlightWaiterCountForTesting(key: key) == 1 {
                break
            }
            await Task.yield()
        }
        let waiterCount = await deduper.inFlightWaiterCountForTesting(key: key)
        XCTAssertEqual(waiterCount, 1)
        await gate.release()

        let first = try await firstTask.value
        let second = try await secondTask.value
        XCTAssertEqual(first.payload.documentHTML, second.payload.documentHTML)
        XCTAssertEqual(first.payload.segmentSidecar, second.payload.segmentSidecar)
        XCTAssertFalse(first.didCoalesce)
        XCTAssertTrue(second.didCoalesce)
        let invocationCount = await counter.value()
        XCTAssertEqual(invocationCount, 1)
    }

    func testProcessTextRequestDeduperKeepsProducerAliveWhenOriginalCallerCancels() async throws {
        let key = EBookProcessTextRequestKey(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: "<html><body>raw</body></html>"
        )
        let gate = EBookProcessingGate()
        let started = expectation(description: "Shared producer starts")
        let deduper = EBookProcessTextRequestDeduper()

        let originalCaller = Task {
            try await deduper.process(key: key) {
                started.fulfill()
                await gate.waitUntilReleased()
                try Task.checkCancellation()
                return ebookTestPayload("<html><body>shared</body></html>")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let activeWaiter = Task {
            try await deduper.process(key: key) {
                XCTFail("The active waiter must reuse the independent producer")
                return ebookTestPayload("<html><body>duplicate</body></html>")
            }
        }
        for _ in 0..<1_000 {
            if await deduper.inFlightWaiterCountForTesting(key: key) == 1 {
                break
            }
            await Task.yield()
        }

        originalCaller.cancel()
        await gate.release()

        do {
            _ = try await originalCaller.value
            XCTFail("The cancelled caller must retain its own cancellation result")
        } catch is CancellationError {
            // Expected.
        }
        let waiterResult = try await activeWaiter.value
        XCTAssertEqual(
            String(decoding: waiterResult.payload.documentHTML, as: UTF8.self),
            "<html><body>shared</body></html>"
        )
        XCTAssertTrue(waiterResult.didCoalesce)
    }

    func testProcessTextRequestDeduperCancelsProducerWhenLastWaiterCancels() async throws {
        let key = EBookProcessTextRequestKey(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: "<html><body>raw</body></html>"
        )
        let producerStarted = expectation(description: "Producer starts")
        let producerCancelled = expectation(description: "Orphaned producer is cancelled")
        let deduper = EBookProcessTextRequestDeduper()

        let onlyCaller = Task {
            try await deduper.process(key: key) {
                producerStarted.fulfill()
                return try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(60))
                    return ebookTestPayload("<html><body>unexpected</body></html>")
                } onCancel: {
                    producerCancelled.fulfill()
                }
            }
        }
        await fulfillment(of: [producerStarted], timeout: 1)
        onlyCaller.cancel()

        do {
            _ = try await onlyCaller.value
            XCTFail("The cancelled caller must not receive a result")
        } catch is CancellationError {
            // Expected.
        }
        await fulfillment(of: [producerCancelled], timeout: 1)

        let replacement = try await deduper.process(key: key) {
            ebookTestPayload("<html><body>replacement</body></html>")
        }
        XCTAssertEqual(
            String(decoding: replacement.payload.documentHTML, as: UTF8.self),
            "<html><body>replacement</body></html>"
        )
        XCTAssertFalse(replacement.didCoalesce)
    }

    func testCancelledCoalescedWaiterDoesNotCancelOrAwaitOwner() async throws {
        let key = EBookProcessTextRequestKey(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: "<html><body>raw</body></html>"
        )
        let gate = EBookProcessingGate()
        let started = expectation(description: "Owner processing starts")
        let waiterFinished = expectation(description: "Canceled waiter finishes")
        let deduper = EBookProcessTextRequestDeduper()

        let ownerTask = Task {
            try await deduper.process(key: key) {
                started.fulfill()
                await gate.waitUntilReleased()
                return ebookTestPayload("<html><body>owner</body></html>")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let waiterTask = Task {
            defer { waiterFinished.fulfill() }
            do {
                _ = try await deduper.process(key: key) {
                    XCTFail("A coalesced waiter must not start duplicate work")
                    return ebookTestPayload("<html><body>duplicate</body></html>")
                }
                XCTFail("A canceled waiter must not receive the owner's result")
            } catch is CancellationError {
                return
            } catch {
                XCTFail("Expected CancellationError, received \(error)")
            }
        }
        for _ in 0..<1_000 {
            if await deduper.inFlightWaiterCountForTesting(key: key) == 1 {
                break
            }
            await Task.yield()
        }
        waiterTask.cancel()
        await fulfillment(of: [waiterFinished], timeout: 1)
        for _ in 0..<1_000 {
            if await deduper.inFlightWaiterCountForTesting(key: key) == 0 {
                break
            }
            await Task.yield()
        }
        let remainingWaiterCount = await deduper.inFlightWaiterCountForTesting(key: key)
        XCTAssertEqual(remainingWaiterCount, 0)

        await gate.release()
        let owner = try await ownerTask.value
        XCTAssertEqual(
            String(decoding: owner.payload.documentHTML, as: UTF8.self),
            "<html><body>owner</body></html>"
        )
        XCTAssertFalse(owner.didCoalesce)
    }

    func testForegroundAndCacheWarmerRequestsDoNotCoalesceModeSpecificOutput() async throws {
        let contentURL = URL(string: "ebook://ebook/load/local/Books/test.epub")!
        let text = "<html><body>raw</body></html>"
        let cacheWarmerKey = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: true,
            text: text
        )
        let foregroundKey = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: text
        )
        let counter = EBookProcessorInvocationCounter()
        let gate = EBookProcessingGate()
        let started = expectation(description: "Cache warmer processing starts")
        let deduper = EBookProcessTextRequestDeduper()

        let cacheWarmerTask = Task {
            try await deduper.process(key: cacheWarmerKey) {
                _ = await counter.increment()
                started.fulfill()
                await gate.waitUntilReleased()
                return ebookTestPayload("<html><body>processed</body></html>")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let foregroundTask = Task {
            try await deduper.process(key: foregroundKey) {
                _ = await counter.increment()
                return ebookTestPayload("<html><body>foreground</body></html>")
            }
        }
        await gate.release()

        let cacheWarmerResult = try await cacheWarmerTask.value
        let foregroundResult = try await foregroundTask.value
        XCTAssertEqual(String(decoding: cacheWarmerResult.payload.documentHTML, as: UTF8.self), "<html><body>processed</body></html>")
        XCTAssertEqual(String(decoding: foregroundResult.payload.documentHTML, as: UTF8.self), "<html><body>foreground</body></html>")
        XCTAssertFalse(cacheWarmerResult.didCoalesce)
        XCTAssertFalse(foregroundResult.didCoalesce)
        let invocationCount = await counter.value()
        XCTAssertEqual(invocationCount, 2)
    }

    func testCacheWarmerDoesNotReadLivePreparedTextCache() async throws {
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in
                XCTFail("Cache warmers must not consume live presentation HTML")
                return ebookTestPayload("<html><body>live presentation</body></html>")
            },
            ebookTextProcessor: { _, _, _, _, isCacheWarmer, _, _, _, _ in
                XCTAssertTrue(isCacheWarmer)
                return ebookTestPayload("<html><body>neutral warmer result</body></html>")
            },
            processReadabilityContent: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/title.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: true
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), "<html><body>neutral warmer result</body></html>")
    }

    func testCacheWarmerProcessingReturnsProcessedContentToCaller() async throws {
        let expectedHTML = "<html><body><manabi-segment>cached</manabi-segment></body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in ebookTestPayload(expectedHTML) },
            processReadabilityContent: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/title.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: true
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), expectedHTML)
    }

    func testForegroundUsesPersistedProcessedTextWithoutReprocessing() async throws {
        let expectedHTML = """
        <html><body><m-m>persisted</m-m>
        <script id="mnb-segment-metadata" type="application/json">
        {"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!persisted",0,null,null,null,null,null,null,null,0,0]]}
        </script></body></html>
        """
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in
                let split = try XCTUnwrap(splitCanonicalReaderSegmentSidecar(from: Array(expectedHTML.utf8)))
                return split
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                XCTFail("A persisted cache hit should bypass ebook text processing")
                return ebookTestPayload("<html><body>unexpected processed value</body></html>")
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: false
        )

        let expectedPayload = try XCTUnwrap(
            splitCanonicalReaderSegmentSidecar(from: Array(expectedHTML.utf8))
        )
        XCTAssertEqual(result.documentHTML, expectedPayload.documentHTML)
        XCTAssertEqual(result.segmentSidecar, expectedPayload.segmentSidecar)
    }

    func testProcessingCanSkipCacheReadAfterCallerAlreadyMissed() async throws {
        let expectedHTML = "<html><body>processed once</body></html>"
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in
                XCTFail("The scheme handler already performed this cache read")
                return ebookTestPayload("<html><body>unexpected cached value</body></html>")
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in ebookTestPayload(expectedHTML) },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: false,
            shouldReadProcessedCache: false
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), expectedHTML)
    }

    func testCacheWarmerProcessTextResponseDoesNotReturnProcessedContent() throws {
        let processedHTML = "<html><body><manabi-segment>cached</manabi-segment></body></html>"

        let cacheWarmerData = try XCTUnwrap(ebookProcessTextResponseData(
            processedText: processedHTML,
            isCacheWarmer: true
        ))
        let liveData = try XCTUnwrap(ebookProcessTextResponseData(
            processedText: processedHTML,
            isCacheWarmer: false
        ))

        XCTAssertTrue(cacheWarmerData.isEmpty)
        XCTAssertEqual(String(data: liveData, encoding: .utf8), processedHTML)
    }

    func testCacheWarmerWithoutProcessorFallsBackToOriginalText() async throws {
        let originalText = "<html><body>raw</body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessor: nil,
            processReadabilityContent: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/title.xhtml",
            text: originalText,
            isCacheWarmer: true
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), originalText)
    }
}
