import Foundation

/// Shared presentation boundary for Books and the generic importer.
/// Forward-ported from v3-hotfix, including typed resource-limit failures.
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

        let detail: String
        if let packageError = error as? ReaderPackageEntrySourceError {
            switch packageError {
            case .entryCountExceeded, .entrySizeExceeded, .aggregateSizeExceeded,
                 .actualEntrySizeExceeded, .entryPathSizeExceeded, .aggregatePathSizeExceeded:
                detail = "This EPUB exceeds the supported package limits. Try a smaller edition or remove oversized resources."
            case .packageCorrupt, .ambiguousEntry, .invalidSubpath:
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
