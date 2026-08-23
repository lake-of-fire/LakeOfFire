import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps

enum LibraryConfigurationConsolidationError: Error {
    case missingPrimaryAfterConsolidation
}

func orderedUniqueLibraryIdentifiers<Identifier: Hashable>(
    _ identifiers: [Identifier]
) -> [Identifier] {
    var seen = Set<Identifier>()
    return identifiers.filter { seen.insert($0).inserted }
}

/// Preserves the existing order and inserts incoming-only IDs after the last ID
/// shared by both lists. With no shared anchor, incoming IDs are appended.
func mergeLibraryConfigurationIdentifiers<Identifier: Hashable>(
    primary: [Identifier],
    incoming: [Identifier]
) -> [Identifier] {
    var result = orderedUniqueLibraryIdentifiers(primary)
    let incoming = orderedUniqueLibraryIdentifiers(incoming)
    let existingIdentifiers = Set(result)
    let newIdentifiers = incoming.filter { !existingIdentifiers.contains($0) }
    guard !newIdentifiers.isEmpty else { return result }

    let incomingIdentifiers = Set(incoming)
    if let insertionAnchor = result.lastIndex(where: incomingIdentifiers.contains) {
        result.insert(contentsOf: newIdentifiers, at: insertionAnchor + 1)
    } else {
        result.append(contentsOf: newIdentifiers)
    }
    return result
}

private func libraryConfigurationPrecedes(
    _ lhs: LibraryConfiguration,
    _ rhs: LibraryConfiguration
) -> Bool {
    if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
    }
    return lhs.id.uuidString < rhs.id.uuidString
}

private func replaceLibraryListIfNeeded<T: RealmCollectionValue>(
    _ list: RealmSwift.List<T>,
    with values: [T]
) -> Bool {
    guard Array(list) != values else { return false }
    list.removeAll()
    list.append(objectsIn: values)
    return true
}

extension LibraryConfiguration {
    @RealmBackgroundActor
    public static func getConsolidatedOrCreate(
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration
    ) async throws -> LibraryConfiguration {
        try Task.checkCancellation()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration
        )

        let primaryID: UUID = try await realm.asyncWrite {
            try Task.checkCancellation()
            let configurations = Array(
                realm.objects(LibraryConfiguration.self).where { !$0.isDeleted }
            ).sorted(by: libraryConfigurationPrecedes)

            guard let primary = configurations.first else {
                let configuration = LibraryConfiguration()
                realm.add(configuration)
                configuration.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: Date()
                )
                return configuration.id
            }

            func retainedCategoryIDs(_ identifiers: [UUID]) -> [UUID] {
                orderedUniqueLibraryIdentifiers(identifiers).filter { identifier in
                    guard let category = realm.object(
                        ofType: FeedCategory.self,
                        forPrimaryKey: identifier
                    ) else {
                        // A missing object may still be in transit from CloudKit.
                        return true
                    }
                    return !category.isDeleted && !category.isArchived
                }
            }

            func retainedScriptIDs(_ identifiers: [UUID]) -> [UUID] {
                orderedUniqueLibraryIdentifiers(identifiers).filter { identifier in
                    guard let script = realm.object(
                        ofType: UserScript.self,
                        forPrimaryKey: identifier
                    ) else {
                        return true
                    }
                    return !script.isDeleted && !script.isArchived
                }
            }

            var categoryIDs = retainedCategoryIDs(Array(primary.categoryIDs))
            var scriptIDs = retainedScriptIDs(Array(primary.userScriptIDs))
            let duplicates = configurations.dropFirst()

            for duplicate in duplicates {
                categoryIDs = mergeLibraryConfigurationIdentifiers(
                    primary: categoryIDs,
                    incoming: retainedCategoryIDs(Array(duplicate.categoryIDs))
                )
                scriptIDs = mergeLibraryConfigurationIdentifiers(
                    primary: scriptIDs,
                    incoming: retainedScriptIDs(Array(duplicate.userScriptIDs))
                )
            }

            let referencedCategoryIDs = Set(categoryIDs)
            let orphanCategoryIDs = Array(
                realm.objects(FeedCategory.self).where {
                    !$0.isDeleted && !$0.isArchived
                }
            ).filter {
                !referencedCategoryIDs.contains($0.id)
            }.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }.map(\.id)
            categoryIDs.append(contentsOf: orphanCategoryIDs)

            let referencedScriptIDs = Set(scriptIDs)
            let orphanScriptIDs = Array(
                realm.objects(UserScript.self).where {
                    !$0.isDeleted && !$0.isArchived
                }
            ).filter {
                !referencedScriptIDs.contains($0.id)
            }.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }.map(\.id)
            scriptIDs.append(contentsOf: orphanScriptIDs)

            let categoryIDsChanged = replaceLibraryListIfNeeded(
                primary.categoryIDs,
                with: categoryIDs
            )
            let scriptIDsChanged = replaceLibraryListIfNeeded(
                primary.userScriptIDs,
                with: scriptIDs
            )
            let timestamp = Date()
            if categoryIDsChanged || scriptIDsChanged {
                primary.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: timestamp
                )
            }

            for duplicate in duplicates where !duplicate.isDeleted {
                duplicate.isDeleted = true
                duplicate.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: timestamp
                )
            }
            return primary.id
        }

        guard let primary = realm.object(
            ofType: LibraryConfiguration.self,
            forPrimaryKey: primaryID
        ), !primary.isDeleted else {
            throw LibraryConfigurationConsolidationError
                .missingPrimaryAfterConsolidation
        }
        return primary
    }
}
