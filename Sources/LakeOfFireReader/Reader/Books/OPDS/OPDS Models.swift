import Foundation
import RealmSwift
import RealmSwiftGaps
import BigSyncKit

public class OPDSCatalog: Object, UnownedSyncableObject, ObjectKeyIdentifiable, ChangeMetadataRecordable {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var title: String = ""
    @Persisted public var url: String = ""

    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt: Date
    @Persisted public var isDeleted = false

    public override init() {
        super.init()
    }

    public var needsSyncToAppServer: Bool {
        return false
    }

    @discardableResult
    public static func add(
        title: String,
        url: String,
        to realm: Realm,
        at timestamp: Date = Date()
    ) -> OPDSCatalog {
        let catalog = OPDSCatalog()
        catalog.title = title
        catalog.url = url
        realm.add(catalog, update: .modified)
        catalog.refreshChangeMetadata(
            explicitlyModified: true,
            at: timestamp
        )
        return catalog
    }

    @discardableResult
    public func softDelete(at timestamp: Date = Date()) -> Bool {
        guard !isDeleted else { return false }
        isDeleted = true
        refreshChangeMetadata(
            explicitlyModified: true,
            at: timestamp
        )
        return true
    }
}
