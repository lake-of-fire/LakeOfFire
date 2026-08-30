import XCTest
import ZIPFoundation
import SwiftSoup
@testable import LakeOfFireContent
@_spi(ReaderProcessing) @_spi(TestSupport) @testable import LakeOfFireReader

private actor EbookTestGate {
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

private actor EbookTestInvocationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func ebookTestPayload(
    _ documentHTML: String,
    sidecar: String = "",
    isAuthoritativelyProcessed: Bool = false
) -> EbookProcessedSectionPayload {
    let document = Data(documentHTML.utf8)
    let sidecarData = Data(sidecar.utf8)
    return isAuthoritativelyProcessed
        ? .successfulReaderProcessing(documentHTML: document, segmentSidecar: sidecarData)
        : EbookProcessedSectionPayload(documentHTML: document, segmentSidecar: sidecarData)
}

private func ebookIndexedSidecarPayload(_ index: Int) -> EbookProcessedSectionPayload {
    EbookProcessedSectionPayload.successfulReaderProcessing(
        documentHTML: Data("<m-c pid=\"p\"><m-s sid=\"s\" o=\"true\"><m-m id=\"m\">\(index)</m-m></m-s></m-c>".utf8),
        segmentSidecar: Data("""
        {"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h\(index)"],"x":["\(index)"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}
        """.utf8)
    )
}

private let ebookTestProcessingVariant = EbookProcessingVariant(
    availableDictionaryIDs: ["jmdict"],
    includeJLPTClasses: false,
    romajiModeEnabled: false
)

final class EbookURLSchemeHandlerTests: XCTestCase {
    func testEbookEndpointSourceRequiresTheRequestMainDocumentPackage() throws {
        let manager = ReaderFileManager()
        let bookURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/one.epub"))
        let otherBookURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/two.epub"))

        var request = URLRequest(
            url: URL(string: "ebook://ebook/entries?sourceURL=\(bookURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")!
        )
        request.mainDocumentURL = bookURL
        request.setValue(bookURL.absoluteString, forHTTPHeaderField: "X-Ebook-Source-URL")
        XCTAssertEqual(
            ebookAuthorizedMainDocumentURL(for: request, readerFileManager: manager),
            bookURL
        )

        request.setValue(otherBookURL.absoluteString, forHTTPHeaderField: "X-Ebook-Source-URL")
        XCTAssertNil(ebookAuthorizedMainDocumentURL(for: request, readerFileManager: manager))

        request.setValue(bookURL.absoluteString, forHTTPHeaderField: "X-Ebook-Source-URL")
        request.mainDocumentURL = otherBookURL
        XCTAssertNil(ebookAuthorizedMainDocumentURL(for: request, readerFileManager: manager))
    }

    func testEbookEndpointSourceCanonicalizesQueryAndFragmentBeforeComparing() throws {
        let manager = ReaderFileManager()
        let sourceURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/one.epub"))
        let sourceWithDecorations = try XCTUnwrap(
            URL(string: "ebook://ebook/load/local/Books/one.epub?subpath=OPS/chapter.xhtml#section")
        )
        var request = URLRequest(url: URL(string: "ebook://ebook/entries")!)
        request.mainDocumentURL = sourceURL
        request.setValue(sourceWithDecorations.absoluteString, forHTTPHeaderField: "X-Ebook-Source-URL")

        XCTAssertEqual(
            ebookAuthorizedMainDocumentURL(for: request, readerFileManager: manager),
            sourceURL
        )
    }

    func testEbookEndpointRejectsMalformedRawSourceEscapes() throws {
        XCTAssertFalse(ebookURLStringHasValidPercentEncoding("ebook://ebook/load/local/bad%ZZ.epub"))
        XCTAssertFalse(ebookURLStringHasValidPercentEncoding("ebook://ebook/load/local/bad%2.epub"))
        XCTAssertTrue(ebookURLStringHasValidPercentEncoding("ebook://ebook/load/local/100%25.epub"))
    }

    func testEbookEndpointAuthorizesProcessedSectionSubresourcesAgainstActivePackage() throws {
        let manager = ReaderFileManager()
        let bookURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/one.epub"))
        let otherBookURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/two.epub"))
        let encodedSource = bookURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let processedSectionURL = try XCTUnwrap(
            URL(string: "ebook://ebook/processed-section?sourceURL=\(encodedSource)&subpath=OPS/chapter.xhtml")
        )
        var request = URLRequest(url: URL(string: "ebook://ebook/entry-source/token/OPS/image.png")!)
        request.mainDocumentURL = processedSectionURL

        XCTAssertEqual(
            ebookAuthorizedMainDocumentURL(
                for: request,
                activePackageURL: bookURL,
                readerFileManager: manager
            ),
            bookURL
        )
        XCTAssertNil(
            ebookAuthorizedMainDocumentURL(
                for: request,
                activePackageURL: otherBookURL,
                readerFileManager: manager
            )
        )
    }

    func testExternalizingCanonicalSidecarKeepsAggregateAndPublishesRawJSON() throws {
        let canonicalJSON = #"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["本文"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#
        let aggregateJSON = #"{"c":0,"j":[],"n":[],"k":[],"sid":[]}"#
        let html = """
        <html><head><title>Test</title></head><body><m-c pid="p"><m-s sid="s" o="true"><m-m id="m">本文</m-m></m-s></m-c>
        <script id="mnb-segment-metadata-aggregate" type="application/json" data-mnb-seg-meta-aggregate="true">\(aggregateJSON)</script>
        <script id="mnb-segment-metadata" type="application/json" data-mnb-seg-meta="true">\(canonicalJSON)</script>
        </body></html>
        """

        let result = externalizingCanonicalReaderSegmentSidecar(
            in: Array(html.utf8),
            scheme: .ebook
        )
        let output = String(decoding: result.documentHTML, as: UTF8.self)

        XCTAssertFalse(output.contains("id=\"mnb-segment-metadata\""))
        XCTAssertTrue(output.contains("id=\"mnb-segment-metadata-aggregate\""))
        XCTAssertTrue(output.contains("meta name=\"mnb-segment-sidecar\""))
        XCTAssertTrue(output.contains("ebook://ebook/processed-section-sidecar/"))
        XCTAssertLessThan(
            try XCTUnwrap(output.range(of: "meta name=\"mnb-segment-sidecar\"")?.lowerBound),
            try XCTUnwrap(output.range(of: "</head>")?.lowerBound)
        )
        XCTAssertEqual(result.canonicalSidecarByteCount, canonicalJSON.utf8.count)
        let endpointURL = try XCTUnwrap(result.endpointURL)
        let token = try XCTUnwrap(URL(string: endpointURL)?.lastPathComponent)
        let stored = try XCTUnwrap(ReaderExternalSegmentSidecarStore.shared.entry(for: token))
        XCTAssertEqual(String(decoding: stored.data, as: UTF8.self), canonicalJSON)
        XCTAssertEqual(stored.signature, result.signature)
    }

    func testExternalizingCanonicalSidecarIgnoresIdentifierTextInsideEarlierScript() throws {
        let canonicalJSON = #"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["本文"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#
        let html = """
        <html><head></head><body>
        <script>window.decoy = 'id="mnb-segment-metadata"';</script>
        <m-c pid="p"><m-s sid="s" o="true"><m-m id="m">本文</m-m></m-s></m-c>
        <script type="application/json" data-mnb-seg-meta="true" id="mnb-segment-metadata">
        \(canonicalJSON)
        </script>
        </body></html>
        """

        let result = externalizingCanonicalReaderSegmentSidecar(
            in: Array(html.utf8),
            scheme: .ebook
        )
        let output = String(decoding: result.documentHTML, as: UTF8.self)

        XCTAssertTrue(output.contains("window.decoy"))
        XCTAssertFalse(output.contains("data-mnb-seg-meta"))
        let endpoint = try XCTUnwrap(result.endpointURL.flatMap(URL.init(string:)))
        let served = try XCTUnwrap(
            readerExternalSegmentSidecarResponse(for: endpoint, scheme: .ebook)
        )
        XCTAssertEqual(
            String(decoding: served.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            canonicalJSON
        )
    }

    func testExternalizingCanonicalSidecarIgnoresCommentedScriptDecoy() throws {
        let canonicalJSON = #"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["本文"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#
        let html = """
        <html><head></head><body>
        <!-- <script id="mnb-segment-metadata">{"decoy":true}</script> -->
        <m-c pid="p"><m-s sid="s" o="true"><m-m id="m">本文</m-m></m-s></m-c>
        <SCRIPT type="application/json" data-note="2 > 1" ID="mnb-segment-metadata">
        \(canonicalJSON)
        </SCRIPT>
        </body></html>
        """

        let result = externalizingCanonicalReaderSegmentSidecar(
            in: Array(html.utf8),
            scheme: .ebook
        )
        let output = String(decoding: result.documentHTML, as: UTF8.self)

        XCTAssertTrue(output.contains("{\"decoy\":true}"))
        XCTAssertFalse(output.contains("data-note=\"2 > 1\""))
        let endpoint = try XCTUnwrap(result.endpointURL.flatMap(URL.init(string:)))
        let served = try XCTUnwrap(
            readerExternalSegmentSidecarResponse(for: endpoint, scheme: .ebook)
        )
        XCTAssertEqual(
            String(decoding: served.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            canonicalJSON
        )
    }

    func testExternalizingCanonicalSidecarRejectsMultipleCanonicalOwners() {
        let canonicalJSON = #"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["本文"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#
        let html = """
        <html><body><m-c pid="p"><m-s sid="s" o="true"><m-m id="m">本文</m-m></m-s></m-c>
        <script id="mnb-segment-metadata">\(canonicalJSON)</script>
        <script id="mnb-segment-metadata">\(canonicalJSON)</script>
        </body></html>
        """

        let result = externalizingCanonicalReaderSegmentSidecar(
            in: Array(html.utf8),
            scheme: .ebook
        )

        XCTAssertEqual(result.documentHTML, Data(html.utf8))
        XCTAssertEqual(result.canonicalSidecarByteCount, 0)
        XCTAssertNil(result.endpointURL)
    }

    func testExternalSidecarIdentityIsDeterministicAndCacheable() throws {
        let payload = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: Data("<html><head></head><body><m-c pid=\"p\"><m-s sid=\"s\" o=\"true\"><m-m id=\"m\">本文</m-m></m-s></m-c></body></html>".utf8),
            segmentSidecar: Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["本文"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        )

        let first = publishingCanonicalReaderSegmentSidecar(payload, scheme: .ebook)
        let second = publishingCanonicalReaderSegmentSidecar(payload, scheme: .ebook)

        XCTAssertEqual(first.endpointURL, second.endpointURL)
        XCTAssertEqual(first.signature, second.signature)
        let responseDocument = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            first.documentHTML,
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
            writingHint: nil,
            bodyAttributes: [:],
            additionalHeadMarkup: first.headDescriptor
        ), as: UTF8.self)
        XCTAssertTrue(responseDocument.contains("<head><base href="))
        XCTAssertTrue(responseDocument.contains("<meta name=\"mnb-segment-sidecar\""))
        let endpoint = try XCTUnwrap(first.endpointURL.flatMap(URL.init(string:)))
        let served = try XCTUnwrap(readerExternalSegmentSidecarResponse(for: endpoint, scheme: .ebook))
        XCTAssertEqual(served.data, payload.segmentSidecar)
        XCTAssertEqual(served.response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testPublishedSidecarRemainsAvailableForDocumentLifetime() throws {
        let firstPayload = ebookIndexedSidecarPayload(0)
        let first = publishingCanonicalReaderSegmentSidecar(firstPayload, scheme: .ebook)
        let firstEndpoint = try XCTUnwrap(first.endpointURL.flatMap(URL.init(string:)))

        // This exceeded the former entry limit and evicted an otherwise valid
        // sidecar URL retained by the first document.
        for index in 1...40 {
            _ = publishingCanonicalReaderSegmentSidecar(
                ebookIndexedSidecarPayload(index),
                scheme: .ebook
            )
        }

        let served = try XCTUnwrap(
            readerExternalSegmentSidecarResponse(for: firstEndpoint, scheme: .ebook)
        )
        XCTAssertEqual(served.data, firstPayload.segmentSidecar)
    }

    func testEvictedSidecarRegeneratesFromContentAddressedStorageAcrossStoreInstances() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let firstStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )
        let firstPayload = ebookIndexedSidecarPayload(0)
        let first = publishingCanonicalReaderSegmentSidecar(
            firstPayload,
            scheme: .ebook,
            store: firstStore
        )
        let endpoint = try XCTUnwrap(first.endpointURL.flatMap(URL.init(string:)))

        _ = publishingCanonicalReaderSegmentSidecar(
            ebookIndexedSidecarPayload(1),
            scheme: .ebook,
            store: firstStore
        )
        XCTAssertEqual(
            readerExternalSegmentSidecarResponse(
                for: endpoint,
                scheme: .ebook,
                store: firstStore
            )?.data,
            firstPayload.segmentSidecar
        )

        let restartedStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )
        XCTAssertEqual(
            readerExternalSegmentSidecarResponse(
                for: endpoint,
                scheme: .ebook,
                store: restartedStore
            )?.data,
            firstPayload.segmentSidecar
        )
    }

    func testSidecarStorePrunesOldDiskEntriesButKeepsRecentRestartData() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let old = String(repeating: "a", count: 64)
        let recent = String(repeating: "b", count: 64)
        let oldURL = directoryURL.appendingPathComponent(old)
        let recentURL = directoryURL.appendingPathComponent(recent)
        try Data("old".utf8).write(to: oldURL)
        try Data("recent".utf8).write(to: recentURL)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1_000)],
            ofItemAtPath: oldURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: recentURL.path
        )

        _ = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            diskByteLimit: 1_024,
            diskCountLimit: 10,
            maximumDiskAge: 100,
            now: now
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
    }

    func testSidecarStoreHonorsMemoryBudgetWhenDiskPersistenceFails() throws {
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parentURL) }
        let unusableDirectoryURL = parentURL.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: unusableDirectoryURL)
        let store = ReaderExternalSegmentSidecarStore(
            directoryURL: unusableDirectoryURL,
            totalByteLimit: 4,
            countLimit: 1,
            diskByteLimit: 16,
            diskCountLimit: 2
        )

        let first = try XCTUnwrap(store.insert(Data("aaaa".utf8)))
        let second = try XCTUnwrap(store.insert(Data("bbbb".utf8)))
        let usage = store.memoryUsageForTesting()

        XCTAssertLessThanOrEqual(usage.byteCount, 4)
        XCTAssertLessThanOrEqual(usage.count, 1)
        XCTAssertNil(store.entry(for: first.token))
        XCTAssertEqual(store.entry(for: second.token)?.data, Data("bbbb".utf8))
        XCTAssertEqual(store.diskUsageForTesting().count, 0)
    }

    func testSidecarStorePrunesDuringLongLivedInsertSequenceWithoutDeletingCurrentFile() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-long-lived-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1,
            diskByteLimit: 12,
            diskCountLimit: 2
        )

        _ = try XCTUnwrap(store.insert(Data("aaaaaa".utf8)))
        _ = try XCTUnwrap(store.insert(Data("bbbbbb".utf8)))
        let current = try XCTUnwrap(store.insert(Data("cccccc".utf8)))
        let diskUsage = store.diskUsageForTesting()

        XCTAssertLessThanOrEqual(store.memoryUsageForTesting().byteCount, 1)
        XCTAssertLessThanOrEqual(diskUsage.byteCount, 12)
        XCTAssertLessThanOrEqual(diskUsage.count, 2)
        XCTAssertEqual(store.entry(for: current.token)?.data, Data("cccccc".utf8))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directoryURL.appendingPathComponent(current.token).path
        ))
    }

    func testSidecarStoreRejectsEntryThatCannotFitEitherTierWithoutPublishingURL() {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-oversized-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 3,
            countLimit: 1,
            diskByteLimit: 3,
            diskCountLimit: 1
        )

        XCTAssertNil(store.insert(Data("oversized".utf8)))
        XCTAssertEqual(store.memoryUsageForTesting().byteCount, 0)
        XCTAssertEqual(store.diskUsageForTesting().byteCount, 0)
        let published = publishingCanonicalReaderSegmentSidecar(
            ebookIndexedSidecarPayload(99),
            scheme: .ebook,
            store: store
        )
        XCTAssertNil(published.endpointURL)
        XCTAssertNil(published.signature)
        XCTAssertEqual(published.canonicalSidecarByteCount, 0)
    }

    func testSpeechProgressSaturatesOverflowingUTF16Range() {
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "A😀B",
                spokenRange: NSRange(location: Int.max - 1, length: 10)
            ),
            1
        )
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "本文",
                spokenRange: NSRange(location: NSNotFound, length: 0)
            ),
            0
        )
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "本文",
                spokenRange: NSRange(location: -1, length: 1)
            ),
            0
        )
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "",
                spokenRange: NSRange(location: 0, length: 1)
            ),
            0
        )
    }

    func testUnversionedViewerAssetsDisableBrowserCaching() throws {
        let response = ebookHTTPResponse(
            url: try XCTUnwrap(URL(string: "ebook://ebook/load/viewer-assets/foliate-js/paginator.js")),
            mimeType: "text/javascript",
            byteCount: 123,
            textEncodingName: "utf-8",
            additionalHeaderFields: ebookViewerAssetCacheHeaderFields()
        )

        XCTAssertEqual(
            response.value(forHTTPHeaderField: "Cache-Control"),
            "no-store, no-cache, must-revalidate"
        )
        XCTAssertEqual(response.value(forHTTPHeaderField: "Pragma"), "no-cache")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Expires"), "0")
    }

    func testExternalizingCanonicalSidecarLeavesHTMLWithoutCanonicalSidecarUnchanged() {
        let html = "<html><head></head><body><p>本文</p></body></html>"

        let result = externalizingCanonicalReaderSegmentSidecar(
            in: Array(html.utf8),
            scheme: .internalReader
        )

        XCTAssertEqual(result.documentHTML, Data(html.utf8))
        XCTAssertEqual(result.canonicalSidecarByteCount, 0)
        XCTAssertNil(result.endpointURL)
        XCTAssertNil(result.signature)
    }

    func testProcessedSidecarCacheEnvelopeRoundTripsWithoutRescanningCombinedHTML() throws {
        let canonicalJSON = #"{"v":11,"t":{"語":[1]},"s":[]}"#
        let aggregateJSON = #"{"c":1,"j":["語"]}"#
        let html = """
        <html><head></head><body><p>本文</p>
        <script id="mnb-segment-metadata-aggregate" type="application/json">\(aggregateJSON)</script>
        <script id="mnb-segment-metadata" type="application/json" data-mnb-seg-meta="true">\(canonicalJSON)</script>
        </body></html>
        """

        let payload = try XCTUnwrap(splitCanonicalReaderSegmentSidecar(from: Array(html.utf8)))
        XCTAssertFalse(payload.isAuthoritativelyProcessed)
        let encoded = encodedEbookProcessedSectionCacheValue(payload)
        let decoded = try XCTUnwrap(decodedEbookProcessedSectionCacheValue(encoded))
        let splitDocument = String(decoding: decoded.documentHTML, as: UTF8.self)

        XCTAssertFalse(splitDocument.contains("id=\"mnb-segment-metadata\""))
        XCTAssertTrue(splitDocument.contains("id=\"mnb-segment-metadata-aggregate\""))
        XCTAssertEqual(String(decoding: decoded.segmentSidecar, as: UTF8.self), canonicalJSON)

    }

    func testProcessedSidecarCacheEnvelopeRejectsTruncatedValue() throws {
        let html = "<html><body><script id=\"mnb-segment-metadata\">{}</script></body></html>"
        let payload = try XCTUnwrap(splitCanonicalReaderSegmentSidecar(from: Array(html.utf8)))
        let encoded = encodedEbookProcessedSectionCacheValue(payload)

        XCTAssertNil(decodedEbookProcessedSectionCacheValue(Array(encoded.dropLast())))
    }

    func testProcessedSidecarCacheEnvelopePreservesExplicitAuthority() throws {
        let successful = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: Data(
                "<html><body><m-c pid=\"p\"><m-s sid=\"s\" o=\"true\">記号だけ。</m-s></m-c></body></html>".utf8
            ),
            segmentSidecar: Data()
        )
        let fallback = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body>未処理の本文</body></html>".utf8),
            segmentSidecar: Data()
        )

        let decodedSuccessful = try XCTUnwrap(
            decodedEbookProcessedSectionCacheValue(
                encodedEbookProcessedSectionCacheValue(successful)
            )
        )
        let decodedFallback = try XCTUnwrap(
            decodedEbookProcessedSectionCacheValue(
                encodedEbookProcessedSectionCacheValue(fallback)
            )
        )

        XCTAssertTrue(decodedSuccessful.isAuthoritativelyProcessed)
        XCTAssertFalse(decodedFallback.isAuthoritativelyProcessed)
    }

    func testProcessedSidecarCacheEnvelopeCannotPromoteUnmarkedSegmentFreeFallback() {
        let fallback = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body>未処理の本文</body></html>".utf8),
            segmentSidecar: Data()
        )
        var encoded = encodedEbookProcessedSectionCacheValue(fallback)
        let authorityByteIndex = Array("MNBPSC5".utf8).count
            + (MemoryLayout<UInt64>.size * 2)
        encoded[authorityByteIndex] = 1

        XCTAssertNil(decodedEbookProcessedSectionCacheValue(encoded))
    }

    func testProcessedSidecarCacheEnvelopeRejectsPreStableIdentityVersion() throws {
        let html = "<html><body><script id=\"mnb-segment-metadata\">{}</script></body></html>"
        let payload = try XCTUnwrap(splitCanonicalReaderSegmentSidecar(from: Array(html.utf8)))
        var legacyEncoded = encodedEbookProcessedSectionCacheValue(payload)
        legacyEncoded.replaceSubrange(0..<7, with: Array("MNBPSC3".utf8))

        XCTAssertNil(decodedEbookProcessedSectionCacheValue(legacyEncoded))
    }

    func testProcessedSidecarCacheEnvelopeRejectsImplicitAuthorityVersion() throws {
        let payload = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: Data("<html><body>処理済み</body></html>".utf8),
            segmentSidecar: Data()
        )
        var legacyEncoded = encodedEbookProcessedSectionCacheValue(payload)
        legacyEncoded.replaceSubrange(0..<7, with: Array("MNBPSC4".utf8))

        XCTAssertNil(decodedEbookProcessedSectionCacheValue(legacyEncoded))
    }

    func testProcessedSidecarCacheRequiresDurableIdentityForEverySegment() {
        let documentHTML = Data("""
        <m-c pid="paragraph"><m-s sid="sentence" o="true">
        <m-m id="runtime"><m-t>text</m-t></m-m>
        </m-s></m-c>
        """.utf8)
        let sidecar = Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["hash"],"x":["text"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!runtime",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        let valid = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: documentHTML,
            segmentSidecar: sidecar
        )
        let missingSentenceIdentity = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: valid.documentHTML,
            segmentSidecar: Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["hash"],"x":["text"],"sid":[],"pid":["paragraph"]},"s":[["!runtime",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        )
        let previousSchemaVersion = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: valid.documentHTML,
            segmentSidecar: Data(#"{"v":11,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["hash"],"x":["text"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!runtime",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        )
        let mismatchedDocumentIdentifier = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: Data(
                String(decoding: valid.documentHTML, as: UTF8.self)
                    .replacingOccurrences(of: "id=\"runtime\"", with: "id=\"other\"")
                    .utf8
            ),
            segmentSidecar: valid.segmentSidecar
        )
        let duplicateDocumentIdentifier = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: Data("""
            <m-c pid="paragraph"><m-s sid="sentence" o="true">
            <m-m id="runtime">A</m-m><m-m id="runtime">B</m-m>
            </m-s></m-c>
            """.utf8),
            segmentSidecar: sidecar
        )

        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(valid))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(missingSentenceIdentity))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(previousSchemaVersion))
        XCTAssertFalse(
            ebookProcessedSectionPayloadHasDurableSegmentIdentities(
                mismatchedDocumentIdentifier
            )
        )
        XCTAssertFalse(
            ebookProcessedSectionPayloadHasDurableSegmentIdentities(
                duplicateDocumentIdentifier
            )
        )
    }

    func testProcessedSidecarCacheRejectsMissingOrIncompleteSegmentCoverage() {
        let documentHTML = Data("""
        <m-c pid="paragraph"><m-s sid="sentence" o="true">
        <m-m id="a">A</m-m><m-m id="b">B</m-m>
        </m-s></m-c>
        """.utf8)
        let missingSidecar = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: documentHTML,
            segmentSidecar: Data()
        )
        let emptySidecar = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: documentHTML,
            segmentSidecar: Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":[],"x":[],"sid":[],"pid":[]},"s":[]}"#.utf8)
        )
        let incompleteSidecar = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: documentHTML,
            segmentSidecar: Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["hash"],"x":["A"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!a",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        )
        let segmentFreeDocument = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: Data("<html><body><m-metadata>Plain text</m-metadata></body></html>".utf8),
            segmentSidecar: Data()
        )
        let implicitSegmentFreeDocument = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body>日本語の未処理本文</body></html>".utf8),
            segmentSidecar: Data()
        )
        let nonAuthoritativeFallback = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body>Raw fallback</body></html>".utf8),
            segmentSidecar: Data()
        )

        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(missingSidecar))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(emptySidecar))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(incompleteSidecar))
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(segmentFreeDocument))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(implicitSegmentFreeDocument))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(nonAuthoritativeFallback))
    }

    func testProcessedSidecarCacheBindsSentenceParagraphAndSurface() {
        let sidecar = Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["hash"],"x":["本文"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!runtime",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        let valid = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: Data("<m-c pid=\"paragraph\"><m-s sid=\"sentence\" o=\"true\"><m-m id=\"runtime\"><m-t>本文</m-t></m-m></m-s></m-c>".utf8),
            segmentSidecar: sidecar
        )
        func changed(_ original: String, _ replacement: String) -> EbookProcessedSectionPayload {
            EbookProcessedSectionPayload.successfulReaderProcessing(
                documentHTML: Data(
                    String(decoding: valid.documentHTML, as: UTF8.self)
                        .replacingOccurrences(of: original, with: replacement)
                        .utf8
                ),
                segmentSidecar: valid.segmentSidecar
            )
        }

        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(valid))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(changed("sid=\"sentence\"", "sid=\"other\"")))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(changed("pid=\"paragraph\"", "pid=\"other\"")))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(changed("<m-t>本文</m-t>", "<m-t>別文</m-t>")))
    }

    func testProcessedSidecarCacheRejectsNonIntegralAndBooleanTupleIndexes() {
        let document = Data("<m-c pid=\"paragraph\"><m-s sid=\"sentence\" o=\"true\"><m-m id=\"runtime\">本文</m-m></m-s></m-c>".utf8)
        let fractional = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: document,
            segmentSidecar: Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["hash"],"x":["本文"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!runtime",0.5,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        )
        let boolean = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: document,
            segmentSidecar: Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["hash"],"x":["本文"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!runtime",true,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        )

        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(fractional))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(boolean))
    }

    func testSuccessfulPayloadPreservesXHTMLBytesRubyEntitiesAndUnicodeWhitespace() {
        let nonbreakingSpace = "\u{00A0}"
        let body = """
        <body><m-c pid="paragraph"><m-s sid="sentence" o="true"><m-m id="runtime"><ruby><rb>学</rb><rt>がく</rt></ruby>&#xA0;校</m-m></m-s></m-c><img src="cover.jpg" /></body>
        """
        let source = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>A &amp; B</title></head>\(body)</html>
        """
        let sidecar = Data("""
        {"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["hash"],"x":["学\(nonbreakingSpace)校"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!runtime",0,null,null,null,null,null,null,0,0,0]]}
        """.utf8)

        let payload = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: Data(source.utf8),
            segmentSidecar: sidecar
        )
        let output = String(decoding: payload.documentHTML, as: UTF8.self)

        XCTAssertTrue(payload.isAuthoritativelyProcessed)
        XCTAssertTrue(output.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(output.contains("xmlns=\"http://www.w3.org/1999/xhtml\""))
        XCTAssertTrue(output.contains("<title>A &amp; B</title>"))
        XCTAssertTrue(output.contains(body))
        XCTAssertTrue(output.contains("<img src=\"cover.jpg\" />"))
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(payload))
    }

    func testAuthorityDigestIgnoresOnlyBodyInsertedMarkerAndBindsRubyText() throws {
        let html = """
        <body><m-c pid="p"><m-s sid="s" o="true"><m-m id="m"><ruby><rb>猫</rb><rt>ねこ</rt></ruby></m-m></m-s></m-c></body>
        """
        let sidecar = Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["猫"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        let payload = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: Data(html.utf8),
            segmentSidecar: sidecar
        )

        XCTAssertTrue(payload.isAuthoritativelyProcessed)
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(payload))

        var tamperedEnvelope = Data(encodedEbookProcessedSectionCacheValue(payload))
        let rubyRange = try XCTUnwrap(tamperedEnvelope.range(of: Data("ねこ".utf8)))
        tamperedEnvelope.replaceSubrange(rubyRange, with: Data("ネコ".utf8))

        XCTAssertNil(decodedEbookProcessedSectionCacheValue(Array(tamperedEnvelope)))
    }

    func testCompletionProofIsSourceBoundSingleUseAndCoversJapaneseScalarFamilies() {
        let source = "<html><body><m-s sid=\"s\" o=\"true\">本文</m-s></body></html>"
        let proof = EbookReaderProcessingCompletionProof.forTesting(sourceHTML: source)
        let first = proof.complete(documentHTML: Data(source.utf8), segmentSidecar: Data())
        let second = proof.complete(documentHTML: Data(source.utf8), segmentSidecar: Data())

        XCTAssertTrue(first.isAuthoritativelyProcessed)
        XCTAssertFalse(second.isAuthoritativelyProcessed)

        for uncoveredJapanese in ["ｶﾀｶﾅ", "\u{1B001}", "々", "〳"] {
            let html = "<html><body>\(uncoveredJapanese)</body></html>"
            let result = EbookReaderProcessingCompletionProof.forTesting(sourceHTML: html)
                .complete(documentHTML: Data(html.utf8), segmentSidecar: Data())
            XCTAssertFalse(result.isAuthoritativelyProcessed, uncoveredJapanese)
        }

        let changed = "<html><body><m-s sid=\"s\" o=\"true\">別文</m-s></body></html>"
        let sourceBound = EbookReaderProcessingCompletionProof.forTesting(sourceHTML: source)
            .complete(documentHTML: Data(changed.utf8), segmentSidecar: Data())
        XCTAssertFalse(sourceBound.isAuthoritativelyProcessed)

        let rubySource = "<html><body><m-s sid=\"s\" o=\"true\"><ruby>猫<rt>ねこ</rt></ruby></m-s></body></html>"
        let changedRuby = "<html><body><m-s sid=\"s\" o=\"true\"><ruby class=\"mnb-src\">猫<rt>にゃん</rt></ruby></m-s></body></html>"
        let rubyBound = EbookReaderProcessingCompletionProof.forTesting(
            sourceHTML: rubySource
        ).complete(
            documentHTML: Data(changedRuby.utf8),
            segmentSidecar: Data()
        )
        XCTAssertFalse(rubyBound.isAuthoritativelyProcessed)

        let generatedRuby = "<html><body><m-s sid=\"s\" o=\"true\"><ruby class=\"mnb-gen\">本文<rt>ほんぶん</rt></ruby></m-s></body></html>"
        let generatedRubyResult = EbookReaderProcessingCompletionProof.forTesting(
            sourceHTML: source
        ).complete(
            documentHTML: Data(generatedRuby.utf8),
            segmentSidecar: Data()
        )
        XCTAssertTrue(generatedRubyResult.isAuthoritativelyProcessed)
    }

    func testZeroMatchCoverageExemptsNonRenderedContainersAndRubyAnnotations() {
        let html = """
        <body><script>const 日本語 = true;</script><style>.日本語 { color: red; }</style><ruby>A<rt>かな</rt><rp>（</rp></ruby> Plain text.</body>
        """
        let payload = EbookProcessedSectionPayload.successfulReaderProcessing(
            documentHTML: Data(html.utf8),
            segmentSidecar: Data()
        )

        XCTAssertTrue(payload.isAuthoritativelyProcessed)
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(payload))
    }

    func testIncompletePayloadCannotForgeOrPublishSidecarAuthority() {
        let document = Data("<m-c pid=\"p\"><m-s sid=\"s\" o=\"true\"><m-m id=\"m\">本文</m-m></m-s></m-c>".utf8)
        let sidecar = Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["本文"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)
        let incomplete = EbookProcessedSectionPayload(
            documentHTML: document,
            segmentSidecar: sidecar
        )

        let published = publishingCanonicalReaderSegmentSidecar(
            incomplete,
            scheme: .ebook
        )

        XCTAssertFalse(incomplete.isAuthoritativelyProcessed)
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(incomplete))
        XCTAssertNil(published.headDescriptor)
        XCTAssertNil(published.endpointURL)
        XCTAssertEqual(published.canonicalSidecarByteCount, 0)
    }

    func testHTMLTransformAppendingUncoveredJapaneseRevokesAuthority() async throws {
        let source = "<html><head></head><body><m-c pid=\"p\"><m-s sid=\"s\" o=\"true\"><m-m id=\"m\">本文</m-m></m-s></m-c></body></html>"
        let sidecar = Data(#"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["本文"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#.utf8)

        let result = try await ebookTextProcessor(
            contentURL: URL(string: "ebook://ebook/load/local/book.epub")!,
            sectionLocation: "chapter.xhtml",
            content: source,
            contentFingerprint: "content",
            isCacheWarmer: false,
            processReadabilityContent: nil,
            processHTMLDocument: { _, _, completionProof in
                completionProof.complete(
                    documentHTML: Data(source.utf8),
                    segmentSidecar: sidecar
                )
            },
            processHTMLBytes: nil,
            processHTML: { html, _ in
                html.replacingOccurrences(of: "</body>", with: "<p>未処理の追記</p></body>")
            }
        )
        let published = publishingCanonicalReaderSegmentSidecar(result, scheme: .ebook)

        XCTAssertFalse(result.isAuthoritativelyProcessed)
        XCTAssertNil(published.headDescriptor)
        XCTAssertNil(published.endpointURL)
    }

    func testInlineSharedReaderFontCSSInjectsBothDirectionalFamilies() throws {
        let doc = try SwiftSoup.parse("<html><head></head><body class=\"readability-mode\"><p>本文</p></body></html>")
        let css = """
        @font-face {
          font-family: 'YuKyokasho';
          src: url("data:font/woff2;base64,AAAA") format("woff2");
        }
        """

        try upsertInlineSharedReaderFontCSS(css, in: doc)

        let style = try XCTUnwrap(doc.getElementById("mnb-custom-fonts-inline"))
        let script = try XCTUnwrap(doc.getElementById("mnb-custom-fonts-inline-bootstrap"))
        let styleText = try style.html()
        let scriptText = try script.html()

        XCTAssertTrue(styleText.contains("font-family: 'YuKyokasho';"))
        XCTAssertTrue(styleText.contains("font-family: 'YuKyokasho Yoko';"))
        XCTAssertTrue(scriptText.contains("manabiReaderFontCSSText"))
        XCTAssertTrue(scriptText.contains("manabiReaderFontInjectionMode"))
        XCTAssertTrue(scriptText.contains("manabiHorizontalFontFamilyName"))
        XCTAssertTrue(scriptText.contains("manabiVerticalFontFamilyName"))
        XCTAssertEqual(try doc.getElementsByTag("html").first()?.attr("data-mnb-horizontal-font-family"), "YuKyokasho")
        XCTAssertEqual(try doc.getElementsByTag("html").first()?.attr("data-mnb-vertical-font-family"), "YuKyokasho Yoko")
        XCTAssertTrue((try doc.getElementsByTag("html").first()?.attr("style") ?? "").contains("--mnb-content-font: 'YuKyokasho';"))
        XCTAssertTrue((try doc.body()?.attr("style") ?? "").contains("--mnb-content-vertical-font: 'YuKyokasho Yoko';"))
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

        XCTAssertTrue(result.contains("<HEAD><base href=\"ebook://ebook/entry-source/token/chapter.xhtml?x=1&amp;y=2\">"))
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
            "<!doctype html><html><head><base href=\"ebook://ebook/entry-source/token/chapter.xhtml\"></head><body data-test=\"ok\"><section>本文</section></body></html>"
        )
    }

    func testResponseMetadataScannerHandlesGreaterThanInsideQuotedAttributesAndInjectsPresentation() {
        let html = "<HTML data-note='1>0'><HEAD data-note=\"2>1\"></HEAD><BODY data-note='3>2' style='color:red'>本文</BODY></HTML>"
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
        XCTAssertTrue(result.contains("<BODY data-note='3>2' style='color:red;font-size:18px!important;' data-mnb-dark-theme=\"current\" data-mnb-presentation-revision=\"presentation-1\" data-mnb-presentation-schema-version=\"1\" data-response=\"ready\">"))
    }

    func testResponseMetadataReplacesManagedPresentationAttributesBeforeLayout() {
        let html = """
        <html><head></head><body data-mnb-dark-theme="stale" data-mnb-settings-initialized="false" data-publisher="kept" style="color:red;font-size:9px">Text</body></html>
        """
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
            )
        ), as: UTF8.self)

        XCTAssertEqual(result.components(separatedBy: "data-mnb-dark-theme=").count - 1, 1)
        XCTAssertEqual(result.components(separatedBy: "data-mnb-settings-initialized=").count - 1, 1)
        XCTAssertTrue(result.contains("data-mnb-dark-theme=\"current\""))
        XCTAssertTrue(result.contains("data-mnb-settings-initialized=\"true\""))
        XCTAssertTrue(result.contains("data-mnb-presentation-schema-version=\"1\""))
        XCTAssertTrue(result.contains("data-mnb-presentation-revision=\"presentation-2\""))
        XCTAssertTrue(result.contains("data-publisher=\"kept\""))
        XCTAssertFalse(result.contains("not-allowlisted"))
        XCTAssertTrue(result.contains("style=\"color:red;font-size:9px;font-size:18px!important;\""))
        XCTAssertFalse(result.contains("background:red"))
        XCTAssertFalse(result.contains("display:none"))
    }

    func testNativeSectionPrewarmReadsEntryAndRunsCacheWarmerProcessor() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let contentDirectory = packageRoot
            .appendingPathComponent("item/xhtml", isDirectory: true)
        let chapterURL = contentDirectory
            .appendingPathComponent("chapter.xhtml")
        let chapterHTML = "<html><body>native prewarm</body></html>"

        try FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        try Data(chapterHTML.utf8).write(to: chapterURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        let contentURL = URL(string: "ebook://ebook/load/local/Books/test.epub")!
        let actor = EBookProcessingActor(
            ebookTextProcessor: { receivedContentURL, sectionHref, text, _, isCacheWarmer, _, _, _, _ in
                XCTAssertEqual(receivedContentURL, contentURL)
                XCTAssertEqual(sectionHref, "item/xhtml/chapter.xhtml")
                XCTAssertEqual(text, chapterHTML)
                XCTAssertTrue(isCacheWarmer)
                return ebookTestPayload("<html><body>processed</body></html>")
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.prewarm(
            contentURL: contentURL,
            sectionHref: "item/xhtml/chapter.xhtml",
            source: source
        )

        XCTAssertEqual(result.sectionHref, "item/xhtml/chapter.xhtml")
        XCTAssertEqual(result.requestBytes, chapterHTML.utf8.count)
        XCTAssertEqual(result.responseBytes, "<html><body>processed</body></html>".utf8.count)
        XCTAssertTrue(result.pageStatsRequested)
        XCTAssertEqual(result.pageStatsOutcome, .unsupported)
    }

    func testReaderPackageDirectorySourceRejectsSymlinksEscapingThePackageRoot() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let internalFileURL = packageRoot.appendingPathComponent("internal.xhtml")
        let outsideFileURL = temporaryRoot.appendingPathComponent("outside.xhtml")
        let internalLinkURL = packageRoot.appendingPathComponent("internal-link.xhtml")
        let escapingLinkURL = packageRoot.appendingPathComponent("escaping-link.xhtml")

        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: internalFileURL)
        try Data("outside".utf8).write(to: outsideFileURL)
        try FileManager.default.createSymbolicLink(at: internalLinkURL, withDestinationURL: internalFileURL)
        try FileManager.default.createSymbolicLink(at: escapingLinkURL, withDestinationURL: outsideFileURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        XCTAssertEqual(
            String(decoding: try source.readEntry(subpath: "internal-link.xhtml"), as: UTF8.self),
            "inside"
        )
        let enumeratedPaths = try source.enumerateEntries().map(\.path)
        XCTAssertTrue(enumeratedPaths.contains("internal-link.xhtml"))
        XCTAssertFalse(enumeratedPaths.contains("escaping-link.xhtml"))
        XCTAssertThrowsError(try source.readEntry(subpath: "escaping-link.xhtml")) { error in
            guard case ReaderPackageEntrySourceError.invalidSubpath = error else {
                XCTFail("Expected invalidSubpath, received \(error)")
                return
            }
        }
    }

    func testReaderPackageDirectoryEnumerationHandlesStandardizedRootPaths() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let contentDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)
        let chapterURL = contentDirectory
            .appendingPathComponent("chapter1.xhtml")

        try FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: chapterURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        let entries = try source.enumerateEntries()

        XCTAssertEqual(entries.map(\.path), ["OPS/chapter1.xhtml"])
    }

    func testReaderPackageEntrySourceCacheEvictsLeastRecentlyUsedBooks() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        func makePackage(index: Int) throws -> (packageURL: URL, readerURL: URL) {
            let packageURL = temporaryRoot
                .appendingPathComponent("book-\(index).epub", isDirectory: true)
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            try Data("<html>\(index)</html>".utf8)
                .write(to: packageURL.appendingPathComponent("chapter.xhtml"))
            var components = URLComponents(string: "ebook://ebook/load/local/Books/book-\(index).epub")!
            components.queryItems = [
                URLQueryItem(name: "diagnosticLocalFilePath", value: packageURL.path),
            ]
            return (packageURL, try XCTUnwrap(components.url))
        }

        let first = try makePackage(index: 1)
        let second = try makePackage(index: 2)
        let third = try makePackage(index: 3)
        let fourth = try makePackage(index: 4)
        let cache = ReaderPackageEntrySourceCache(countLimit: 2)
        let fileManager = ReaderFileManager()

        _ = try await cache.cachedSource(forPackageURL: first.readerURL, readerFileManager: fileManager)
        _ = try await cache.cachedSource(forPackageURL: second.readerURL, readerFileManager: fileManager)
        _ = try await cache.cachedSource(forPackageURL: third.readerURL, readerFileManager: fileManager)

        let initialCount = await cache.cachedSourceCountForTesting()
        let initialOrder = await cache.cachedSourcePathsInLRUOrderForTesting()
        XCTAssertEqual(initialCount, 2)
        XCTAssertEqual(
            initialOrder,
            [second.packageURL.standardizedFileURL.path, third.packageURL.standardizedFileURL.path]
        )

        _ = try await cache.cachedSource(forPackageURL: second.readerURL, readerFileManager: fileManager)
        _ = try await cache.cachedSource(forPackageURL: fourth.readerURL, readerFileManager: fileManager)

        let finalOrder = await cache.cachedSourcePathsInLRUOrderForTesting()
        XCTAssertEqual(
            finalOrder,
            [second.packageURL.standardizedFileURL.path, fourth.packageURL.standardizedFileURL.path]
        )
    }

    func testReaderPackageEntrySourceCacheDoesNotPublishFromAnAlreadyCancelledRequest() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageURL = temporaryRoot.appendingPathComponent("cancelled.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data("<html></html>".utf8)
            .write(to: packageURL.appendingPathComponent("chapter.xhtml"))
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        var continuation: AsyncStream<Void>.Continuation!
        let startStream = AsyncStream<Void> { continuation = $0 }
        var components = URLComponents(string: "ebook://ebook/load/local/Books/cancelled.epub")!
        components.queryItems = [
            URLQueryItem(name: "diagnosticLocalFilePath", value: packageURL.path),
        ]
        let readerURL = try XCTUnwrap(components.url)
        let cache = ReaderPackageEntrySourceCache(countLimit: 2)
        let fileManager = ReaderFileManager()

        let request = Task {
            var iterator = startStream.makeAsyncIterator()
            _ = await iterator.next()
            return try await cache.cachedSource(
                forPackageURL: readerURL,
                readerFileManager: fileManager
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
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        let cachedCount = await cache.cachedSourceCountForTesting()
        XCTAssertEqual(cachedCount, 0)
    }

    func testReaderPackageArchiveSourceEnumeratesAndReadsEntriesWithoutExpansion() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("book.epub")
        let chapterPath = "OPS/chapter1.xhtml"
        let chapterHTML = "<html><body>chapter</body></html>"

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        guard let archive = Archive(url: archiveURL, accessMode: .create) else {
            XCTFail("Expected archive to be created")
            return
        }
        try archive.addEntry(with: chapterPath, type: .file, uncompressedSize: Int64(chapterHTML.utf8.count)) { position, size in
            let bytes = Array(chapterHTML.utf8)
            return Data(bytes[Int(position)..<Int(position) + size])
        }

        let source = try ReaderPackageEntrySource(localURL: archiveURL)
        let entries = try source.enumerateEntries()

        XCTAssertEqual(entries.map(\.path), [chapterPath])
        XCTAssertEqual(String(decoding: try source.readEntry(subpath: chapterPath), as: UTF8.self), chapterHTML)
    }

    func testReaderPackageArchiveSourceAdvertisesOnlyFirstAddressableEntryPerPath() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("book.epub")
        let firstEntryData = Data("first".utf8)
        let duplicateEntryData = Data("second-is-longer".utf8)

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        guard let archive = Archive(url: archiveURL, accessMode: .create) else {
            XCTFail("Expected archive to be created")
            return
        }
        func addEntry(path: String, data: Data) throws {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count)
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        try addEntry(path: "OPS/chapter.xhtml", data: firstEntryData)
        try addEntry(path: "../outside.xhtml", data: Data("outside".utf8))
        try addEntry(path: "OPS\\windows.xhtml", data: Data("windows".utf8))
        try addEntry(path: "OPS/chapter.xhtml", data: duplicateEntryData)

        let source = try ReaderPackageEntrySource(localURL: archiveURL)

        XCTAssertEqual(
            try source.enumerateEntries(),
            [ReaderPackageEntryMetadata(path: "OPS/chapter.xhtml", size: firstEntryData.count)]
        )
        XCTAssertEqual(
            String(decoding: try source.readEntry(subpath: "OPS/chapter.xhtml"), as: UTF8.self),
            "first"
        )
        XCTAssertThrowsError(try source.readEntry(subpath: "../outside.xhtml"))
        XCTAssertThrowsError(try source.readEntry(subpath: "OPS\\windows.xhtml"))
    }

    func testReaderPackageResourceLimitsRejectArchiveEntryCountAndAggregateSize() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("limited.epub")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        guard let archive = Archive(url: archiveURL, accessMode: .create) else {
            XCTFail("Expected archive to be created")
            return
        }
        let first = Data(repeating: 1, count: 4)
        let second = Data(repeating: 2, count: 4)
        for (path, data) in [("one.xhtml", first), ("two.xhtml", second)] {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        let countLimited = try ReaderPackageEntrySource(
            localURL: archiveURL,
            limits: ReaderPackageResourceLimits(
                maxEntryCount: 1,
                maxEntryBytes: 10,
                maxAggregateUncompressedBytes: 100
            )
        )
        XCTAssertThrowsError(try countLimited.enumerateEntries()) { error in
            guard case ReaderPackageEntrySourceError.entryCountExceeded(limit: 1) = error else {
                XCTFail("Expected entry-count limit, received \(error)")
                return
            }
        }

        let aggregateLimited = try ReaderPackageEntrySource(
            localURL: archiveURL,
            limits: ReaderPackageResourceLimits(
                maxEntryCount: 10,
                maxEntryBytes: 10,
                maxAggregateUncompressedBytes: 7
            )
        )
        XCTAssertThrowsError(try aggregateLimited.enumerateEntries()) { error in
            guard case ReaderPackageEntrySourceError.aggregateSizeExceeded(_, 7) = error else {
                XCTFail("Expected aggregate-size limit, received \(error)")
                return
            }
        }
    }

    func testReaderPackageDirectoryReadStreamsAndRejectsAdvertisedEntrySize() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot.appendingPathComponent("limited.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 8).write(to: packageRoot.appendingPathComponent("chapter.xhtml"))
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let source = try ReaderPackageEntrySource(
            localURL: packageRoot,
            limits: ReaderPackageResourceLimits(
                maxEntryCount: 10,
                maxEntryBytes: 4,
                maxAggregateUncompressedBytes: 100
            )
        )
        XCTAssertThrowsError(try source.readEntry(subpath: "chapter.xhtml")) { error in
            guard case ReaderPackageEntrySourceError.entrySizeExceeded(
                path: "chapter.xhtml",
                size: 8,
                limit: 4
            ) = error else {
                XCTFail("Expected per-entry limit, received \(error)")
                return
            }
        }
    }

    func testReaderPackageSourceReportsCorruptArchiveAsTypedError() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("corrupt.epub")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try Data("not a ZIP archive".utf8).write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        XCTAssertThrowsError(try ReaderPackageEntrySource(localURL: archiveURL)) { error in
            guard case ReaderPackageEntrySourceError.packageCorrupt = error else {
                XCTFail("Expected typed corrupt-package error, received \(error)")
                return
            }
        }
    }

    func testCacheWarmerProcessingReturnsProcessedContent() async throws {
        let expectedHTML = "<html><body><manabi-segment>cached</manabi-segment></body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in ebookTestPayload(expectedHTML) },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
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

    func testCacheWarmerWithoutProcessorFallsBackToOriginalText() async throws {
        let originalText = "<html><body>raw</body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessor: nil,
            processReadabilityContent: nil,
            processHTMLDocument: nil,
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
        XCTAssertFalse(result.isAuthoritativelyProcessed)
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
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testEbookTextProcessorRejectsSuccessfulReadabilityResultAfterTaskCancellation() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))
        let task = Task {
            try await ebookTextProcessor(
                contentURL: contentURL,
                sectionLocation: "item/xhtml/title.xhtml",
                content: "<html><body>Original</body></html>",
                contentFingerprint: "fingerprint",
                isCacheWarmer: false,
                processReadabilityContent: { content, _, sectionURL, _, _, _, _ in
                    withUnsafeCurrentTask { currentTask in
                        currentTask?.cancel()
                    }
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
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testEbookTextProcessorTreatsTaskCancellationAsCancellationEvenForAnotherError() async throws {
        enum ExpectedProcessingError: Error {
            case failedAfterCancellation
        }

        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))
        let task = Task {
            try await ebookTextProcessor(
                contentURL: contentURL,
                sectionLocation: "item/xhtml/title.xhtml",
                content: "<html><body>Original</body></html>",
                contentFingerprint: "fingerprint",
                isCacheWarmer: false,
                processReadabilityContent: { _, _, _, _, _, _, _ in
                    withUnsafeCurrentTask { currentTask in
                        currentTask?.cancel()
                    }
                    throw ExpectedProcessingError.failedAfterCancellation
                },
                processHTMLDocument: nil,
                processHTMLBytes: nil,
                processHTML: nil
            )
        }

        do {
            _ = try await task.value
            XCTFail("Cancelled processing must not become a recoverable raw fallback")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
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

    func testPartiallyMutatedReaderFailureIsNonAuthoritativeAndIsNotCached() async throws {
        enum ExpectedProcessingError: Error {
            case failedAfterPartialMutation
        }

        let cacheWriteCount = EbookTestInvocationCounter()
        let source = "<html><body>Original</body></html>"
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheWriter: { _, _, _, _ in
                await cacheWriteCount.increment()
            },
            ebookTextProcessor: ebookTextProcessor,
            processReadabilityContent: nil,
            processHTMLDocument: { document, _, _ in
                try document.body()?.append("<m-m id='partial'>猫</m-m>")
                throw ExpectedProcessingError.failedAfterPartialMutation
            },
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/partial.xhtml",
            text: source,
            contentFingerprint: "partial-fingerprint",
            isCacheWarmer: false
        )

        XCTAssertEqual(result.documentHTML, Data(source.utf8))
        XCTAssertTrue(result.segmentSidecar.isEmpty)
        XCTAssertFalse(result.isAuthoritativelyProcessed)
        let writeCount = await cacheWriteCount.count
        XCTAssertEqual(writeCount, 0)
    }

    func testSectionProcessingDeduperCoalescesEquivalentInFlightRequests() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
        )
        let gate = EbookTestGate()
        let invocationCounter = EbookTestInvocationCounter()
        let started = expectation(description: "processing starts")
        let deduper = EBookSectionProcessingDeduper()

        let firstTask = Task {
            try await deduper.process(key: key) {
                await invocationCounter.increment()
                started.fulfill()
                await gate.waitUntilReleased()
                return ebookTestPayload("shared")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let secondTask = Task {
            try await deduper.process(key: key) {
                XCTFail("Equivalent in-flight work should reuse the active operation")
                return ebookTestPayload("duplicate")
            }
        }
        for _ in 0..<1_000 {
            if await deduper.inFlightWaiterCountForTesting(key: key) > 0 {
                break
            }
            await Task.yield()
        }
        let waiterCount = await deduper.inFlightWaiterCountForTesting(key: key)
        XCTAssertEqual(waiterCount, 1)
        await gate.release()

        let first = try await firstTask.value
        let second = try await secondTask.value
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(String(decoding: first.payload.documentHTML, as: UTF8.self), "shared")
        XCTAssertEqual(String(decoding: second.payload.documentHTML, as: UTF8.self), "shared")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertTrue(second.didCoalesce)
        XCTAssertEqual(invocationCount, 1)
    }

    func testSectionProcessingDeduperKeepsSharedProducerAliveWhenOriginalCallerIsCancelled() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
        )
        let gate = EbookTestGate()
        let invocationCounter = EbookTestInvocationCounter()
        let started = expectation(description: "shared producer starts")
        let deduper = EBookSectionProcessingDeduper()

        let originalCaller = Task {
            try await deduper.process(key: key) {
                await invocationCounter.increment()
                started.fulfill()
                await gate.waitUntilReleased()
                try Task.checkCancellation()
                return ebookTestPayload("shared-after-cancellation")
            }
        }
        await fulfillment(of: [started], timeout: 1)

        let activeWaiter = Task {
            try await deduper.process(key: key) {
                XCTFail("The active waiter must reuse the independent shared producer")
                return ebookTestPayload("duplicate")
            }
        }
        for _ in 0..<1_000 {
            if await deduper.inFlightWaiterCountForTesting(key: key) > 0 {
                break
            }
            await Task.yield()
        }
        let waiterCount = await deduper.inFlightWaiterCountForTesting(key: key)
        XCTAssertEqual(waiterCount, 1)

        originalCaller.cancel()
        await gate.release()

        do {
            _ = try await originalCaller.value
            XCTFail("The cancelled caller must retain its own cancellation result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        let activeResult = try await activeWaiter.value
        XCTAssertEqual(
            String(decoding: activeResult.payload.documentHTML, as: UTF8.self),
            "shared-after-cancellation"
        )
        XCTAssertTrue(activeResult.didCoalesce)
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(invocationCount, 1)
    }

    func testSectionProcessingDeduperCancelledWaiterReturnsBeforeSharedProducerCompletes() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
        )
        let gate = EbookTestGate()
        let started = expectation(description: "shared producer starts")
        let cancelledWaiterFinished = expectation(description: "cancelled waiter finishes promptly")
        let deduper = EBookSectionProcessingDeduper()

        let activeCaller = Task {
            try await deduper.process(key: key) {
                started.fulfill()
                await gate.waitUntilReleased()
                return ebookTestPayload("active-result")
            }
        }
        await fulfillment(of: [started], timeout: 1)

        let cancelledWaiter = Task {
            try await deduper.process(key: key) {
                XCTFail("The coalesced waiter must not start another producer")
                return ebookTestPayload("duplicate")
            }
        }
        for _ in 0..<1_000 {
            if await deduper.inFlightWaiterCountForTesting(key: key) > 0 {
                break
            }
            await Task.yield()
        }

        let cancellationObserver = Task {
            do {
                _ = try await cancelledWaiter.value
                XCTFail("The cancelled waiter must not wait for the shared producer")
            } catch is CancellationError {
                cancelledWaiterFinished.fulfill()
            } catch {
                XCTFail("Expected CancellationError, received \(error)")
            }
        }
        cancelledWaiter.cancel()
        await fulfillment(of: [cancelledWaiterFinished], timeout: 1)

        await gate.release()
        let activeResult = try await activeCaller.value
        _ = await cancellationObserver.result
        XCTAssertEqual(String(decoding: activeResult.payload.documentHTML, as: UTF8.self), "active-result")
    }

    func testSectionProcessingDeduperCancelsProducerWhenItsLastWaiterCancels() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
        )
        let producerStarted = expectation(description: "producer starts")
        let producerCancelled = expectation(description: "orphaned producer is cancelled")
        let callerCancelled = expectation(description: "last waiter finishes with cancellation")
        let deduper = EBookSectionProcessingDeduper()

        let onlyCaller = Task {
            try await deduper.process(key: key) {
                producerStarted.fulfill()
                return try await withTaskCancellationHandler {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return ebookTestPayload("unexpected")
                } onCancel: {
                    producerCancelled.fulfill()
                }
            }
        }
        await fulfillment(of: [producerStarted], timeout: 1)

        let cancellationObserver = Task {
            do {
                _ = try await onlyCaller.value
                XCTFail("The last cancelled waiter must not receive a result")
            } catch is CancellationError {
                callerCancelled.fulfill()
            } catch {
                XCTFail("Expected CancellationError, received \(error)")
            }
        }
        onlyCaller.cancel()
        await fulfillment(of: [callerCancelled, producerCancelled], timeout: 1)
        _ = await cancellationObserver.result

        let replacement = try await deduper.process(key: key) {
            ebookTestPayload("replacement")
        }
        XCTAssertEqual(String(decoding: replacement.payload.documentHTML, as: UTF8.self), "replacement")
        XCTAssertFalse(replacement.didCoalesce)
    }

    func testProcessedSectionCacheProbePreservesCancellationAfterReaderReturns() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let gate = EbookTestGate()
        let cacheReadStarted = expectation(description: "cache read starts")

        let probe = Task {
            try await probeEbookProcessedSectionCache(
                reader: { _, _, _ in
                    cacheReadStarted.fulfill()
                    await gate.waitUntilReleased()
                    return nil
                },
                contentURL: contentURL,
                location: "chapter.xhtml",
                contentFingerprint: "fingerprint"
            )
        }
        await fulfillment(of: [cacheReadStarted], timeout: 1)
        probe.cancel()
        await gate.release()

        do {
            _ = try await probe.value
            XCTFail("Cancellation must not become a cache miss")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testProcessedSectionCacheProbePropagatesReaderCancellation() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))

        do {
            _ = try await probeEbookProcessedSectionCache(
                reader: { _, _, _ in throw CancellationError() },
                contentURL: contentURL,
                location: "chapter.xhtml",
                contentFingerprint: "fingerprint"
            )
            XCTFail("Reader cancellation must not become a cache miss")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testProcessedSectionCacheProbeRejectsCancellationWithoutAReader() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let gate = EbookTestGate()
        let probeStarted = expectation(description: "probe starts")
        let probe = Task {
            probeStarted.fulfill()
            await gate.waitUntilReleased()
            try await probeEbookProcessedSectionCache(
                reader: nil,
                contentURL: contentURL,
                location: "chapter.xhtml",
                contentFingerprint: "fingerprint"
            )
        }
        await fulfillment(of: [probeStarted], timeout: 1)
        probe.cancel()
        await gate.release()

        do {
            _ = try await probe.value
            XCTFail("Cancellation must not become an unavailable cache result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testProcessedSectionCacheProbeKeepsNonCancellationFailuresRetryable() async throws {
        enum ExpectedCacheError: Error {
            case failed
        }
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))

        let result = try await probeEbookProcessedSectionCache(
            reader: { _, _, _ in throw ExpectedCacheError.failed },
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentFingerprint: "fingerprint"
        )

        XCTAssertNil(result.payload)
        XCTAssertTrue(result.outcome.hasPrefix("error:"))
    }

    func testSectionProcessingDeduplicationDoesNotCrossHandlerOwners() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
        )
        let firstGate = EbookTestGate()
        let firstStarted = expectation(description: "first handler processing starts")
        let secondStarted = expectation(description: "second handler processing starts independently")
        let firstHandler = EbookURLSchemeHandler()
        let secondHandler = EbookURLSchemeHandler()

        let firstTask = Task {
            try await firstHandler.processSectionForRequest(key: key) {
                firstStarted.fulfill()
                await firstGate.waitUntilReleased()
                return ebookTestPayload("first-owner")
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let secondTask = Task {
            try await secondHandler.processSectionForRequest(key: key) {
                secondStarted.fulfill()
                return ebookTestPayload("second-owner")
            }
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        let second = try await secondTask.value
        await firstGate.release()
        let first = try await firstTask.value

        XCTAssertEqual(String(decoding: first.payload.documentHTML, as: UTF8.self), "first-owner")
        XCTAssertEqual(String(decoding: second.payload.documentHTML, as: UTF8.self), "second-owner")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertFalse(second.didCoalesce)
    }

    func testSectionProcessingDeduperProducerInheritsExactProcessingVariantContext() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let variant = EbookProcessingVariant(
            availableDictionaryIDs: ["jmnedict", "jmdict"],
            includeJLPTClasses: true,
            romajiModeEnabled: true
        )
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: variant
        )
        let deduper = EBookSectionProcessingDeduper()

        let result = try await EbookProcessingVariantContext.$current.withValue(variant) {
            try await deduper.process(key: key) {
                XCTAssertEqual(EbookProcessingVariantContext.current, variant)
                return ebookTestPayload("variant-owned")
            }
        }

        XCTAssertEqual(String(decoding: result.payload.documentHTML, as: UTF8.self), "variant-owned")
        XCTAssertFalse(result.didCoalesce)
    }

    func testSectionProcessingDeduperDoesNotCoalesceDifferentProcessingVariants() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let contentData = Data("本文".utf8)
        let firstKey = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: contentData,
            processingVariant: EbookProcessingVariant(
                availableDictionaryIDs: ["jmdict"],
                includeJLPTClasses: false,
                romajiModeEnabled: false
            )
        )
        let secondKey = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: contentData,
            processingVariant: EbookProcessingVariant(
                availableDictionaryIDs: ["jmdict", "jmnedict"],
                includeJLPTClasses: true,
                romajiModeEnabled: true
            )
        )
        let firstGate = EbookTestGate()
        let firstStarted = expectation(description: "first variant starts")
        let secondStarted = expectation(description: "second variant starts independently")
        let invocationCounter = EbookTestInvocationCounter()
        let deduper = EBookSectionProcessingDeduper()

        let firstTask = Task {
            try await deduper.process(key: firstKey) {
                await invocationCounter.increment()
                firstStarted.fulfill()
                await firstGate.waitUntilReleased()
                return ebookTestPayload("first-variant")
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let secondTask = Task {
            try await deduper.process(key: secondKey) {
                await invocationCounter.increment()
                secondStarted.fulfill()
                return ebookTestPayload("second-variant")
            }
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        let secondResult = try await secondTask.value
        await firstGate.release()
        let firstResult = try await firstTask.value

        XCTAssertEqual(String(decoding: firstResult.payload.documentHTML, as: UTF8.self), "first-variant")
        XCTAssertEqual(String(decoding: secondResult.payload.documentHTML, as: UTF8.self), "second-variant")
        XCTAssertFalse(firstResult.didCoalesce)
        XCTAssertFalse(secondResult.didCoalesce)
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(invocationCount, 2)
    }

    func testSectionProcessingDeduperDoesNotRetainCompletedResponses() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
        )
        let deduper = EBookSectionProcessingDeduper()
        let invocationCounter = EbookTestInvocationCounter()

        let first = try await deduper.process(key: key) {
            await invocationCounter.increment()
            return ebookTestPayload("first")
        }
        let second = try await deduper.process(key: key) {
            await invocationCounter.increment()
            return ebookTestPayload("second")
        }

        XCTAssertEqual(String(decoding: first.payload.documentHTML, as: UTF8.self), "first")
        XCTAssertEqual(String(decoding: second.payload.documentHTML, as: UTF8.self), "second")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertFalse(second.didCoalesce)
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(invocationCount, 2)
    }

    func testCacheWarmerDoesNotPopulateDisplayReadyProcessedTextCache() async throws {
        let writerInvocationCounter = EbookTestInvocationCounter()
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheWriter: { _, _, _, _ in
                await writerInvocationCounter.increment()
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                ebookTestPayload("<html><body>warmer result</body></html>")
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        _ = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: true
        )

        let writerInvocationCount = await writerInvocationCounter.count
        XCTAssertEqual(writerInvocationCount, 0)
    }

    func testForegroundProcessingPopulatesDisplayReadyProcessedTextCache() async throws {
        let writerCalled = expectation(description: "display-ready cache writer runs")
        let canonicalJSON = #"{"v":12,"t":{"j":[],"n":[],"s":[],"ns":[],"p":[],"h":["h"],"x":["foreground result"],"sid":["s"],"pid":["p"]},"s":[["!m",0,null,null,null,null,null,null,0,0,0]]}"#
        let processedHTML = "<html><body><m-c pid=\"p\"><m-s sid=\"s\" o=\"true\"><m-m id=\"m\">foreground result</m-m></m-s></m-c><script id=\"mnb-segment-metadata\">\(canonicalJSON)</script></body></html>"
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheWriter: { _, _, _, payload in
                XCTAssertTrue(payload.isAuthoritativelyProcessed)
                XCTAssertTrue(String(decoding: payload.documentHTML, as: UTF8.self).contains("foreground result"))
                XCTAssertEqual(String(decoding: payload.segmentSidecar, as: UTF8.self), canonicalJSON)
                writerCalled.fulfill()
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                let split = try XCTUnwrap(
                    splitCanonicalReaderSegmentSidecar(from: Array(processedHTML.utf8))
                )
                return EbookProcessedSectionPayload.readerProcessingFixture(
                    sourceDocumentHTML: Data(processedHTML.utf8),
                    documentHTML: split.documentHTML,
                    segmentSidecar: split.segmentSidecar
                )
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        _ = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: false
        )

        await fulfillment(of: [writerCalled], timeout: 1)
    }

    func testForegroundProcessingDoesNotCacheNonAuthoritativeFallback() async throws {
        let writerInvocationCounter = EbookTestInvocationCounter()
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheWriter: { _, _, _, _ in
                await writerInvocationCounter.increment()
            },
            ebookTextProcessor: { _, _, text, _, _, _, _, _, _ in
                ebookTestPayload(text, isAuthoritativelyProcessed: false)
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw fallback</body></html>",
            isCacheWarmer: false
        )

        XCTAssertFalse(result.isAuthoritativelyProcessed)
        let writerInvocationCount = await writerInvocationCounter.count
        XCTAssertEqual(writerInvocationCount, 0)
    }
}
