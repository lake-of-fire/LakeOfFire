import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

struct LibraryUserScriptEditorTarget: Equatable, Sendable {
    let scriptID: UUID
    let createdAt: Date
}

enum LibraryUserScriptEditorField: Equatable, Sendable {
    case title
    case source
    case enabled
    case injectAtStart
    case mainFrameOnly
    case sandboxed
    case previewURL
}

enum LibraryUserScriptEditorFieldMutationResult: Equatable, Sendable {
    case changed(changedAt: Date)
    case unchanged
    case superseded
    case unavailable
}

enum LibraryUserScriptEditorFieldMutation: Equatable, Sendable {
    case title(String)
    case source(String)
    case injectAtStart(Bool)
    case mainFrameOnly(Bool)
    case sandboxed(Bool)
    case previewURL(URL?)

    var field: LibraryUserScriptEditorField {
        switch self {
        case .title:
            .title
        case .source:
            .source
        case .injectAtStart:
            .injectAtStart
        case .mainFrameOnly:
            .mainFrameOnly
        case .sandboxed:
            .sandboxed
        case .previewURL:
            .previewURL
        }
    }
}

enum LibraryUserScriptEditorFieldCommand {
    @RealmBackgroundActor
    static func perform(
        _ mutation: LibraryUserScriptEditorFieldMutation,
        target: LibraryUserScriptEditorTarget,
        configuration: Realm.Configuration,
        at timestamp: Date = Date()
    ) async throws -> LibraryUserScriptEditorFieldMutationResult {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try Task.checkCancellation()
        return try await realm.asyncWrite {
            try Task.checkCancellation()
            guard let script = realm.object(
                ofType: UserScript.self,
                forPrimaryKey: target.scriptID
            ) else {
                return .unavailable
            }
            guard !script.isDeleted, script.isUserEditable else {
                return .unavailable
            }
            guard script.createdAt == target.createdAt else {
                return .superseded
            }

            let changed: Bool
            switch mutation {
            case .title(let value):
                changed = script.title != value
                if changed { script.title = value }
            case .source(let value):
                changed = script.script != value
                if changed { script.script = value }
            case .injectAtStart(let value):
                changed = script.injectAtStart != value
                if changed { script.injectAtStart = value }
            case .mainFrameOnly(let value):
                changed = script.mainFrameOnly != value
                if changed { script.mainFrameOnly = value }
            case .sandboxed(let value):
                changed = script.sandboxed != value
                if changed { script.sandboxed = value }
            case .previewURL(let value):
                changed = script.previewURL != value
                if changed { script.previewURL = value }
            }
            guard changed else { return .unchanged }
            script.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            return .changed(changedAt: timestamp)
        }
    }
}

struct LibraryUserScriptAllowedDomainTarget: Equatable, Sendable, Identifiable {
    let domainID: UUID
    let createdAt: Date

    var id: UUID { domainID }
}

enum LibraryUserScriptAllowedDomainMembershipMutationResult: Equatable, Sendable {
    case changed(changedAt: Date)
    case unchanged
    case superseded
    case unavailable
}

enum LibraryUserScriptAllowedDomainFieldMutationResult: Equatable, Sendable {
    case changed(changedAt: Date)
    case unchanged
    case superseded
    case unavailable
}

enum LibraryUserScriptAllowedDomainFieldCommand {
    @RealmBackgroundActor
    static func setDomain(
        _ domainText: String,
        target: LibraryUserScriptAllowedDomainTarget,
        configuration: Realm.Configuration,
        at timestamp: Date = Date()
    ) async throws -> LibraryUserScriptAllowedDomainFieldMutationResult {
        try await writeDomain(domainText, target: target, scriptTarget: nil, configuration: configuration, at: timestamp)
    }

    @RealmBackgroundActor
    static func setDomain(
        _ domainText: String,
        target: LibraryUserScriptAllowedDomainTarget,
        from scriptTarget: LibraryUserScriptEditorTarget,
        configuration: Realm.Configuration,
        at timestamp: Date = Date()
    ) async throws -> LibraryUserScriptAllowedDomainFieldMutationResult {
        try await writeDomain(
            domainText, target: target, scriptTarget: scriptTarget, configuration: configuration, at: timestamp
        )
    }

