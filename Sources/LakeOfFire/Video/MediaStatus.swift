import Foundation
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
import SwiftUtilities

public class MediaStatus: Object, UnownedSyncableObject {
    @Persisted(primaryKey: true) public var compoundKey = ""
    @Persisted public var url = URL(string: "about:blank")!
    @Persisted public var providerMediaID: String?

    @Persisted public var modifiedAt: Date
    @Persisted public var isDeleted = false
    
    @Persisted(originProperty: "mediaStatus") public var feeds: LinkingObjects<MediaTranscript>
    
    public var needsSyncToServer: Bool {
        return false
    }
   
    private enum CodingKeys: String, CodingKey {
        case compoundKey
        case url
        case providerMediaID
        case modifiedAt
        case isDeleted
    }
    
    public static func makeCompoundKey(url: URL) -> String {
        return String(format: "%02X", stableHash(url.absoluteString))
    }
    
    func updateCompoundKey() {
        compoundKey = Self.makeCompoundKey(url: url)
    }
    
    @RealmBackgroundActor
    static func getOrCreate(url: URL) async throws -> MediaStatus {
        guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { fatalError("Can't get Realm for MediaStatus") }

        if let mediaStatus = realm.object(ofType: MediaStatus.self, forPrimaryKey: MediaStatus.makeCompoundKey(url: url)) {
            if mediaStatus.isDeleted {
                try await realm.asyncWrite {
                    mediaStatus.isDeleted = false
                    mediaStatus.modifiedAt = Date()
                }
            }
            return mediaStatus
        }
        
        let mediaStatus = MediaStatus()
        mediaStatus.url = url
        mediaStatus.updateCompoundKey()
        try await realm.asyncWrite {
            realm.add(mediaStatus, update: .modified)
        }
        return mediaStatus
    }
}
