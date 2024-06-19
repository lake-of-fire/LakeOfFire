import Foundation
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
import SwiftUtilities

public class VideoStatus: Object, UnownedSyncableObject {
    @Persisted(primaryKey: true) public var compoundKey = ""
    @Persisted public var url = URL(string: "about:blank")!
    @Persisted public var providerVideoID: String?

    @Persisted public var modifiedAt: Date
    @Persisted public var isDeleted = false
    
    public var needsSyncToServer: Bool {
        return false
    }
    
    public static func makeCompoundKey(url: URL) -> String {
        return String(format: "%02X", stableHash(url.absoluteString))
    }
    
    func updateCompoundKey() {
        compoundKey = Self.makeCompoundKey(url: url)
    }
    
    @RealmBackgroundActor
    static func getOrCreate(url: URL) async throws -> VideoStatus {
        let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: RealmBackgroundActor.shared)
        
        if let videoStatus = realm.object(ofType: VideoStatus.self, forPrimaryKey: VideoStatus.makeCompoundKey(url: url)) {
            if videoStatus.isDeleted {
                try await realm.asyncWrite {
                    videoStatus.isDeleted = false
                }
            }
            return videoStatus
        }
        
        let videoStatus = VideoStatus()
        videoStatus.url = url
        videoStatus.updateCompoundKey()
        try await realm.asyncWrite {
            realm.add(videoStatus, update: .modified)
        }
        return videoStatus
    }
}
