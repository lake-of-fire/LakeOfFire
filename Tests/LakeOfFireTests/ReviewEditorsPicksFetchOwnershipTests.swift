import XCTest
@testable import LakeOfFireReader

@MainActor
private final class ControlledEditorsPicksFetcher {
    typealias Value = ([Publication], String?)

    private var nextID = 0
    private var pending = [
        Int: CheckedContinuation<Value, Never>
    ]()
    private var waiters = [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ]()

    func fetch(_ url: URL) async -> Value {
        nextID += 1
        let id = nextID
        resumeReadyWaiters()
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
        }
    }

    func waitForRequests(_ target: Int) async {
        guard nextID < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }

    func resolve(
        _ id: Int,
        publications: [Publication],
        errorMessage: String? = nil
    ) {
        pending.removeValue(forKey: id)?.resume(
            returning: (publications, errorMessage)
        )
    }

    private func resumeReadyWaiters() {
        var remaining = [
            (target: Int, continuation: CheckedContinuation<Void, Never>)
        ]()
        for waiter in waiters {
            if nextID >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

@MainActor
final class ReviewEditorsPicksFetchOwnershipTests: XCTestCase {
    private func publication(_ title: String) -> Publication {
        Publication(title: title)
    }

    private func waitUntil(
        _ description: String,
        _ predicate: @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func fixture()
        -> (BookLibraryViewModel, ControlledEditorsPicksFetcher) {
        let viewModel = BookLibraryViewModel()
        let fetcher = ControlledEditorsPicksFetcher()
        viewModel.publicationFetcher = { url in
            await fetcher.fetch(url)
        }
        return (viewModel, fetcher)
    }

    func testFetchAllDataDoesNotReturnBeforeCurrentFetchCompletes()
        async {
        let (viewModel, fetcher) = fixture()
        var returned = false

        let task = Task { @MainActor in
            await viewModel.fetchAllData()
            returned = true
        }

        await fetcher.waitForRequests(1)
        await Task.yield()
        XCTAssertFalse(
            returned,
            "refreshable completion must represent completed data refresh"
        )

        fetcher.resolve(1, publications: [publication("current")])
        await task.value

        XCTAssertTrue(returned)
        XCTAssertEqual(viewModel.editorsPicks.map(\.title), ["current"])
    }

    func testOlderSuccessCannotOverwriteNewerSuccess() async {
        let (viewModel, fetcher) = fixture()

        viewModel.fetchEditorsPicks()
        await fetcher.waitForRequests(1)
        viewModel.fetchEditorsPicks()
        await fetcher.waitForRequests(2)

        fetcher.resolve(2, publications: [publication("newer")])
        await waitUntil("newer publication") {
            viewModel.editorsPicks.first?.title == "newer"
        }

        fetcher.resolve(1, publications: [publication("older")])
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(viewModel.editorsPicks.map(\.title), ["newer"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testOlderErrorCannotReplaceNewerSuccess() async {
        let (viewModel, fetcher) = fixture()

        viewModel.fetchEditorsPicks()
        await fetcher.waitForRequests(1)
        viewModel.fetchEditorsPicks()
        await fetcher.waitForRequests(2)

        fetcher.resolve(2, publications: [publication("newer")])
        await waitUntil("newer publication") {
            viewModel.editorsPicks.first?.title == "newer"
        }

        fetcher.resolve(
            1,
            publications: [],
            errorMessage: "older request failed"
        )
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(viewModel.editorsPicks.map(\.title), ["newer"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testOlderSuccessCannotReplaceNewerError() async {
        let (viewModel, fetcher) = fixture()

        viewModel.fetchEditorsPicks()
        await fetcher.waitForRequests(1)
        viewModel.fetchEditorsPicks()
        await fetcher.waitForRequests(2)

        fetcher.resolve(
            2,
            publications: [],
            errorMessage: "newer request failed"
        )
        await waitUntil("newer error") {
            viewModel.errorMessage != nil
        }

        fetcher.resolve(1, publications: [publication("older")])
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(viewModel.editorsPicks.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }
}
