import Foundation
import WebKit
import RealmSwift
import BigSyncKit
import SwiftUIWebView
import LakeOfFireCore
import LakeOfFireAdblock

public class UserScriptAllowedDomain: Object, UnownedSyncableObject, ObjectKeyIdentifiable, Codable {
    public var needsSyncToAppServer: Bool {
        return false
    }

    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var domain = ""
    
    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt: Date
    @Persisted public var isDeleted = false
}

public class UserScript: Object, UnownedSyncableObject, ObjectKeyIdentifiable, Codable {
    public var needsSyncToAppServer: Bool {
        return false
    }

    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var title = ""
    @Persisted public var script = ""
    @Persisted public var allowedDomainIDs = RealmSwift.List<UUID>()
    
    @Persisted public var injectAtStart = true
    @Persisted public var mainFrameOnly = true
    @Persisted public var sandboxed = false
    
    @Persisted public var previewURL: URL?
    
    @Persisted public var isArchived = false
    
    @Persisted public var opmlOwnerName: String? = nil
    @Persisted public var opmlURL: URL? = nil
    
    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt: Date
    
    @Persisted public var isDeleted = false
    
    public func getWebViewUserScript() -> WebViewUserScript? {
        guard let allowedDomains = getAllowedDomains() else { return nil }
        return WebViewUserScript(
            source: script,
            injectionTime: injectAtStart ? .atDocumentStart : .atDocumentEnd,
            forMainFrameOnly: mainFrameOnly,
            in: WKContentWorld.world(name: id.uuidString),
            allowedDomains: Set(allowedDomains.map({ $0.domain }))
        )
    }
    
    
    public var isUserEditable: Bool {
        return opmlURL == nil
    }
    
    public func getAllowedDomains() -> [UserScriptAllowedDomain]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        return allowedDomainIDs.compactMap { realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: $0) } .filter { !$0.isDeleted }
    }
}
