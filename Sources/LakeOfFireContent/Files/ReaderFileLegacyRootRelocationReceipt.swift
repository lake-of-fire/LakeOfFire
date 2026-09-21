import Foundation
import RealmSwift

/// Device-local recovery state for moving an old root-level download into the
/// directory selected by the current file processor.
///
/// The destination is indexed before this receipt is committed.  The source is
/// then soft-deleted in the same transaction as the receipt, allowing a later
/// launch to retry only the final physical source removal without guessing.
@objc(ReaderFileLegacyRootRelocationReceipt)
public final class ReaderFileLegacyRootRelocationReceipt: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) public var receiptIdentifier = ""
    @Persisted(indexed: true) public var storageScopeIdentifier = ""
    @Persisted public var sourceRelativePath = ""
    @Persisted public var sourceReaderBackingURLString = ""
    @Persisted(indexed: true) public var sourceContentFilePrimaryKey = ""
    @Persisted public var sourceContentFileCreatedAt = Date.distantPast
    @Persisted public var sourceModifiedAt: Date?
    @Persisted public var sourceFileSize: Int64 = -1
    @Persisted public var targetReaderURLString = ""
    @Persisted(indexed: true) public var targetContentFilePrimaryKey = ""
    @Persisted public var targetContentFileCreatedAt = Date.distantPast
    @Persisted public var targetModifiedAt: Date?
    @Persisted public var targetFileSize: Int64 = -1
    @Persisted public var createdAt = Date.distantPast

    public static func makeReceiptIdentifier(
        storageScopeIdentifier: String,
        sourceRelativePath: String,
        sourceContentFilePrimaryKey: String
    ) -> String {
        [storageScopeIdentifier, sourceRelativePath, sourceContentFilePrimaryKey]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }
}
