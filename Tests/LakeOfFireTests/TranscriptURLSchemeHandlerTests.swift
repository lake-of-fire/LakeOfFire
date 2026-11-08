import XCTest
@preconcurrency import WebKit
import LakeOfFireCore
@testable import LakeOfFireReader

@MainActor
private final class TranscriptTestSchemeTask: NSObject, @preconcurrency WKURLSchemeTask {
    var request: URLRequest
    private(set) var events: [String] = []
    private(set) var responses: [URLResponse] = []
    private(set) var failures: [Error] = []
    var onResponse: (@MainActor () -> Void)?
    var onData: (@MainActor () -> Void)?
    var onFinish: (@MainActor () -> Void)?
    var onFailure: (@MainActor () -> Void)?

    init(url: URL) {
        request = URLRequest(url: url)
        super.init()
    }

    func didReceive(_ response: URLResponse) {
        responses.append(response)
        events.append("response")
        onResponse?()
    }

    func didReceive(_ data: Data) {
        events.append("data:\(String(decoding: data, as: UTF8.self))")
        onData?()
    }

    func didFinish() {
        events.append("finish")
        onFinish?()
    }

    func didFailWithError(_ error: Error) {
        failures.append(error)
        events.append("failure")
        onFailure?()
    }
}

// Intentionally ignores cancellation so a stopped attempt can return after its successor starts.
@MainActor
private final class TranscriptResponseGate {
    private var callCount = 0
    private var responses: [Int: CheckedContinuation<(String, Data), Error>] = [:]
    private var waiters: [Int: XCTestExpectation] = [:]

    func resolve(_ url: URL) async throws -> (String, Data) {
        try await withCheckedThrowingContinuation { continuation in
            let index = callCount
            callCount += 1
            responses[index] = continuation
            waiters.removeValue(forKey: index)?.fulfill()
        }
    }

    func waitForCall(_ index: Int) async throws {
        if callCount > index { return }
        let entered = XCTestExpectation(description: "Transcript resolver call \(index) started")
        waiters[index] = entered
        let result = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        waiters.removeValue(forKey: index)
        guard result == .completed else {
            throw TranscriptTestError.resolverDidNotStart(index)
        }
    }

    func succeed(_ index: Int, body: String) {
        responses.removeValue(forKey: index)!.resume(returning: ("text/html", Data(body.utf8)))
    }

    func fail(_ index: Int) {
        responses.removeValue(forKey: index)!.resume(throwing: TranscriptTestError.expected)
    }
}

private enum TranscriptTestError: Error {
    case expected
    case resolverDidNotStart(Int)
}

final class TranscriptURLSchemeHandlerTests: XCTestCase {
    @MainActor
    private func makeTask() -> TranscriptTestSchemeTask {
        TranscriptTestSchemeTask(url: URL.transcriptPageURL(key: UUID().uuidString)!)
    }

    @MainActor
    func testImmediateResolverFindsRegisteredAttemptAndCompletesOnce() async throws {
        let handler = TranscriptURLSchemeHandler { _ in ("text/html", Data("ready".utf8)) }
        let task = makeTask()
        let webView = WKWebView()

        handler.webView(webView, start: task)
        let work = try XCTUnwrap(handler.pendingTask(for: task))
        await work.value
        handler.webView(webView, stop: task)

        XCTAssertEqual(task.events, ["response", "data:ready", "finish"])
        XCTAssertEqual(task.responses.first?.mimeType, "text/html")
        XCTAssertEqual(task.responses.first?.expectedContentLength, 5)
        XCTAssertNil(handler.pendingTask(for: task))
    }

    @MainActor
    func testCurrentResolverFailureTerminatesOnce() async throws {
        let handler = TranscriptURLSchemeHandler { _ in throw TranscriptTestError.expected }
        let task = makeTask()
        let webView = WKWebView()

        handler.webView(webView, start: task)
        let work = try XCTUnwrap(handler.pendingTask(for: task))
        await work.value
        handler.webView(webView, stop: task)

        XCTAssertEqual(task.events, ["failure"])
        XCTAssertTrue(task.failures.first is TranscriptTestError)
        XCTAssertNil(handler.pendingTask(for: task))
    }

