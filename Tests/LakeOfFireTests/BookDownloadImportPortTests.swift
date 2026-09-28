import Foundation
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
final class BookDownloadImportPortTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/synthetic/日本語.epub")
    private let destination = URL(string: "reader-file://local/owned/book.epub")!

    func testInitialStateDoesNotClaimALibraryImport() async {
        let state = BookDownloadImportState()
        XCTAssertFalse(state.isImported)
        XCTAssertNil(state.importedURL)
        XCTAssertNil(state.errorMessage)
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

    func testProviderFailureRetainsTheExistingRecoveryMessage() async {
        for error in [ReaderFileAccessError.downloadInProgress, .notAvailableOffline] {
            var state = BookDownloadImportState()
            let result = await ReaderFileImportOperation.perform(.success(source)) { _ in throw error }
            XCTAssertFalse(state.receive(result))
            XCTAssertEqual(state.errorMessage, "Couldn't import 日本語.epub. \(error.userFacingMessage)")
        }
    }

    func testPackageLimitFailureUsesTheSharedPresentation() async {
        let errors: [ReaderPackageEntrySourceError] = [
            .entryCountExceeded(limit: 1), .entrySizeExceeded(path: "x", size: 2, limit: 1),
            .aggregateSizeExceeded(limit: 1), .actualEntrySizeExceeded(path: "x", limit: 1),
            .entryPathSizeExceeded(limit: 1), .aggregatePathSizeExceeded(limit: 1),
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
}
