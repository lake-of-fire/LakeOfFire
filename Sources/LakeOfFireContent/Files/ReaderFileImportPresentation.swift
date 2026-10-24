import Foundation

/// Shared presentation boundary for Books and the generic importer.
/// Preserves the selected package errors and cloud-availability messages.
public enum ReaderFileImportPresentation {
    public static func missingResult(for url: URL) -> String {
        "Couldn't import \(url.lastPathComponent). Try selecting the file again."
    }

    public static func failure(_ error: Error, importing url: URL? = nil) -> String? {
        let nsError = error as NSError
        guard !(error is CancellationError),
              !(nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.userCancelled.rawValue),
              !(nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue),
              (error as? ReaderPackageEntrySourceError) != .cancelled else { return nil }

        if let importError = error as? ReaderFileImportError {
            switch importError {
            case .missingResult(let sourceURL):
                return missingResult(for: sourceURL)
            }
        }

        let detail: String
        if let packageError = error as? ReaderPackageEntrySourceError {
            switch packageError {
            case .ambiguousEntry, .invalidSubpath:
                detail = "This EPUB contains damaged or invalid package data. Try downloading or exporting it again."
            case .entryNotFound:
                detail = "A required EPUB resource is missing. Make sure the complete book is available and try again."
            case .unsupportedSource:
                detail = "This package could not be read. Check that it is a supported, fully downloaded file."
            case .cancelled:
                return nil
            }
        } else {
            detail = ReaderFileOperationMessageMapper.openMessage(for: error) ?? error.localizedDescription
        }
        if let url { return "Couldn't import \(url.lastPathComponent). \(detail)" }
        return "Couldn't select the file. \(detail)"
    }
}
