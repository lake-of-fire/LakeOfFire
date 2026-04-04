import Foundation
import RealmSwift

public enum DefaultRealmConfiguration {
    public static let schemaVersion: UInt64 = 54
    
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
            MediaTranscript.self,
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

        if oldSchemaVersion < 54 {
            migrateMediaTranscript_schemaVersionLessThan54(migration: migration)
        }
    }

    private static func migrateMediaTranscript_schemaVersionLessThan54(migration: Migration) {
        migration.enumerateObjects(ofType: MediaTranscript.className()) { oldObject, newObject in
            guard let newObject else { return }

            let contentURL = migrationURL(oldObject, key: "contentURL")
            let stableMediaIdentity = migrationString(oldObject, key: "stableMediaIdentity")
            let languageCode = migrationString(oldObject, key: "languageCode")?.lowercased() ?? "und"

            guard let contentURL, let stableMediaIdentity, !stableMediaIdentity.isEmpty else {
                newObject["isDeleted"] = true
                return
            }

            let canonicalContentURL = MediaTranscript.canonicalContentURL(from: contentURL)
            newObject["contentURL"] = canonicalContentURL
            newObject["stableMediaIdentity"] = stableMediaIdentity
            newObject["languageCode"] = languageCode
            newObject["compoundKey"] = MediaTranscript.makeCompoundKey(
                contentURL: canonicalContentURL,
                stableMediaIdentity: stableMediaIdentity,
                languageCode: languageCode
            )
            if migrationString(oldObject, key: "transcriptLocale")?.isEmpty != false {
                newObject["transcriptLocale"] = languageCode
            }
        }
    }

    private static func migrationURL(_ object: MigrationObject?, key: String) -> URL? {
        guard let object else { return nil }
        if object.objectSchema.properties.contains(where: { $0.name == key }) == false {
            return nil
        }
        if let url = object[key] as? URL {
            return url
        }
        if let value = object[key] as? String {
            return URL(string: value)
        }
        return nil
    }

    private static func migrationString(_ object: MigrationObject?, key: String) -> String? {
        guard let object else { return nil }
        if object.objectSchema.properties.contains(where: { $0.name == key }) == false {
            return nil
        }
        return object[key] as? String
    }
}
