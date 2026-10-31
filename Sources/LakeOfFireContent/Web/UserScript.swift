import Foundation
import LakeOfFireCore
import WebKit
import RealmSwift
import BigSyncKit
import SwiftUIWebView

/// Plain projection of a managed script. Resolve it on the Realm's owning actor;
/// create WebKit namespaces only when installing the value on MainActor.
public struct UserScriptSnapshot: Sendable {
    public let source: String
    public let injectionTime: WKUserScriptInjectionTime
    public let isForMainFrameOnly: Bool
    public let worldName: String
    public let allowedDomains: Set<String>

    @MainActor
    public func makeWebViewUserScript() -> WebViewUserScript {
        WebViewUserScript(
            source: source, injectionTime: injectionTime,
            forMainFrameOnly: isForMainFrameOnly,
            in: WKContentWorld.world(name: worldName), allowedDomains: allowedDomains
        )
    }
}

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
    
    @MainActor
    public func getWebViewUserScript() -> WebViewUserScript? {
        getWebViewUserScriptSnapshot()?.makeWebViewUserScript()
    }

    public func getWebViewUserScriptSnapshot() -> UserScriptSnapshot? {
        // OPML is content configuration, never a source of executable code.
        // This also blocks previously imported and subsequently synced records.
        guard opmlURL == nil, let allowedDomains = getAllowedDomains() else { return nil }
        // An intentionally empty list means every site. Missing or tombstoned
        // UUID references must never silently broaden a restricted script.
        guard allowedDomainIDs.isEmpty || !allowedDomains.isEmpty else { return nil }
        return UserScriptSnapshot(
            source: script,
            injectionTime: injectAtStart ? .atDocumentStart : .atDocumentEnd,
            isForMainFrameOnly: mainFrameOnly,
            worldName: id.uuidString,
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
