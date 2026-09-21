import Foundation
import RealmSwift

/// Device-local retry work for one file processor and one indexed file.
///
/// The row lives in the reader Realm so indexing metadata and retry admission can
/// commit atomically. Manabi's canonical configuration excludes it from BigSync:
/// drive roots and processor implementations are local to one installation.
@objc(ReaderFilePostprocessorDebt)
public final class ReaderFilePostprocessorDebt: Object, @unchecked Sendable {
    public static let portableStorageScopeIdentifier = ""

    @Persisted(primaryKey: true) public var debtIdentifier = ""
    @Persisted(indexed: true) public var storageScopeIdentifier = ""
    @Persisted(indexed: true) public var processorIdentifier = ""
    @Persisted public var processorVersion: Int64 = 0
    @Persisted(indexed: true) public var contentFilePrimaryKey = ""
    @Persisted public var contentFileCreatedAt = Date.distantPast
    @Persisted public var readerFileURLString = ""
    @Persisted public var sourceModifiedAt: Date?
    @Persisted public var sourceFileSize: Int64 = -1
    @Persisted public var attemptIdentifier = ""
    @Persisted public var enqueuedAt = Date.distantPast

    public static func makeDebtIdentifier(
        storageScopeIdentifier: String,
        processorIdentifier: String,
        contentFilePrimaryKey: String
    ) -> String {
        [storageScopeIdentifier, processorIdentifier, contentFilePrimaryKey]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    public static func makePortableDebtIdentifier(
        processorIdentifier: String,
        contentFilePrimaryKey: String
    ) -> String {
        makeDebtIdentifier(
            storageScopeIdentifier: portableStorageScopeIdentifier,
            processorIdentifier: processorIdentifier,
            contentFilePrimaryKey: contentFilePrimaryKey
        )
    }
}
