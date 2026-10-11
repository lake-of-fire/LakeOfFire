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

private struct LibraryAdmissionKey: Comparable, Sendable {
    let createdAt: Date
    let resolutionRank: Int
    let sourceConfigurationID: String
    let sourceOrdinal: Int
    let targetID: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.resolutionRank != rhs.resolutionRank {
            return lhs.resolutionRank < rhs.resolutionRank
        }
        if lhs.sourceConfigurationID != rhs.sourceConfigurationID {
            return lhs.sourceConfigurationID < rhs.sourceConfigurationID
        }
        if lhs.sourceOrdinal != rhs.sourceOrdinal {
            return lhs.sourceOrdinal < rhs.sourceOrdinal
        }
        return lhs.targetID < rhs.targetID
    }
}

private struct LibraryAdmissionCandidate: Sendable {
    let id: UUID
    let key: LibraryAdmissionKey
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
        let resolvedPrimaryID = try await realm.asyncWrite {
            try Task.checkCancellation()
            // Select the survivor and admit immutable relationship keys in
            // the final transaction, preserving the primary's existing order.
            let configurations = Array(
                realm.objects(LibraryConfiguration.self).where { !$0.isDeleted }
            ).sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            let timestamp = Date()
            guard let primary = configurations.first else {
                let configuration = LibraryConfiguration()
                realm.add(configuration)
                configuration.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: timestamp
                )
                return configuration.id
            }
            let duplicateIDs = configurations.dropFirst().map(\.id)

            func normalizedExistingCategories() -> [UUID] {
                orderedUniqueLibraryIdentifiers(Array(primary.categoryIDs)).filter { id in
                    guard let category = realm.object(
                        ofType: FeedCategory.self,
                        forPrimaryKey: id
                    ) else {
                        // Preserve unresolved current relationships across bounded
                        // CloudKit delivery; absence is not a deletion decision.
                        return true
                    }
                    return !category.isDeleted && !category.isArchived
                }
            }

            func normalizedExistingScripts() -> [UUID] {
                orderedUniqueLibraryIdentifiers(Array(primary.userScriptIDs)).filter { id in
                    guard let script = realm.object(
                        ofType: UserScript.self,
                        forPrimaryKey: id
                    ) else {
                        return true
                    }
                    // Disabled scripts remain reachable for re-enabling; execution filters them separately.
                    return !script.isDeleted
                }
            }

            var finalCategoryIDs = normalizedExistingCategories()
            var finalScriptIDs = normalizedExistingScripts()
            let existingCategoryIDs = Set(finalCategoryIDs)
            let existingScriptIDs = Set(finalScriptIDs)
            var categoryCandidates: [UUID: LibraryAdmissionCandidate] = [:]
            var scriptCandidates: [UUID: LibraryAdmissionCandidate] = [:]

            func register(
                id: UUID,
                key: LibraryAdmissionKey,
                in candidates: inout [UUID: LibraryAdmissionCandidate]
            ) {
                if let existing = candidates[id], existing.key <= key {
                    return
                }
                candidates[id] = LibraryAdmissionCandidate(id: id, key: key)
            }