    @MainActor
    func testStopDuringResponseSuppressesDataAndFinish() async throws {
        let handler = TranscriptURLSchemeHandler { _ in ("text/html", Data("old".utf8)) }
        let task = makeTask()
        let webView = WKWebView()
        task.onResponse = { handler.webView(webView, stop: task) }
        defer { task.onResponse = nil }

        handler.webView(webView, start: task)
        let work = try XCTUnwrap(handler.pendingTask(for: task))
        await work.value

        XCTAssertEqual(task.events, ["response"])
        XCTAssertNil(handler.pendingTask(for: task))
    }

    @MainActor
    func testStopDuringDataSuppressesFinish() async throws {
        let handler = TranscriptURLSchemeHandler { _ in ("text/html", Data("old".utf8)) }
        let task = makeTask()
        let webView = WKWebView()
        task.onData = { handler.webView(webView, stop: task) }
        defer { task.onData = nil }

        handler.webView(webView, start: task)
        let work = try XCTUnwrap(handler.pendingTask(for: task))
        await work.value

        XCTAssertEqual(task.events, ["response", "data:old"])
        XCTAssertNil(handler.pendingTask(for: task))
    }

    @MainActor
    func testRestartDuringResponseSuppressesOldDataAndRetainsSuccessor() async throws {
        try await assertRestartDuringCallback(.response)
    }

    @MainActor
    func testRestartDuringDataSuppressesOldFinishAndRetainsSuccessor() async throws {
        try await assertRestartDuringCallback(.data)
    }

    @MainActor
    func testRestartDuringFinishRetainsSuccessor() async throws {
        try await assertRestartDuringCallback(.finish)
    }

    @MainActor
    func testRestartDuringFailureRetainsSuccessor() async throws {
        try await assertRestartDuringCallback(.failure)
    }

    @MainActor
    func testOldSuccessCannotCompleteOrRemoveSameObjectSuccessor() async throws {
        try await assertOldCompletionPreservesSuccessor(failing: false)
    }

    @MainActor
    func testOldFailureCannotFailOrRemoveSameObjectSuccessor() async throws {
        try await assertOldCompletionPreservesSuccessor(failing: true)
    }

    @MainActor
    func testStoppedDelayedResolverCannotDeliver() async throws {
        let gate = TranscriptResponseGate()
        let handler = TranscriptURLSchemeHandler(responseResolver: gate.resolve)
        let task = makeTask()
        let webView = WKWebView()
        handler.webView(webView, start: task)
        let work = try XCTUnwrap(handler.pendingTask(for: task))
        try await gate.waitForCall(0)

        handler.webView(webView, stop: task)
        XCTAssertTrue(work.isCancelled)
        gate.succeed(0, body: "stopped")
        await work.value

        XCTAssertTrue(task.events.isEmpty)
        XCTAssertNil(handler.pendingTask(for: task))
    }

    @MainActor
    func testDefaultInitializerPreservesMissingAssetAndMalformedRequestErrors() async throws {
        let handler = TranscriptURLSchemeHandler()
        let webView = WKWebView()
        let missingAsset = makeTask()
        handler.webView(webView, start: missingAsset)
        let work = try XCTUnwrap(handler.pendingTask(for: missingAsset))
        await work.value
        XCTAssertEqual(missingAsset.events, ["failure"])
        guard case .invalidRoute? = missingAsset.failures.first as? TranscriptURLSchemeHandler.TranscriptSchemeError else {
            return XCTFail("A missing transcript asset must retain main's invalidRoute error")
        }

        let malformed = makeTask()
        malformed.request.url = nil
        handler.webView(webView, start: malformed)
        XCTAssertEqual(malformed.events, ["failure"])
        guard case .notFound? = malformed.failures.first as? TranscriptURLSchemeHandler.TranscriptSchemeError else {
            return XCTFail("A request without a transcript URL must retain main's notFound error")
        }
        XCTAssertNil(handler.pendingTask(for: malformed))
    }

