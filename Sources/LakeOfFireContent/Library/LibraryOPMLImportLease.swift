import Foundation
import RealmSwift

public final class LibraryOPMLImportLease: Object {
    public static let singletonID = "LibraryOPMLImportLease.v1"

    @Persisted(primaryKey: true) public var id = singletonID
    @Persisted public var generation: Int64 = 0
    @Persisted public var ownerID = ""
    @Persisted public var acquiredAt = Date.distantPast
}
