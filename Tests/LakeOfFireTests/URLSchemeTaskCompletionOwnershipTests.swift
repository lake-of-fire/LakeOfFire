import XCTest
@preconcurrency import WebKit
import SwiftCloudDrive
import ZIPFoundation
@testable import LakeOfFireContent
@testable import LakeOfFireFiles
@testable import LakeOfFireReader

private final class TestURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var responses = [URLResponse]()
    private(set) var data = [Data]()
    private(set) var finishCount = 0
    private(set) var failures = [any Swift.Error]()
    var onTerminal: (() -> Void)?

    init(request: URLRequest) {
        self.request = request
    }

    func didReceive(_ response: URLResponse) {
        responses.append(response)
    }

    func didReceive(_ data: Data) {
        self.data.append(data)
    }

    func didFinish() {
        finishCount += 1
        onTerminal?()
    }

    func didFailWithError(_ error: any Swift.Error) {
        failures.append(error)
        onTerminal?()
    }
}

private final class LockedCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private func requestWithoutURL() -> URLRequest {
    var request = URLRequest(url: URL(string: "about:blank")!)
    request.url = nil
    return request
}

final class URLSchemeTaskCompletionOwnershipTests: XCTestCase {
    func testCancellationRejectsLaterCompletion() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()

        ownership.begin(task)

        XCTAssertTrue(ownership.cancel(task))
        XCTAssertFalse(ownership.claimCompletion(task))
    }

    func testOnlyOneTerminalClaimSucceeds() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()

        ownership.begin(task)

        XCTAssertTrue(ownership.claimCompletion(task))
        XCTAssertFalse(ownership.claimCompletion(task))
        XCTAssertFalse(ownership.cancel(task))
    }

    func testEqualHashObjectsRetainIndependentOwnership() {
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

    func testCancellationInvokesAttachedWorkCancellationExactlyOnce() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()
        let cancellationCount = LockedCancellationCounter()

        ownership.begin(task)
        XCTAssertTrue(ownership.attachCancellation(task) {
            cancellationCount.increment()
        })

        XCTAssertTrue(ownership.cancel(task))
        XCTAssertEqual(cancellationCount.value, 1)
        XCTAssertFalse(ownership.cancel(task))
        XCTAssertEqual(cancellationCount.value, 1)
    }

    func testLateWorkAttachmentCancelsImmediatelyAfterTaskStops() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()
        let cancellationCount = LockedCancellationCounter()

        ownership.begin(task)
        XCTAssertTrue(ownership.cancel(task))
        XCTAssertFalse(ownership.attachCancellation(task) {
            cancellationCount.increment()
        })
        XCTAssertEqual(cancellationCount.value, 1)
    }

    func testSuccessfulCompletionReleasesWorkWithoutCancellingIt() {
        let ownership = URLSchemeTaskCompletionOwnership()
        let task = NSObject()
        let cancellationCount = LockedCancellationCounter()

        ownership.begin(task)
        XCTAssertTrue(ownership.attachCancellation(task) {
            cancellationCount.increment()
        })

        XCTAssertTrue(ownership.claimCompletion(task))
        XCTAssertEqual(cancellationCount.value, 0)
        XCTAssertFalse(ownership.cancel(task))
        XCTAssertEqual(cancellationCount.value, 0)
    }

    @MainActor
    func testReaderFileHandlerTerminatesMalformedRequest() {
        let handler = ReaderFileURLSchemeHandler()
        let task = TestURLSchemeTask(request: requestWithoutURL())
        let webView = WKWebView()

        handler.webView(webView, start: task)
        handler.webView(webView, stop: task)

        XCTAssertEqual(task.failures.count, 1)
        XCTAssertEqual(task.finishCount, 0)
        XCTAssertTrue(task.responses.isEmpty)
    }

    @MainActor
    func testReaderFileHandlerRespondsWithPackageEntryMIMEAndEncoding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-package-response-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let drive = try await CloudDrive(storage: .localDirectory(rootURL: root))
        let archiveURL = drive.rootDirectory.appendingPathComponent("book.epub")
        guard let archive = Archive(url: archiveURL, accessMode: .create) else {
            XCTFail("Expected package archive to be created")
            return
        }
        let entries: [(String, Data, String, String?)] = [
            ("cover.jpg", Data([0xFF, 0xD8, 0xFF]), "image/jpeg", nil),
            ("diagram.svg", Data("<svg/>".utf8), "image/svg+xml", "utf-8"),
            ("opaque.unknown-manabi-format", Data([0x01, 0x02]), "application/octet-stream", nil),
        ]
        for (path, data, _, _) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        let manager = ReaderFileManager()
        manager.localDrive = drive
        let handler = ReaderFileURLSchemeHandler()
        await { @ReaderFileURLSchemeActor in
            handler.readerFileManager = manager
        }()
        let webView = WKWebView()

        for (path, data, expectedMIME, expectedEncoding) in entries {
            var components = URLComponents(string: "reader-file://file/load/local/book.epub")!
            components.queryItems = [URLQueryItem(name: "subpath", value: path)]
            let task = TestURLSchemeTask(request: URLRequest(url: try XCTUnwrap(components.url)))
            let terminal = expectation(description: "Package response for \(path)")
            task.onTerminal = { terminal.fulfill() }

            handler.webView(webView, start: task)
            await fulfillment(of: [terminal], timeout: 5)

            XCTAssertTrue(task.failures.isEmpty, path)
            XCTAssertEqual(task.finishCount, 1, path)
            XCTAssertEqual(task.responses.first?.mimeType, expectedMIME, path)
            XCTAssertEqual(task.responses.first?.textEncodingName, expectedEncoding, path)
            XCTAssertEqual(task.data.first, data, path)
        }
    }

    @MainActor
    func testEbookHandlerTerminatesMalformedRequest() {
        let handler = EbookURLSchemeHandler()
        let task = TestURLSchemeTask(request: requestWithoutURL())
        let webView = WKWebView()

        handler.webView(webView, start: task)
        handler.webView(webView, stop: task)

        XCTAssertEqual(task.failures.count, 1)
        XCTAssertEqual(task.finishCount, 0)
        XCTAssertTrue(task.responses.isEmpty)
    }
}
