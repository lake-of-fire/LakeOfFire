//import Foundation
//import RealmSwift
//import RealmSwiftGaps
//import BigSyncKit
//import SwiftUtilities
//
//public class VideoTranscript: Object, UnownedSyncableObject {
//    @Persisted(primaryKey: true) public var compoundKey = ""
//    @Persisted public var videoStatus: VideoStatus
//    
//    @Persisted public var languageCode: String
//    @Persisted public var content: Data?
//
//    @Persisted public var modifiedAt: Date
//    @Persisted public var isDeleted = false
//    
//    public var needsSyncToServer: Bool {
//        return false
//    }
//    
//    public static func makeCompoundKey(videoStatus: VideoStatus, language: String) -> String {
//        var key = String(format: "%02X", stableHash(url.absoluteString))
//        key.append()
//        return key
//    }
//    
//    func updateCompoundKey() {
//        compoundKey = Self.makeCompoundKey(url: url)
//    }
//    
//    @RealmBackgroundActor
//    static func getOrCreate(url: URL) async throws -> VideoStatus {
//        let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: RealmBackgroundActor.shared)
//        
//        if let videoStatus = realm.object(ofType: VideoStatus.self, forPrimaryKey: VideoStatus.makeCompoundKey(url: url)) {
//            if videoStatus.isDeleted {
//                try await realm.asyncWrite {
//                    videoStatus.isDeleted = false
//                }
//            }
//            return videoStatus
//        }
//        
//        let videoStatus = VideoStatus()
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
//}
