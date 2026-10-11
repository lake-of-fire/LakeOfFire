import Foundation

public enum ReaderFileImportResult: Sendable, Equatable {
    case imported(URL)
    case cancelled
    case failed(message: String)
}

/// One operation path for the actual Books and generic file pickers. This owns
/// presentation, not filesystem transactions: a late cancellation never deletes
/// a file that the importer may already have committed.
public enum ReaderFileImportOperation {
    @MainActor
    public static func perform(
        _ selection: Result<URL, Error>,
        importing: @MainActor (URL) async throws -> URL?
    ) async -> ReaderFileImportResult {
        guard !Task.isCancelled else { return .cancelled }
        switch selection {
        case .failure(let error):
            guard let message = ReaderFileImportPresentation.failure(error) else { return .cancelled }
            return .failed(message: message)
        case .success(let selectedURL):
            do {
                let importedURL = try await importing(selectedURL)
                guard !Task.isCancelled else { return .cancelled }
                guard let importedURL else {
                    return .failed(message: ReaderFileImportPresentation.missingResult(for: selectedURL))
                }
                return .imported(importedURL)
            } catch {
                guard !Task.isCancelled,
                      let message = ReaderFileImportPresentation.failure(error, importing: selectedURL)
                else { return .cancelled }
                return .failed(message: message)
            }
        }
    }
}
