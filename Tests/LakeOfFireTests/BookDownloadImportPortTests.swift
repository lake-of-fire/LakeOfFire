import Foundation
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
final class BookDownloadImportPortTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/synthetic/日本語.epub")
    private let destination = URL(string: "reader-file://local/owned/book.epub")!

    @MainActor
    private final class SuspendedImport {
        let started = XCTestExpectation(description: "Importer entered")
        private var continuation: CheckedContinuation<URL?, Error>?
        private var result: Result<URL?, Error>?

        func run() async throws -> URL? {
            started.fulfill()
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation {
                continuation = $0
            }
        }

        func finish(_ result: Result<URL?, Error>) {
            self.result = result
            let saved = continuation
            continuation = nil
            saved?.resume(with: result)
        }
    }

    func testInitialStateDoesNotClaimALibraryImport() async {
        let state = BookDownloadImportState()
        XCTAssertFalse(state.isImported)
        XCTAssertNil(state.importedURL)
        XCTAssertNil(state.errorMessage)
    }

    func testRebindingClearsStateOnlyWhenBookIdentityChanges() async {
        let first = BookDownloadImportIdentity(
            remoteURL: URL(string: "https://example.com/first.epub")!,
            localDestination: URL(fileURLWithPath: "/library/first.epub"),
            name: "First"
        )
        let second = BookDownloadImportIdentity(
            remoteURL: URL(string: "https://example.com/second.epub")!,
            localDestination: URL(fileURLWithPath: "/library/second.epub"),
            name: "Second"
        )
        var state = BookDownloadImportState()

        XCTAssertTrue(state.bind(to: first))
        state.receive(.imported(destination))
        XCTAssertTrue(state.isImported)

        XCTAssertFalse(state.bind(to: first))
        XCTAssertTrue(state.isImported)
        XCTAssertEqual(state.importedURL, destination)

        XCTAssertTrue(state.bind(to: second))
        XCTAssertFalse(state.isImported)
        XCTAssertNil(state.importedURL)
        XCTAssertNil(state.errorMessage)

        state.receive(.failed(message: "Offline"))
        XCTAssertFalse(state.bind(to: second))
        XCTAssertEqual(state.errorMessage, "Offline")
    }

    func testRebindingDistinguishesDestinationAndNameChanges() async {
        let remote = URL(string: "https://example.com/book.epub")!
        let first = BookDownloadImportIdentity(
            remoteURL: remote,
            localDestination: URL(fileURLWithPath: "/library/a.epub"),
            name: "Book"
        )
        let moved = BookDownloadImportIdentity(
            remoteURL: remote,
            localDestination: URL(fileURLWithPath: "/library/b.epub"),
            name: "Book"
        )
        let renamed = BookDownloadImportIdentity(
            remoteURL: remote,
            localDestination: moved.localDestination,
            name: "Renamed"
        )
        var state = BookDownloadImportState()

        XCTAssertTrue(state.bind(to: first))
        state.receive(.failed(message: "Old error"))
        XCTAssertTrue(state.bind(to: moved))
        XCTAssertNil(state.errorMessage)
        state.receive(.imported(destination))
        XCTAssertTrue(state.bind(to: renamed))
        XCTAssertFalse(state.isImported)
    }

    func testSuccessRecordsTheActualDestination() async {
        var state = BookDownloadImportState()
        XCTAssertTrue(state.receive(.imported(destination)))
        XCTAssertTrue(state.isImported)
        XCTAssertEqual(state.importedURL, destination)
        XCTAssertNil(state.errorMessage)
    }

    func testFailedImportDoesNotContinueSelectionOrHideRetry() async {
        var state = BookDownloadImportState()
        XCTAssertFalse(state.receive(.failed(message: "Damaged book")))
        XCTAssertFalse(state.isImported)
        XCTAssertNil(state.importedURL)
        XCTAssertEqual(state.errorMessage, "Damaged book")
    }

    func testCancellationDoesNotEraseAnEarlierImportedState() async {
        var state = BookDownloadImportState()
        state.receive(.imported(destination))
        XCTAssertFalse(state.receive(.cancelled))
        XCTAssertTrue(state.isImported)
        XCTAssertEqual(state.importedURL, destination)
        XCTAssertNil(state.errorMessage)
    }

    func testCancellationDoesNotEraseAnEarlierFailure() async {
        var state = BookDownloadImportState()
        state.receive(.failed(message: "Offline"))
        XCTAssertFalse(state.receive(.cancelled))
        XCTAssertFalse(state.isImported)
        XCTAssertEqual(state.errorMessage, "Offline")
    }

    func testMissingImporterResultRemainsRetryable() async {
        var state = BookDownloadImportState()
        var calls = 0
        let result = await ReaderFileImportOperation.perform(.success(source)) { _ in
            calls += 1
            return nil
        }
        XCTAssertFalse(state.receive(result))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(state.isImported)
        XCTAssertEqual(state.errorMessage, "Couldn't import 日本語.epub. Try selecting the file again.")
    }

    func testRetryAfterFailureClearsTheErrorAndContinuesSelection() async {
        var state = BookDownloadImportState()
        let failed = await ReaderFileImportOperation.perform(.success(source)) { _ in nil }
        XCTAssertFalse(state.receive(failed))
        let succeeded = await ReaderFileImportOperation.perform(.success(source)) { _ in self.destination }
        XCTAssertTrue(state.receive(succeeded))
        XCTAssertTrue(state.isImported)
        XCTAssertEqual(state.importedURL, destination)
        XCTAssertNil(state.errorMessage)
    }

    func testTypedMissingImportClearsPriorSuccessAndRemainsRetryable() async {
        var state = BookDownloadImportState()
        XCTAssertTrue(state.receive(.imported(destination)))
        let result = await ReaderFileImportOperation.perform(.success(source)) { url in
            throw ReaderFileImportError.missingResult(url)
        }
        XCTAssertFalse(state.receive(result))
        XCTAssertFalse(state.isImported)
        XCTAssertNil(state.importedURL)
        XCTAssertEqual(state.errorMessage, ReaderFileImportPresentation.missingResult(for: source))
    }

    func testProviderFailureRetainsTheExistingRecoveryMessage() async {
        for error in [ReaderFileAccessError.downloadInProgress, .notAvailableOffline] {
            var state = BookDownloadImportState()
            let result = await ReaderFileImportOperation.perform(.success(source)) { _ in throw error }
            XCTAssertFalse(state.receive(result))
            XCTAssertEqual(state.errorMessage, "Couldn't import 日本語.epub. \(error.userFacingMessage)")
        }
    }

    func testSelectedPackageErrorsUseTheSharedPresentation() async {
        let errors: [ReaderPackageEntrySourceError] = [
            .invalidSubpath, .ambiguousEntry, .entryNotFound, .unsupportedSource,
        ]
        for error in errors {
            var state = BookDownloadImportState()
            let result = await ReaderFileImportOperation.perform(.success(source)) { _ in throw error }
            XCTAssertFalse(state.receive(result))
            XCTAssertEqual(state.errorMessage, ReaderFileImportPresentation.failure(error, importing: source))
            XCTAssertFalse(state.isImported)
        }
    }

    func testCancellationErrorsNeverBecomeSuccessOrAlerts() async {
        let errors: [Error] = [CancellationError(), CocoaError(.userCancelled), URLError(.cancelled),
                               ReaderPackageEntrySourceError.cancelled]
        for error in errors {
            var state = BookDownloadImportState()
            let result = await ReaderFileImportOperation.perform(.success(source)) { _ in throw error }
            XCTAssertFalse(state.receive(result))
            XCTAssertFalse(state.isImported)
            XCTAssertNil(state.errorMessage)
        }
    }

    func testPreCancelledImportNeverInvokesTheImporter() async {
        let source = self.source
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ReaderFileImportOperation.perform(.success(source)) { _ in
                XCTFail("Cancelled importer was entered")
                return source
            }
        }
        var state = BookDownloadImportState()
        let result = await task.value
        XCTAssertFalse(state.receive(result))
        XCTAssertNil(state.errorMessage)
    }

    func testCancellationAfterCommitKeepsTheFileWithoutPublishingSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("committed.epub")
        let bytes = Data("committed-fixture".utf8)
        let source = self.source
        let task = Task { @MainActor in
            await ReaderFileImportOperation.perform(.success(source)) { _ in
                try bytes.write(to: output, options: .atomic)
                withUnsafeCurrentTask { $0?.cancel() }
                return output
            }
        }
        var state = BookDownloadImportState()
        let result = await task.value
        XCTAssertFalse(state.receive(result))
        XCTAssertFalse(state.isImported)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testCancelledFailureDoesNotPublishAnObsoleteError() async {
        let source = self.source
        let task = Task { @MainActor in
            await ReaderFileImportOperation.perform(.success(source)) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.notConnectedToInternet)
            }
        }
        var state = BookDownloadImportState()
        let result = await task.value
        XCTAssertFalse(state.receive(result))
        XCTAssertNil(state.errorMessage)
    }

    func testOwnedImportSelectsOnlyAfterSuccessAndKeepsAlreadyDownloadedValue() async throws {
        for alreadyDownloaded in [false, true] {
            let owner = BookDownloadOperation()
            var state = BookDownloadImportState()
            var selected: [Bool] = []
            let task = try XCTUnwrap(owner.start(operation: {
                let result = await ReaderFileImportOperation.perform(.success(self.source)) { _ in self.destination }
                return (result, alreadyDownloaded)
            }, publish: { result in
                if state.receive(result.0) { selected.append(result.1) }
            }))
            await task.value
            XCTAssertEqual(selected, [alreadyDownloaded])
            XCTAssertTrue(state.isImported)
        }
    }

    func testOwnedNilImportCannotInvokeTheSelectionCallback() async throws {
        let owner = BookDownloadOperation()
        var state = BookDownloadImportState()
        var selected = 0
        let task = try XCTUnwrap(owner.start(operation: {
            await ReaderFileImportOperation.perform(.success(self.source)) { _ in nil }
        }, publish: { result in
            if state.receive(result) { selected += 1 }
        }))
        await task.value
        XCTAssertEqual(selected, 0)
        XCTAssertFalse(state.isImported)
        XCTAssertNotNil(state.errorMessage)
    }

    func testReboundRowKeepsItsImportWhenOlderSuccessOrErrorReturns() async throws {
        let oldURL = URL(string: "reader-file://local/old/book.epub")!
        let newURL = URL(string: "reader-file://local/current/book.epub")!
        let firstIdentity = BookDownloadImportIdentity(
            remoteURL: URL(string: "https://example.com/old.epub")!,
            localDestination: source,
            name: "Old"
        )
        let nextIdentity = BookDownloadImportIdentity(
            remoteURL: URL(string: "https://example.com/current.epub")!,
            localDestination: URL(fileURLWithPath: "/synthetic/current.epub"),
            name: "Current"
        )
        let outcomes: [Result<URL?, Error>] = [
            .success(oldURL), .failure(URLError(.notConnectedToInternet)),
        ]
        for outcome in outcomes {
            let owner = BookDownloadOperation()
            let importer = SuspendedImport()
            var state = BookDownloadImportState()
            var selected: [String] = []
            XCTAssertTrue(state.bind(to: firstIdentity))
            let old = try XCTUnwrap(owner.start(operation: {
                await ReaderFileImportOperation.perform(.success(self.source)) { _ in
                    try await importer.run()
                }
            }, publish: { result in
                if state.receive(result) { selected.append("old") }
            }))
            let entered = await XCTWaiter.fulfillment(of: [importer.started], timeout: 3)
            guard entered == .completed else {
                XCTFail("Old import did not enter")
                owner.cancel()
                importer.finish(outcome)
                await old.value
                return
            }

            // These are the row's real bind/cancel operations. The suspended
            // importer deliberately ignores cancellation and settles afterwards.
            XCTAssertTrue(state.bind(to: nextIdentity))
            owner.cancel()
            guard let current = owner.start(operation: {
                await ReaderFileImportOperation.perform(.success(nextIdentity.localDestination)) { _ in newURL }
            }, publish: { result in
                if state.receive(result) { selected.append("current") }
            }) else {
                XCTFail("Rebound row must admit its current import")
                importer.finish(outcome)
                await old.value
                return
            }
            await current.value
            importer.finish(outcome)
            await old.value

            XCTAssertEqual(state.identity, nextIdentity)
            XCTAssertEqual(state.importedURL, newURL)
            XCTAssertNil(state.errorMessage)
            XCTAssertEqual(selected, ["current"])
        }
    }
}