            for duplicateID in duplicateIDs {
                guard let configuration = realm.object(
                    ofType: LibraryConfiguration.self,
                    forPrimaryKey: duplicateID
                ), !configuration.isDeleted else {
                    continue
                }

                for (ordinal, id) in configuration.categoryIDs.enumerated()
                    where !existingCategoryIDs.contains(id) {
                    if let category = realm.object(
                        ofType: FeedCategory.self,
                        forPrimaryKey: id
                    ) {
                        guard !category.isDeleted, !category.isArchived else { continue }
                        register(
                            id: id,
                            key: LibraryAdmissionKey(
                                createdAt: category.createdAt,
                                resolutionRank: 0,
                                sourceConfigurationID: "",
                                sourceOrdinal: 0,
                                targetID: id.uuidString
                            ),
                            in: &categoryCandidates
                        )
                    } else {
                        register(
                            id: id,
                            key: LibraryAdmissionKey(
                                createdAt: configuration.createdAt,
                                resolutionRank: 1,
                                sourceConfigurationID: configuration.id.uuidString,
                                sourceOrdinal: ordinal,
                                targetID: id.uuidString
                            ),
                            in: &categoryCandidates
                        )
                    }
                }

                for (ordinal, id) in configuration.userScriptIDs.enumerated()
                    where !existingScriptIDs.contains(id) {
                    if let script = realm.object(
                        ofType: UserScript.self,
                        forPrimaryKey: id
                    ) {
                        guard !script.isDeleted else { continue }
                        register(
                            id: id,
                            key: LibraryAdmissionKey(
                                createdAt: script.createdAt,
                                resolutionRank: 0,
                                sourceConfigurationID: "",
                                sourceOrdinal: 0,
                                targetID: id.uuidString
                            ),
                            in: &scriptCandidates
                        )
                    } else {
                        register(
                            id: id,
                            key: LibraryAdmissionKey(
                                createdAt: configuration.createdAt,
                                resolutionRank: 1,
                                sourceConfigurationID: configuration.id.uuidString,
                                sourceOrdinal: ordinal,
                                targetID: id.uuidString
                            ),
                            in: &scriptCandidates
                        )
                    }
                }
            }

            // Orphan eligibility is evaluated inside the final transaction. Only
            // stable IDs cross suspension; stale managed objects and pre-await
            // archive/deletion decisions are never reused.
            for category in realm.objects(FeedCategory.self).where({
                !$0.isDeleted && !$0.isArchived
            }) where !existingCategoryIDs.contains(category.id) {
                register(
                    id: category.id,
                    key: LibraryAdmissionKey(
                        createdAt: category.createdAt,
                        resolutionRank: 0,
                        sourceConfigurationID: "",
                        sourceOrdinal: 0,
                        targetID: category.id.uuidString
                    ),
                    in: &categoryCandidates
                )
            }
            for script in realm.objects(UserScript.self).where({
                !$0.isDeleted
            }) where !existingScriptIDs.contains(script.id) {
                register(
                    id: script.id,
                    key: LibraryAdmissionKey(
                        createdAt: script.createdAt,
                        resolutionRank: 0,
                        sourceConfigurationID: "",
                        sourceOrdinal: 0,
                        targetID: script.id.uuidString
                    ),
                    in: &scriptCandidates
                )
            }

            finalCategoryIDs.append(
                contentsOf: categoryCandidates.values.sorted {
                    $0.key < $1.key
                }.map(\.id)
            )
            finalScriptIDs.append(
                contentsOf: scriptCandidates.values.sorted {
                    $0.key < $1.key
                }.map(\.id)
            )
            finalCategoryIDs = orderedUniqueLibraryIdentifiers(finalCategoryIDs)
            finalScriptIDs = orderedUniqueLibraryIdentifiers(finalScriptIDs)

            let currentCategoryIDs = Array(primary.categoryIDs)
            let currentScriptIDs = Array(primary.userScriptIDs)
            var primaryChanged = false
            if finalCategoryIDs != currentCategoryIDs {
                primary.categoryIDs.removeAll()
                primary.categoryIDs.append(objectsIn: finalCategoryIDs)
                primaryChanged = true
            }
            if finalScriptIDs != currentScriptIDs {
                primary.userScriptIDs.removeAll()
                primary.userScriptIDs.append(objectsIn: finalScriptIDs)
                primaryChanged = true
            }
            if primaryChanged {
                primary.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: timestamp
                )
            }

            for duplicateID in duplicateIDs {
                guard let duplicate = realm.object(
                    ofType: LibraryConfiguration.self,
                    forPrimaryKey: duplicateID
                ), !duplicate.isDeleted else {
                    continue
                }
                duplicate.isDeleted = true
                duplicate.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: timestamp
                )
            }
            return primary.id
        }

        if let primary = realm.object(
            ofType: LibraryConfiguration.self,
            forPrimaryKey: resolvedPrimaryID
        ), !primary.isDeleted {
            return primary
        }
        throw LibraryConfigurationConsolidationError
            .missingPrimaryAfterConsolidation
    }

}
