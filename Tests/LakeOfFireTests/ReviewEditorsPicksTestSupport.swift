import XCTest
@testable import LakeOfFireReader

/// Own every caller and continuation so a failed setup cannot strand teardown.
/// This drives BookLibraryViewModel, not a replacement ownership state machine.
@MainActor
final class ReviewEditorsPicksHarness {
    typealias Value = ([Publication], String?)
    let viewModel = BookLibraryViewModel()
    private(set) var requestCount = 0
    private var pending: [Int: CheckedContinuation<Value, Never>] = [:]
    private var startSignals: [Int: XCTestExpectation] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var finishSignals: [Int: [XCTestExpectation]] = [:]
    private var finished: Set<Int> = []
    private var closed = false

    init() {
        viewModel.publicationFetcher = { [weak self] _ in
            guard let self, !self.closed else { return ([], nil) }
            self.requestCount += 1
            let request = self.requestCount
            // A newly admitted cancelled request can finish immediately; older
            // requests already suspended below deliberately ignore cancellation.
            if Task.isCancelled {
                self.startSignals.removeValue(forKey: request)?.fulfill()
                return ([], nil)
            }
            return await withCheckedContinuation { continuation in
                self.pending[request] = continuation
                self.startSignals.removeValue(forKey: request)?.fulfill()
            }
        }
    }

    @discardableResult
    func start(cancelBeforeAdmission: Bool = false) -> Int {
        let id = tasks.count
        let task = Task { @MainActor in
            if cancelBeforeAdmission { XCTAssertTrue(Task.isCancelled) }
            await self.viewModel.fetchAllData()
            self.finished.insert(id)
            self.finishSignals.removeValue(forKey: id)?.forEach { $0.fulfill() }
        }
        tasks.append(task)
        // This synchronous main-actor section ends before the task can enter.
        if cancelBeforeAdmission { task.cancel() }
        return id
    }

    func cancel(_ id: Int) { tasks[id].cancel() }
    func hasFinished(_ id: Int) -> Bool { finished.contains(id) }

    func waitForRequest(_ request: Int, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        if requestCount >= request { return true }
        let signal = XCTestExpectation(description: "request \(request) started")
        startSignals[request] = signal
        let result = await XCTWaiter.fulfillment(of: [signal], timeout: 2)
        XCTAssertEqual(result, .completed, "request did not start", file: file, line: line)
        return result == .completed
    }

    func waitForCompletion(_ id: Int, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        if !finished.contains(id) {
            let signal = XCTestExpectation(description: "refresh caller \(id) completed")
            finishSignals[id, default: []].append(signal)
            let result = await XCTWaiter.fulfillment(of: [signal], timeout: 2)
            finishSignals[id]?.removeAll { $0 === signal }
            XCTAssertEqual(result, .completed, "refresh caller did not finish", file: file, line: line)
            guard result == .completed else { return false }
        }
        await tasks[id].value
        return true
    }

    func resolve(_ request: Int, publications: [Publication], error: String? = nil,
                 file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation = pending.removeValue(forKey: request) else {
            return XCTFail("request \(request) has no pending continuation", file: file, line: line)
        }
        continuation.resume(returning: (publications, error))
    }

    func cleanup() async {
        // Closing admission first also handles a task entering after setup timed out.
        closed = true
        tasks.forEach { $0.cancel() }
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(returning: ([], nil)) }
        for id in tasks.indices { _ = await waitForCompletion(id) }
    }
}