    @MainActor
    func testMalformedRestartRetiresPreviousAttempt() async throws {
        let gate = TranscriptResponseGate()
        let handler = TranscriptURLSchemeHandler(responseResolver: gate.resolve)
        let task = makeTask()
        let webView = WKWebView()
        handler.webView(webView, start: task)
        let old = try XCTUnwrap(handler.pendingTask(for: task))
        try await gate.waitForCall(0)

        task.request.url = nil
        handler.webView(webView, start: task)
        gate.succeed(0, body: "old")
        await old.value

        XCTAssertTrue(old.isCancelled)
        XCTAssertEqual(task.events, ["failure"])
        XCTAssertNil(handler.pendingTask(for: task))
    }

    private enum RestartPoint: Equatable {
        case response, data, finish, failure
    }

    @MainActor
    private func assertRestartDuringCallback(_ point: RestartPoint) async throws {
        let gate = TranscriptResponseGate()
        let handler = TranscriptURLSchemeHandler(responseResolver: gate.resolve)
        let task = makeTask()
        let webView = WKWebView()
        let restart: @MainActor () -> Void = {
            task.onResponse = nil
            task.onData = nil
            task.onFinish = nil
            task.onFailure = nil
            handler.webView(webView, start: task)
        }
        switch point {
        case .response: task.onResponse = restart
        case .data: task.onData = restart
        case .finish: task.onFinish = restart
        case .failure: task.onFailure = restart
        }
        defer {
            task.onResponse = nil
            task.onData = nil
            task.onFinish = nil
            task.onFailure = nil
        }

        handler.webView(webView, start: task)
        let old = try XCTUnwrap(handler.pendingTask(for: task))
        try await gate.waitForCall(0)
        if point == .failure {
            gate.fail(0)
        } else {
            gate.succeed(0, body: "old")
        }
        await old.value

        let successor = try XCTUnwrap(handler.pendingTask(for: task))
        try await gate.waitForCall(1)
        XCTAssertFalse(successor.isCancelled)
        let oldEvents: [String]
        switch point {
        case .response: oldEvents = ["response"]
        case .data: oldEvents = ["response", "data:old"]
        case .finish: oldEvents = ["response", "data:old", "finish"]
        case .failure: oldEvents = ["failure"]
        }
        XCTAssertEqual(task.events, oldEvents)

        gate.succeed(1, body: "new")
        await successor.value
        XCTAssertEqual(task.events, oldEvents + ["response", "data:new", "finish"])
        XCTAssertNil(handler.pendingTask(for: task))
    }

    @MainActor
    private func assertOldCompletionPreservesSuccessor(failing: Bool) async throws {
        let gate = TranscriptResponseGate()
        let handler = TranscriptURLSchemeHandler(responseResolver: gate.resolve)
        let task = makeTask()
        let webView = WKWebView()
        handler.webView(webView, start: task)
        let old = try XCTUnwrap(handler.pendingTask(for: task))
        try await gate.waitForCall(0)

        handler.webView(webView, start: task)
        let successor = try XCTUnwrap(handler.pendingTask(for: task))
        try await gate.waitForCall(1)
        XCTAssertTrue(old.isCancelled)
        if failing {
            gate.fail(0)
        } else {
            gate.succeed(0, body: "old")
        }
        await old.value
        XCTAssertTrue(task.events.isEmpty)
        XCTAssertNotNil(handler.pendingTask(for: task))
        XCTAssertFalse(successor.isCancelled)

        gate.succeed(1, body: "new")
        await successor.value
        XCTAssertEqual(task.events, ["response", "data:new", "finish"])
        XCTAssertNil(handler.pendingTask(for: task))
    }
}
