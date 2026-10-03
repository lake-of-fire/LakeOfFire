import Foundation
import RealmSwift

/// Device-local completion work for an already installed local-drive import.
/// Not synced or restored to another installation; the owning Realm and drive
/// are encoded in storageScopeIdentifier. Presence means metadata/provenance
/// completion may be retried after validating the installed content identity.
@objc(ReaderPendingFileImport)
public final class ReaderPendingFileImport: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) public var importIdentifier = ""
    @Persisted(indexed: true) public var storageScopeIdentifier = ""
    @Persisted public var relativePath = ""
    @Persisted public var requiresManifest = false
    @Persisted public var identityVersion = 1
    @Persisted public var identityDigest = Data()
    @Persisted public var collisionHashString = ""
    @Persisted public var downloadURLString: String?
    @Persisted public var enqueuedAt = Date.distantPast
}
