import Foundation
import RealmSwift

public enum DefaultRealmConfiguration {
    // 74 retains the original local hidden-offer flag and repairs historical links.
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
            MediaTranscript.self,
            UserScript.self,
            UserScriptAllowedDomain.self,
        ]
        return config
    }

    public static func migrationBlock(migration: Migration, oldSchemaVersion: UInt64) {
        preserveHistoricalRelationships(in: migration)
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
        if oldSchemaVersion < 72 {
            // MediaTranscript had never shipped with user-created data. Its
            // previous compound key was not a valid CloudKit record name, so
            // discard those cache rows and recreate them with hashed keys.
            migration.deleteData(forType: MediaTranscript.className())
        }
    }

    private static func preserveHistoricalRelationships(in migration: Migration) {
        // Lake50→51 omitted these copies. The app composes this schema into
        // Shared, whose version numbers are unrelated to standalone Lake's.
        LegacyRealmRelationshipMigration.preserve([
            .init("Feed", "category", "categoryID", target: "FeedCategory", key: "id", type: .UUID),
            .init("FeedEntry", "feed", "feedID", target: "Feed", key: "id", type: .UUID),
            .init("LibraryConfiguration", "categories", "categoryIDs", target: "FeedCategory", key: "id", type: .UUID, list: true),
            .init("LibraryConfiguration", "userScripts", "userScriptIDs", target: "UserScript", key: "id", type: .UUID, list: true),
            .init("UserScript", "allowedDomains", "allowedDomainIDs", target: "UserScriptAllowedDomain", key: "id", type: .UUID, list: true),
        ], in: migration)
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

/// Copies historical object references to their primitive identities without
/// consulting current-account state. Shared embeds Lake's models with a
/// different version space, so the original stored shapes select the repair.
public enum LegacyRealmRelationshipMigration {
    public struct Link {
        let table: String
        let source: String
        let destination: String
        let target: String
        let key: String
        let keyType: PropertyType
        let isList: Bool

        public init(_ table: String, _ source: String, _ destination: String,
                    target: String, key: String, type: PropertyType, list: Bool = false) {
            self.table = table
            self.source = source
            self.destination = destination
            self.target = target
            self.key = key
            self.keyType = type
            self.isList = list
        }
    }

    public static func preserve(_ links: [Link], in migration: Migration) {
        for link in links {
            guard let oldTable = migration.oldSchema[link.table],
                  let old = oldTable.properties.first(where: { $0.name == link.source }) else { continue }
            // An already-stored ID is original data. Never replace it from an
            // old parallel link; the independent preservation gate checks both.
            guard !oldTable.properties.contains(where: { $0.name == link.destination }) else { continue }
            guard let new = migration.newSchema[link.table]?.properties.first(where: {
                $0.name == link.destination
            }), let targetKey = migration.oldSchema[link.target]?.primaryKeyProperty else {
                preconditionFailure("Missing historical relationship destination: \(link.table).\(link.destination)")
            }
            precondition(old.type == .object && old.objectClassName == link.target
                && old.isArray == link.isList && !old.isSet && !old.isMap
                && old.isOptional == !link.isList
                && targetKey.name == link.key && targetKey.type == link.keyType
                && !targetKey.isOptional && !targetKey.isArray && !targetKey.isSet && !targetKey.isMap
                && new.type == link.keyType && new.isArray == link.isList
                && !new.isSet && !new.isMap && new.isOptional == !link.isList,
                "Unsupported historical relationship shape: \(link.table).\(link.source)")
            migration.enumerateObjects(ofType: link.table) { oldObject, newObject in
                guard let oldObject, let newObject else { return }
                if link.isList {
                    guard let originals = oldObject[link.source] as? List<MigrationObject> else {
                        preconditionFailure("Invalid historical relationship list: \(link.table).\(link.source)")
                    }
                    // All historical relationship lists in this contract use UUID
                    // identity. map keeps order/duplicates and never drops a key.
                    precondition(link.keyType == .UUID)
                    let identifiers = originals.map { original -> UUID in
                        guard let id = original[link.key] as? UUID else {
                            preconditionFailure("Invalid historical relationship identity: \(link.target).\(link.key)")
                        }
                        return id
                    }
                    let list = List<UUID>()
                    list.append(objectsIn: identifiers)
                    newObject[link.destination] = list
                } else if let value = oldObject[link.source] {
                    guard let original = value as? MigrationObject else {
                        preconditionFailure("Invalid historical relationship: \(link.table).\(link.source)")
                    }
                    // Realm validates the primitive against the destination type;
                    // zero IDs, foreign owners and tombstoned endpoints are data.
                    newObject[link.destination] = original[link.key]
                } else {
                    newObject[link.destination] = nil
                }
            }
        }
    }
}
