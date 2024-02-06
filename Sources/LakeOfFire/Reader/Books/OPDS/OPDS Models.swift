import Foundation
import RealmSwift
import RealmSwiftGaps
import BigSyncKit

public class OPDSCatalog: Object, UnownedSyncableObject, ObjectKeyIdentifiable {
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var title: String = ""
    @Persisted public var url: String = ""
    
    @Persisted public var modifiedAt: Date
    @Persisted public var isDeleted = false
    
    public override init() {
        super.init()
    }
    
    public var needsSyncToServer: Bool {
        return false
    }
}
