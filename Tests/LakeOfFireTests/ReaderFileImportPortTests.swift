import Foundation
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderFileImportPortTests: XCTestCase {
    private let selectedURL = URL(fileURLWithPath: "/synthetic/日本語.epub")

    func testSuccessfulImportReturnsActualDestination() async {
        let destination = URL(string: "reader-file://local/owned/book.epub")!
        var calls = 0
        let result = await ReaderFileImportOperation.perform(.success(selectedURL)) { url in
            calls += 1
            XCTAssertEqual(url, self.selectedURL)
            return destination
        }
        XCTAssertEqual(result, .imported(destination))
        XCTAssertEqual(calls, 1)
    }

    func testMissingImportedURLIsAnActionableFailure() async {
        let result = await ReaderFileImportOperation.perform(.success(selectedURL)) { _ in nil }
        XCTAssertEqual(result, .failed(message: "Couldn't import 日本語.epub. Try selecting the file again."))
    }

    func testPickerCancellationNeverCallsImporter() async {
        for error in cancellationErrors {
            let result = await ReaderFileImportOperation.perform(.failure(error)) { _ in
                XCTFail("Cancelled picker must not import")
                return self.selectedURL
            }
            XCTAssertEqual(result, .cancelled)
        }
    }

    func testOperationCancellationDoesNotBecomeAnErrorMessage() async {
        for error in cancellationErrors {
            let result = await ReaderFileImportOperation.perform(.success(selectedURL)) { _ in throw error }
            XCTAssertEqual(result, .cancelled)
        }
    }

    func testPreCancelledWorkDoesNotInvokeImporter() async {
        let selectedURL = self.selectedURL
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ReaderFileImportOperation.perform(.success(selectedURL)) { _ in
                XCTFail("Pre-cancelled work must not import")
                return selectedURL
            }
        }
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }

    func testCancellationAfterCommitDoesNotPublishSuccessOrDeleteTheResult() async {
        let selectedURL = self.selectedURL
        var committed = false
        let task = Task { @MainActor in
            await ReaderFileImportOperation.perform(.success(selectedURL)) { url in
                committed = true
                withUnsafeCurrentTask { $0?.cancel() }
                return url
            }
        }
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(committed)
    }

    func testCancellationAfterFailureDoesNotPublishObsoleteError() async {
        let selectedURL = self.selectedURL
        let task = Task { @MainActor in
            await ReaderFileImportOperation.perform(.success(selectedURL)) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.notConnectedToInternet)
            }
        }
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }

    func testCloudAvailabilityMessageIsPreserved() async {
        for error in [ReaderFileAccessError.downloadInProgress, .notAvailableOffline] {
            let result = await ReaderFileImportOperation.perform(.success(selectedURL)) { _ in throw error }
            XCTAssertEqual(result, .failed(message: "Couldn't import 日本語.epub. \(error.userFacingMessage)"))
        }
    }

    func testPickerErrorIsNotMisreportedAsAnImportFailure() async {
        let error = NSError(domain: "SyntheticPicker", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Permission was denied."])
        let result = await ReaderFileImportOperation.perform(.failure(error)) { _ in
            XCTFail("A failed selection has no URL to import")
            return self.selectedURL
        }
        XCTAssertEqual(result, .failed(message: "Couldn't select the file. Permission was denied."))
    }

    func testResourceLimitsAreNotReportedAsCorruption() {
        let limits: [ReaderPackageEntrySourceError] = [
            .entryCountExceeded(limit: 1), .entrySizeExceeded(path: "a", size: 2, limit: 1),
            .aggregateSizeExceeded(limit: 1), .actualEntrySizeExceeded(path: "a", limit: 1),
            .entryPathSizeExceeded(limit: 1), .aggregatePathSizeExceeded(limit: 1)
        ]
        for error in limits {
            XCTAssertEqual(ReaderFileImportPresentation.failure(error, importing: selectedURL),
                "Couldn't import 日本語.epub. This EPUB exceeds the supported package limits. Try a smaller edition or remove oversized resources.")
        }
    }

    func testInvalidPackagesHaveARepairableMessage() {
        for error in [ReaderPackageEntrySourceError.packageCorrupt, .ambiguousEntry, .invalidSubpath] {
            XCTAssertEqual(ReaderFileImportPresentation.failure(error, importing: selectedURL),
                "Couldn't import 日本語.epub. This EPUB contains damaged or invalid package data. Try downloading or exporting it again.")
        }
    }

    func testMissingPackageResourceDoesNotSuggestDeletion() {
        XCTAssertEqual(ReaderFileImportPresentation.failure(ReaderPackageEntrySourceError.entryNotFound,
                                                           importing: selectedURL),
            "Couldn't import 日本語.epub. A required EPUB resource is missing. Make sure the complete book is available and try again.")
    }

    func testCancellationCodeInAnotherDomainRemainsARealFailure() {
        let error = NSError(domain: "SyntheticProvider", code: URLError.cancelled.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "Provider failed."])
        XCTAssertEqual(ReaderFileImportPresentation.failure(error, importing: selectedURL),
                       "Couldn't import 日本語.epub. Provider failed.")
    }

    private var cancellationErrors: [Error] {
        [CancellationError(), CocoaError(.userCancelled), URLError(.cancelled), ReaderPackageEntrySourceError.cancelled]
    }
}
