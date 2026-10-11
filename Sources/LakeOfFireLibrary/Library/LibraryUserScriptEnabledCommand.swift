import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

struct LibraryUserScriptTarget: Sendable, Equatable {
    let scriptID: UUID
    let createdAt: Date
}

struct LibraryUserScriptLifecycleResult: Sendable, Equatable {
    let archivedScriptIDs: [UUID]
    let deletedScriptIDs: [UUID]
    let restoredScriptIDs: [UUID]
    let changedAt: Date
    var membershipChanged = false
}

enum LibraryUserScriptLifecycleCommand {
    @RealmBackgroundActor
    static func setEnabled(
        _ isEnabled: Bool,
        target: LibraryUserScriptTarget,
        configurationID: UUID,
        configurationCreatedAt: Date,
        realmConfiguration: Realm.Configuration,
        requiringExistingMembership: Bool = false,
        at timestamp: Date = Date()
    ) async throws -> LibraryUserScriptLifecycleResult {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration
        )
        var archivedScriptIDs = [UUID]()
        var restoredScriptIDs = [UUID]()
        var membershipChanged = false
        try Task.checkCancellation()
        try await realm.asyncWrite {
            try Task.checkCancellation()
            guard let configuration = realm.object(
                ofType: LibraryConfiguration.self,
                forPrimaryKey: configurationID
            ), !configuration.isDeleted,
            configuration.createdAt == configurationCreatedAt,
            let script = realm.object(
                ofType: UserScript.self,
                forPrimaryKey: target.scriptID
            ), !script.isDeleted,
            script.createdAt == target.createdAt,
            script.isUserEditable,
            script.opmlURL == nil,
            !requiringExistingMembership || configuration.userScriptIDs.contains(script.id) else {
                throw RealmBackgroundActorError.unableToResolveObject
            }

            if isEnabled, script.isArchived {
                script.isArchived = false
                script.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: timestamp
                )
                restoredScriptIDs.append(script.id)
            } else if !isEnabled, !script.isArchived {
                script.isArchived = true
                script.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: timestamp
                )
                archivedScriptIDs.append(script.id)
            }
            if !configuration.userScriptIDs.contains(script.id) {
                configuration.userScriptIDs.append(script.id)
                membershipChanged = true
                configuration.refreshChangeMetadata(
                    explicitlyModified: true,
                    at: timestamp
                )
            }
        }
        return LibraryUserScriptLifecycleResult(
            archivedScriptIDs: archivedScriptIDs,
            deletedScriptIDs: [],
            restoredScriptIDs: restoredScriptIDs,
            changedAt: timestamp,
            membershipChanged: membershipChanged
        )
    }

}
