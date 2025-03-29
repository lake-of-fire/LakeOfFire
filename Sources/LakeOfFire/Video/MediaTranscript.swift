import Foundation
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
import SwiftUtilities

public class MediaTranscript: Object, UnownedSyncableObject, ChangeMetadataRecordable {
    @Persisted(primaryKey: true) public var compoundKey = ""
    @Persisted public var mediaStatusID: String?
    
    @Persisted public var languageCode: String
    @Persisted public var content: Data?

    @Persisted public var syncableRevisionCount = 0
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    public var needsSyncToAppServer: Bool {
        return false
    }
    
    public static func makeCompoundKey(mediaStatus: MediaStatus, languageCode: String) -> String? {
        return mediaStatus.compoundKey + "-" + languageCode
    }
    
    func updateCompoundKey() {
//        guard let key = Self.makeCompoundKey(mediaStatus: mediaStatus, languageCode: languageCode) else {
//            print("Failed to update key for MediaTranscript")
//            return
//        }
//        compoundKey = key
    }
    
//    @RealmBackgroundActor
//    static func getOrCreate(mediaStatus: MediaStatus) async throws -> MediaTranscript {
//        let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: RealmBackgroundActor.shared)
//        
//        if let mediaTranscript = realm.object(ofType: MediaTranscript.self, forPrimaryKey: MediaTranscript.makeCompoundKey(mediaStatus: mediaStatus, languageCode: <#T##String#>)) {
//            if mediaStatus.isDeleted {
//                try await realm.asyncWrite {
//                    mediaStatus.isDeleted = false
//                }
//            }
//            return videoStatus
//        }
//        
//        let videoStatus = MediaTranscript()
//        videoStatus.url = url
//        videoStatus.updateCompoundKey()
//        try await realm.asyncWrite {
//            realm.add(videoStatus, update: .modified)
//        }
//        return videoStatus
//    }
//    
//    static func contentToHTML(legacyHTMLContent: String? = nil, content: Data?) -> String? {
//        if let legacyHtml = legacyHTMLContent {
//            return legacyHtml
//        }
//        guard let content = content else { return nil }
//        let nsContent: NSData = content as NSData
//        guard let data = try? nsContent.decompressed(using: .lzfse) as Data? else {
//            return nil
//        }
//        return String(decoding: data, as: UTF8.self)
//    }
}
