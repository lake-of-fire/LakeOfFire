import Foundation

/// The outcome of importing an ordered selection of local OPML files.
/// Failures and cancellation can occur after some changes have been committed.
public struct OPMLImportResult: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let fileURL: URL
        public let message: String

        public init(fileURL: URL, message: String) {
            self.fileURL = fileURL
            self.message = message
        }
    }

    /// Includes files left unattempted when the batch is cancelled.
    public let totalFileCount: Int
    /// Files whose importer returned normally, in selection order. A failed or
    /// cancelled file may still have committed changes; this is not a rollback receipt.
    public let completedFileURLs: [URL]
    public let failures: [Failure]
    public let wasCancelled: Bool

    public init(totalFileCount: Int, completedFileURLs: [URL], failures: [Failure], wasCancelled: Bool) {
        self.totalFileCount = totalFileCount
        self.completedFileURLs = completedFileURLs
        self.failures = failures
        self.wasCancelled = wasCancelled
    }
}