    @RealmBackgroundActor
    private static func writeDomain(
        _ domainText: String,
        target: LibraryUserScriptAllowedDomainTarget,
        scriptTarget: LibraryUserScriptEditorTarget?,
        configuration: Realm.Configuration,
        at timestamp: Date
    ) async throws -> LibraryUserScriptAllowedDomainFieldMutationResult {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try Task.checkCancellation()
        return try await realm.asyncWrite {
            try Task.checkCancellation()
            if let scriptTarget {
                guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptTarget.scriptID),
                      !script.isDeleted, script.isUserEditable,
                      script.allowedDomainIDs.contains(target.domainID) else { return .unavailable }
                guard script.createdAt == scriptTarget.createdAt else { return .superseded }
            }
            guard let domain = realm.object(
                ofType: UserScriptAllowedDomain.self,
                forPrimaryKey: target.domainID
            ) else {
                return .unavailable
            }
            guard !domain.isDeleted else { return .unavailable }
            guard domain.createdAt == target.createdAt else { return .superseded }
            guard domain.domain != domainText else { return .unchanged }
            domain.domain = domainText
            domain.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            return .changed(changedAt: timestamp)
        }
    }
}

enum LibraryUserScriptAllowedDomainMembershipCommand {
    @RealmBackgroundActor
    static func addEmptyDomain(
        to target: LibraryUserScriptEditorTarget,
        domainID: UUID = UUID(),
        configuration: Realm.Configuration,
        at timestamp: Date = Date()
    ) async throws -> (LibraryUserScriptAllowedDomainMembershipMutationResult, LibraryUserScriptAllowedDomainTarget?) {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try Task.checkCancellation()
        return try await realm.asyncWrite {
            try Task.checkCancellation()
            guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: target.scriptID) else {
                return (.unavailable, nil)
            }
            guard !script.isDeleted, script.isUserEditable else {
                return (.unavailable, nil)
            }
            guard script.createdAt == target.createdAt else {
                return (.superseded, nil)
            }
            guard realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID) == nil else {
                return (.unchanged, nil)
            }

            let domain = UserScriptAllowedDomain()
            domain.id = domainID
            realm.add(domain)
            domain.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            script.allowedDomainIDs.append(domain.id)
            script.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            return (
                .changed(changedAt: timestamp),
                LibraryUserScriptAllowedDomainTarget(domainID: domain.id, createdAt: domain.createdAt)
            )
        }
    }

    @RealmBackgroundActor
    static func deleteDomains(
        _ targets: [LibraryUserScriptAllowedDomainTarget],
        from scriptTarget: LibraryUserScriptEditorTarget,
        configuration: Realm.Configuration,
        at timestamp: Date = Date()
    ) async throws -> LibraryUserScriptAllowedDomainMembershipMutationResult {
        var seenIDs = Set<UUID>()
        let uniqueTargets = targets.filter { seenIDs.insert($0.domainID).inserted }
        guard !uniqueTargets.isEmpty else { return .unchanged }

        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try Task.checkCancellation()
        return try await realm.asyncWrite {
            try Task.checkCancellation()
            guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptTarget.scriptID) else {
                return .unavailable
            }
            guard !script.isDeleted, script.isUserEditable else {
                return .unavailable
            }
            guard script.createdAt == scriptTarget.createdAt else {
                return .superseded
            }

            var domains = [UserScriptAllowedDomain]()
            for target in uniqueTargets {
                guard let domain = realm.object(
                    ofType: UserScriptAllowedDomain.self,
                    forPrimaryKey: target.domainID
                ), !domain.isDeleted,
                script.allowedDomainIDs.contains(target.domainID) else {
                    return .unavailable
                }
                guard domain.createdAt == target.createdAt else {
                    return .superseded
                }
                domains.append(domain)
            }

            for domain in domains {
                domain.isDeleted = true
                domain.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            }
            let deletedIDs = Set(uniqueTargets.map(\.domainID))
            let retainedIDs = Array(script.allowedDomainIDs).filter { !deletedIDs.contains($0) }
            guard retainedIDs.count != script.allowedDomainIDs.count else { return .unchanged }
            script.allowedDomainIDs.removeAll()
            script.allowedDomainIDs.append(objectsIn: retainedIDs)
            script.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            return .changed(changedAt: timestamp)
        }
    }
}
