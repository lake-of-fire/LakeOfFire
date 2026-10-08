import Foundation

/// Shared presentation boundary for the actual Books and generic importers.
public enum ReaderFileImportPresentation {
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
