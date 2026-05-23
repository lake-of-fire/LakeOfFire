import Foundation
import LakeOfFireCore
import RealmSwift

public enum DefaultRealmConfiguration {
    public static let schemaVersion: UInt64 = 62
    
    public static var configuration: Realm.Configuration {
        var config = Realm.Configuration.defaultConfiguration
        config.schemaVersion = schemaVersion
        config.migrationBlock = migrationBlock
        // Crashy? https://github.com/realm/realm-core/issues/6378
//        config.shouldCompactOnLaunch = { totalBytes, usedBytes in
//            // totalBytes refers to the size of the file on disk in bytes (data + free space)
//            // usedBytes refers to the number of bytes used by data in the file
//
//            // Compact if the file is over size and less than some % 'used'
//            let targetBytes = 40 * 1024 * 1024
//            return (totalBytes > targetBytes) && (Double(usedBytes) / Double(totalBytes)) < 0.8
//        }
        config.objectTypes = [
            FeedCategory.self,
            Feed.self,
            FeedEntry.self,
            LibraryConfiguration.self,
            UserScript.self,
            UserScriptAllowedDomain.self,
            MediaStatus.self,
            MediaTranscript.self,
        ]
        return config
    }

    public static func migrationBlock(migration: Migration, oldSchemaVersion: UInt64) {
        if oldSchemaVersion < schemaVersion {
            if oldSchemaVersion < 32 {
                migration.deleteData(forType: FeedEntry.className())
            }
            if oldSchemaVersion < 52 {
                migration.enumerateObjects(ofType: FeedEntry.className()) { oldObject, newObject in
                    guard let newObject else { return }
                    if let oldList = oldObject?["voiceAudioURLs"] as? List<URL>, let first = oldList.first {
                        newObject["voiceAudioURL"] = first
                    }
                }
            }
            if oldSchemaVersion < 53 {
                migration.enumerateObjects(ofType: FeedEntry.className()) { _, newObject in
                    guard let newObject else { return }
                    if newObject["audioSubtitlesURL"] != nil, newObject["audioSubtitlesRoleRawValue"] == nil {
                        newObject["audioSubtitlesRoleRawValue"] = AudioSubtitlesRole.content.rawValue
                    }
                }
            }
            if oldSchemaVersion < 54 {
                migration.enumerateObjects(ofType: FeedEntry.className()) { oldObject, newObject in
                    guard let newObject,
                          let url = oldObject?["url"] as? URL,
                          let title = oldObject?["title"] as? String else {
                        return
                    }
                    guard url.isSnippetURL else {
                        newObject["isTitlePrefixOfContent"] = false
                        return
                    }
                    let html: String? = {
                        if let content = oldObject?["content"] as? Data {
                            let nsContent: NSData = content as NSData
                            if let data = try? nsContent.decompressed(using: .lzfse) as Data? {
                                return String(decoding: data, as: UTF8.self)
                            }
                        }
                        return nil
                    }()
                    newObject["isTitlePrefixOfContent"] = ReaderContentLoader.snippetTitleMatchesGeneratedPrefix(
                        title,
                        sourceHTML: html
                    )
                }
            }
            if oldSchemaVersion < 55 {
                migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
            }
            if oldSchemaVersion < 56 {
                migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
            }
            if oldSchemaVersion < 57 {
                migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
            }
            if oldSchemaVersion < 58 {
                migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
            }
            if oldSchemaVersion < 59 {
                migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
            }
            if oldSchemaVersion < 61 {
                migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
            }
            if oldSchemaVersion < 62 {
                migration.enumerateObjects(ofType: FeedEntry.className()) { _, _ in }
            }
        }
    }
}
