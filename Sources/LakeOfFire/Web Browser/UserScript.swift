import Foundation
import WebKit
import RealmSwift
import BigSyncKit
import SwiftUIWebView

public class UserScriptAllowedDomain: Object, UnownedSyncableObject, ObjectKeyIdentifiable, Codable {
    public var needsSyncToServer: Bool {
        return false
    }

    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var domain = ""
    
    @Persisted public var modifiedAt: Date
    @Persisted public var isDeleted = false
}

public class UserScript: Object, UnownedSyncableObject, ObjectKeyIdentifiable, Codable {
    public var needsSyncToServer: Bool {
        return false
    }

    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var title = ""
    @Persisted public var script = ""
    @Persisted public var allowedDomains = RealmSwift.List<UserScriptAllowedDomain>()
    
    @Persisted public var injectAtStart = true
    @Persisted public var mainFrameOnly = true
    @Persisted public var sandboxed = false
    
    @Persisted public var previewURL: URL?
    
    @Persisted public var isArchived = false
    
    @Persisted public var opmlOwnerName: String? = nil
    @Persisted public var opmlURL: URL? = nil
    
    @Persisted public var modifiedAt: Date
    
    @Persisted public var isDeleted = false
    
    public var webViewUserScript: WebViewUserScript {
        return WebViewUserScript(source: script, injectionTime: injectAtStart ? .atDocumentStart : .atDocumentEnd, forMainFrameOnly: mainFrameOnly, in: WKContentWorld.world(name: id.uuidString), allowedDomains: Set(allowedDomains.where({ $0.isDeleted == false }).map({ $0.domain })))
    }
    
    
    public var isUserEditable: Bool {
        return opmlURL == nil
    }
}
