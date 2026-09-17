import Foundation
import LakeOfFireContent

struct BookDownloadImportAttemptOutcome {
    let importedURL: URL?
    let shouldMarkDownloaded: Bool
    let shouldContinueSelection: Bool
    let userFacingMessage: String?
}

/// Production decision boundary for converting downloaded bytes into a Reader
/// library item. The lower tier intentionally preserves legacy behavior.
enum BookDownloadImportAttempt {
    @MainActor
    static func perform(
        importing sourceURL: URL,
        operation: () async throws -> URL?
    ) async -> BookDownloadImportAttemptOutcome {
        let importedURL = try? await operation()
        return BookDownloadImportAttemptOutcome(
            importedURL: importedURL,
            shouldMarkDownloaded: true,
            shouldContinueSelection: true,
            userFacingMessage: nil
        )
    }
}
