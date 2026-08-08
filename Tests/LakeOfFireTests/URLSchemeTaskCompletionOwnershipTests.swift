import XCTest
@preconcurrency import WebKit
@testable import LakeOfFireFiles
@testable import LakeOfFireReader

private final class TestURLSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var responses = [URLResponse]()
    private(set) var data = [Data]()
    private(set) var finishCount = 0
    private(set) var failures = [Error]()

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
    }

    func didFailWithError(_ error: Error) {
        failures.append(error)
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
