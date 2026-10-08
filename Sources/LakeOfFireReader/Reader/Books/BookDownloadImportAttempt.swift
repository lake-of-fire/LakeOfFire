import Foundation
import LakeOfFireContent

struct BookDownloadImportAttemptOutcome {
    let importedURL: URL?
    let shouldMarkDownloaded: Bool
    let shouldContinueSelection: Bool
    let userFacingMessage: String?
}

/// Production decision boundary for converting downloaded bytes into a Reader
/// library item.
enum BookDownloadImportAttempt {
    @MainActor
    static func perform(
        importing sourceURL: URL,
        operation: () async throws -> URL?
    ) async -> BookDownloadImportAttemptOutcome {
        do {
            guard let importedURL = try await operation() else {
                return BookDownloadImportAttemptOutcome(
                    importedURL: nil,
                    shouldMarkDownloaded: false,
                    shouldContinueSelection: false,
                    userFacingMessage:
                        ReaderFileImportPresentation.missingResult(
                            for: sourceURL
                        )
                )
            }
            return BookDownloadImportAttemptOutcome(
                importedURL: importedURL,
                shouldMarkDownloaded: true,
                shouldContinueSelection: true,
                userFacingMessage: nil
            )
        } catch {
            return BookDownloadImportAttemptOutcome(
                importedURL: nil,
                shouldMarkDownloaded: false,
                shouldContinueSelection: false,
                userFacingMessage:
                    ReaderFileImportPresentation.failure(
                        error,
                        importing: sourceURL
                    )
            )
        }
    }
}

enum BookDownloadOpenFailurePresentation {
    static func message(
        for error: Error,
        title: String
    ) -> String? {
        let nsError = error as NSError
        guard !(error is CancellationError),
              !(nsError.domain == NSCocoaErrorDomain
                && nsError.code == CocoaError.userCancelled.rawValue),
              !(nsError.domain == NSURLErrorDomain
                && nsError.code == URLError.cancelled.rawValue)
        else {
            return nil
        }

        let detail =
            ReaderFileOperationMessageMapper.openMessage(for: error)
            ?? error.localizedDescription
        return "Couldn't open \(title). \(detail)"
    }
}
