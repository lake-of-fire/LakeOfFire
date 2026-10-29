import Foundation

/// Shared presentation boundary for the actual Books and generic importers.
public enum ReaderFileImportPresentation {
    /// Interpret a single-selection picker result without taking over the
    /// manager's security scope, storage, or operation-identity lifecycle.
    /// Returns a message only for a genuine failure; success/cancellation are silent.
    @MainActor
    public static func handlePickerResult(
        _ result: Result<URL, Error>,
        importing: @MainActor (URL) async throws -> URL? = {
            try await ReaderFileManager.shared.importFile(fileURL: $0, fromDownloadURL: nil)
        }
    ) async -> String? {
        guard !Task.isCancelled else { return nil }
        switch result {
        case .success(let url):
            do {
                let importedURL = try await importing(url)
                try Task.checkCancellation()
                return importedURL == nil ? missingResult(for: url) : nil
            } catch {
                guard !Task.isCancelled else { return nil }
                return failure(error, importing: url)
            }
        case .failure(let error):
            return failure(error)
        }
    }

    public static func missingResult(for url: URL) -> String? {
        "Couldn't import \(url.lastPathComponent). Try selecting the file again."
    }

    public static func failure(_ error: Error, importing url: URL? = nil) -> String? {
        // Dismissing the picker or cancelling owned work is not an import failure.
        let nsError = error as NSError
        guard !(error is CancellationError),
              !(nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.userCancelled.rawValue),
              !(nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue)
        else { return nil }
        let detail = ReaderFileOperationMessageMapper.openMessage(for: error) ?? error.localizedDescription
        if let url {
            return "Couldn't import \(url.lastPathComponent). \(detail)"
        }
        return "Couldn't select the file. \(detail)"
    }
}
