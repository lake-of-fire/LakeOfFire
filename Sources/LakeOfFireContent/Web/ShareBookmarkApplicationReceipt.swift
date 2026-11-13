import Foundation
import RealmSwift

/// Local application history for durable share-inbox requests. Keep this row
/// independently of the bookmark so a retry cannot undo later edits or deletion.
/// This model must remain excluded from BigSync in the owning configuration.
public final class ShareBookmarkApplicationReceipt: Object {
    @Persisted(primaryKey: true) public var payloadDigest = ""
    @Persisted public var canonicalPayload = Data()
    @Persisted public var bookmarkID = ""
    @Persisted public var appliedAt = Date()
}
