import Foundation
import SwiftUI
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

/// One rendered Library projection. UI offsets never outlive the rows that
/// produced them; commands carry values rather than managed Realm accessors.
struct LibraryScriptListSelection: Sendable {
    struct Row: Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let wasEditable: Bool
        let wasArchived: Bool
    }

    let configurationID: UUID
    let configurationCreatedAt: Date
    let realmConfiguration: Realm.Configuration
    let storageAdmission: RealmStorageAdmission
    let originalIDs: [UUID]
    let rows: [Row]

    @MainActor
    init?(configuration: LibraryConfiguration, scripts: [UserScript]) {
        guard !configuration.isInvalidated, !configuration.isDeleted,
              let realm = configuration.realm else { return nil }
        let capturedConfiguration = realm.configuration
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: capturedConfiguration)
        let storageKey = RealmBackgroundActor.shared.realmCacheKey(for: capturedConfiguration)
        guard scripts.allSatisfy({ script in
            guard !script.isInvalidated, !script.isDeleted,
                  let scriptRealm = script.realm else { return false }
            return RealmBackgroundActor.shared.realmCacheKey(for: scriptRealm.configuration) == storageKey
        }) else { return nil }

        let identifiers = Array(configuration.userScriptIDs)
        let renderedIDs = scripts.map(\.id)
        let renderedSet = Set(renderedIDs)
        guard Set(identifiers).count == identifiers.count,
              renderedSet.count == renderedIDs.count,
              identifiers.filter(renderedSet.contains) == renderedIDs else { return nil }

        configurationID = configuration.id
        configurationCreatedAt = configuration.createdAt
        realmConfiguration = capturedConfiguration
        storageAdmission = admission
        originalIDs = identifiers
        rows = scripts.map {
            Row(id: $0.id, createdAt: $0.createdAt,
                wasEditable: $0.isUserEditable, wasArchived: $0.isArchived)
        }
        guard admission.matchesCurrentStorageIdentity({
            RealmBackgroundActor.shared.realmCacheKey(for: capturedConfiguration)
        }) else { return nil }
    }

    private func validateStorage() throws {
        guard storageAdmission.matchesCurrentStorageIdentity({
            RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
        }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
    }

    @RealmBackgroundActor
    private func resolveConfiguration(in realm: Realm) -> LibraryConfiguration? {
        guard let configuration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: configurationID),
              !configuration.isDeleted,
              configuration.createdAt == configurationCreatedAt else { return nil }
        return configuration
    }

    @RealmBackgroundActor
    private func resolve(_ row: Row, in realm: Realm) -> UserScript? {
        guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: row.id),
              !script.isDeleted, script.createdAt == row.createdAt else { return nil }
        return script
    }

    @RealmBackgroundActor
    func delete(
        at offsets: IndexSet,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard offsets.allSatisfy(rows.indices.contains) else { return false }
        let selectedRows = offsets.map { rows[$0] }.filter(\.wasEditable)
        guard !selectedRows.isEmpty else { return false }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration, storageAdmission: storageAdmission
        )
        try await beforeWrite?()
        try Task.checkCancellation()
        return try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            try validateStorage()
            guard let configuration = resolveConfiguration(in: realm) else { return false }
            let timestamp = Date()
            var didChange = false
            var deletedIDs = Set<UUID>()
            for row in selectedRows {
                guard configuration.userScriptIDs.contains(row.id),
                      let script = resolve(row, in: realm), script.isUserEditable,
                      script.isArchived == row.wasArchived else { continue }
                if row.wasArchived {
                    script.isDeleted = true
                    deletedIDs.insert(row.id)
                } else {
                    // Disabled scripts remain visible and keep their current
                    // slot. Only a later delete gesture removes the reference.
                    script.isArchived = true
                }
                script.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                didChange = true
            }
            if !deletedIDs.isEmpty {
                let currentIDs = Array(configuration.userScriptIDs)
                let nextIDs = currentIDs.filter { !deletedIDs.contains($0) }
                if nextIDs != currentIDs {
                    configuration.userScriptIDs.removeAll()
                    configuration.userScriptIDs.append(objectsIn: nextIDs)
                    configuration.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
            }
            try Task.checkCancellation()
            try validateStorage()
            return didChange
        }
    }

    @RealmBackgroundActor
    func move(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard !offsets.isEmpty, offsets.allSatisfy(rows.indices.contains),
              offsets.allSatisfy({ rows[$0].wasEditable }),
              destination >= 0, destination <= rows.count else { return false }
        let editableIDs = rows.filter(\.wasEditable).map(\.id)
        let editableSet = Set(editableIDs)
        var reorderedRows = rows
        reorderedRows.move(fromOffsets: offsets, toOffset: destination)
        let reorderedIDs = reorderedRows.filter(\.wasEditable).map(\.id)
        guard reorderedIDs != editableIDs else { return false }
        var nextRawIDs = originalIDs
        var nextIndex = 0
        for index in nextRawIDs.indices where editableSet.contains(nextRawIDs[index]) {
            guard nextIndex < reorderedIDs.count else { return false }
            nextRawIDs[index] = reorderedIDs[nextIndex]
            nextIndex += 1
        }
        guard nextIndex == reorderedIDs.count, nextRawIDs != originalIDs else { return false }

        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration, storageAdmission: storageAdmission
        )
        try await beforeWrite?()
        try Task.checkCancellation()
        return try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            try validateStorage()
            guard let configuration = resolveConfiguration(in: realm),
                  Array(configuration.userScriptIDs) == originalIDs else { return false }
            // A newly managed, deleted or recreated displayed row invalidates
            // the old projection, even when its raw identifier did not change.
            for row in rows {
                guard let script = resolve(row, in: realm),
                      script.isUserEditable == row.wasEditable else { return false }
            }
            configuration.userScriptIDs.removeAll()
            configuration.userScriptIDs.append(objectsIn: nextRawIDs)
            configuration.refreshChangeMetadata(explicitlyModified: true)
            try Task.checkCancellation()
            try validateStorage()
            return true
        }
    }
}
