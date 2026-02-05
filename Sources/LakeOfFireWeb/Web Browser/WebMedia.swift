//import Foundation
//import RealmSwift
//import BigSyncKit
//
//public class WebMedia: Object, UnownedSyncableObject, ObjectKeyIdentifiable, Codable {
//    public var needsSyncToAppServer: Bool {
//        return false
//    }
//
//    @Persisted(primaryKey: true) public var id = UUID()
//    @Persisted public var title = ""
//    @Persisted public var domainURL: URL?
//    
//    @Persisted public var opmlOwnerName: String? = nil
//    @Persisted public var opmlURL: URL? = nil
//
//    @Persisted public var createdAt = Date()
//    @Persisted public var modifiedAt: Date
//    
//    @Persisted public var isDeleted = false
//}
import LakeOfFireCore
import LakeOfFireAdblock
