import Foundation
import RealmSwift

public enum DefaultRealmConfiguration {
    public static let schemaVersion: UInt64 = 74
    
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
            FeedDirectory.self,
            Feed.self,
            FeedEntryCollection.self,
            FeedEntry.self,
            LibraryConfiguration.self,
            UserScript.self,
            UserScriptAllowedDomain.self,
        ]
        return config
    }

    public static func migrationBlock(migration: Migration, oldSchemaVersion: UInt64) {
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
            migration.deleteData(forType: "MediaStatus")
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
        if oldSchemaVersion < 60 {
            migration.enumerateObjects(ofType: FeedEntry.className()) { _, _ in }
            migration.enumerateObjects(ofType: Bookmark.className()) { _, _ in }
            migration.enumerateObjects(ofType: HistoryRecord.className()) { _, _ in }
            migration.enumerateObjects(ofType: ContentFile.className()) { _, _ in }
            migration.enumerateObjects(ofType: ContentPackageFile.className()) { _, _ in }
        }
        if oldSchemaVersion < 61 {
            migration.enumerateObjects(ofType: FeedEntry.className()) { _, _ in }
            migration.enumerateObjects(ofType: Bookmark.className()) { _, _ in }
            migration.enumerateObjects(ofType: HistoryRecord.className()) { _, _ in }
            migration.enumerateObjects(ofType: ContentFile.className()) { _, _ in }
            migration.enumerateObjects(ofType: ContentPackageFile.className()) { _, _ in }
        }
        if oldSchemaVersion < 62 {
            migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
        }
        if oldSchemaVersion < 65 {
            migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
        }
        if oldSchemaVersion < 66 {
            migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
        }
        if oldSchemaVersion < 67 {
            migration.enumerateObjects(ofType: FeedEntry.className()) { _, _ in }
        }
        if oldSchemaVersion < 69 {
            migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
        }
        if oldSchemaVersion < 70 {
            migration.enumerateObjects(ofType: Feed.className()) { _, _ in }
            migration.enumerateObjects(ofType: FeedDirectory.className()) { _, _ in }
        }
        if oldSchemaVersion < 71 {
            migration.enumerateObjects(ofType: Feed.className()) { oldObject, newObject in
                guard oldSchemaVersion >= 70 else { return }
                newObject?["ordinal"] = oldObject?["opmlOrder"]
            }
            migration.enumerateObjects(ofType: FeedDirectory.className()) { oldObject, newObject in
                guard oldSchemaVersion >= 70 else { return }
                newObject?["ordinal"] = oldObject?["opmlOrder"]
            }
        }
        if oldSchemaVersion < 74 {
            // Retire the unfinished transcript cache without a production model.
            migration.deleteData(forType: "MediaTranscript")
        }
    }
}
