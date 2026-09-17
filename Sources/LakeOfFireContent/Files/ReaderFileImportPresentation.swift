import Foundation

/// Shared presentation boundary for the actual Books and generic importers.
public enum ReaderFileImportPresentation {
    public static func missingResult(for url: URL) -> String? {
        nil
    }

    public static func failure(_ error: Error, importing url: URL? = nil) -> String? {
        nil
    }
}
